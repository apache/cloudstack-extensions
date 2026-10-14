// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// CloudStack orchestrator extension for Apple container on macOS.
//
// Apple container (https://github.com/apple/container) runs each Linux
// container from an OCI image in its own lightweight virtual machine on Apple
// silicon, through Apple's Virtualization framework. This program drives its
// `container` command line tool: every CloudStack instance is one container,
// named after the instance's internal name and labelled as managed by
// CloudStack, created from the OCI image configured on the template.
//
// The management server reaches the Mac over SSH (or runs locally when the
// management server itself runs on the Mac). Each NIC of the instance is
// attached to a container network with the CloudStack MAC address. A NIC on
// a network of the vmnet network extension carries a broadcast URI such as
// vs://cs-net-42?mode=nat; it is attached to the container network of that
// name, which is created on first use and deleted with its last container.
// Other NICs use the networks of the network detail.
//
// Details (host details override extension details):
//   url                   Mac hostname/IP, or "localhost" to run locally
//   username              SSH user running the container system service
//   password              optional, SSH password (requires sshpass on the
//                         management server; key authentication is preferred)
//   ssh_key               optional, private key path on the management server
//   ssh_port              optional, defaults to 22
//   verify_host_key       optional, "true" (default) or "false"
//   container_path        optional, defaults to /usr/local/bin/container
//   network               optional, comma separated container networks, one
//                         per NIC in device order, the last one repeating for
//                         further NICs; defaults to "default". Not used for
//                         NICs on vmnet extension networks
//   wait_timeout          optional, seconds a stop waits before the container
//                         is killed and to wait for other commands (60)
//   pull_timeout          optional, seconds to wait for an image pull (900)
//   start_service         optional, "true" (default) starts the container
//                         system service when it is not running
//
// Template, service offering or instance details (instance wins), which may
// also be set on the host or extension as defaults:
//   image                 OCI image reference, e.g. docker.io/library/alpine:3.22
//   command               optional, command line replacing the image's default
//                         arguments, split on whitespace, e.g. "sleep infinity"
//   platform              optional, image platform, e.g. linux/amd64
//   init                  optional, "true" runs an init process that reaps
//                         zombies and forwards signals
//   rosetta               optional, "true" enables Rosetta for amd64 images

import Foundation

public let defaultContainerPath = "/usr/local/bin/container"
public let defaultNetwork = "default"
public let managedLabel = "org.apache.cloudstack.managed"
let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
let defaultLogLines: UInt64 = 100
/// Broadcast URI scheme of the networks named by the vmnet network extension.
let vmnetScheme = "vs://"
/// Hint the container tool prints when its system service is not running.
let serviceDownHint = "container system start"
public let operations: Set<String> = [
    "create", "start", "stop", "reboot", "delete", "status", "statuses", "getconsole", "getipaddresses", "getlogs",
]

public typealias JSONObject = [String: Any]

/// An error whose message is reported to CloudStack.
public struct ExtensionError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

func successMessage(_ message: String) -> JSONObject {
    ["status": "success", "message": message]
}

/// Quote an argument for a POSIX shell, like Python's shlex.quote.
public func shellQuote(_ arg: String) -> String {
    let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
    if !arg.isEmpty && arg.allSatisfy({ safe.contains($0) }) {
        return arg
    }
    return "'" + arg.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

/// Text of a JSON value that may be a string, a number or a boolean.
public func valueText(_ value: Any?) -> String {
    switch value {
    case nil, is NSNull:
        return ""
    case let string as String:
        return string
    case let number as NSNumber:
        // JSONSerialization decodes true/false as NSNumber too, typed as char
        if String(cString: number.objCType) == "c" {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    case let other?:
        return "\(other)"
    }
}

public func valueUInt64(_ value: Any?) -> UInt64? {
    switch value {
    case let number as NSNumber:
        return number.int64Value >= 0 ? number.uint64Value : nil
    case let string as String:
        return UInt64(string.trimmingCharacters(in: .whitespaces))
    default:
        return nil
    }
}

/// Memory argument for `container create`, in whole MiB as container has 1 MiB granularity.
public func memoryArgument(_ bytes: UInt64) -> String {
    let mib: UInt64 = 1024 * 1024
    return "\(max((bytes + mib - 1) / mib, 1))M"
}

/// A container network named by the vmnet network extension.
public struct VmnetNetwork: Equatable {
    public let name: String
    public let isInternal: Bool

    public init(name: String, isInternal: Bool) {
        self.name = name
        self.isInternal = isInternal
    }
}

/// The vmnet network of a NIC broadcast URI like vs://cs-net-42?mode=internal,
/// or nil for NICs on other networks.
public func vmnetNetwork(_ broadcastURI: String) throws -> VmnetNetwork? {
    guard broadcastURI.hasPrefix(vmnetScheme) else {
        return nil
    }
    let rest = broadcastURI.dropFirst(vmnetScheme.count)
    let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let name = String(parts[0])
    let query = parts.count > 1 ? parts[1] : ""
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    if name.isEmpty || !name.allSatisfy({ allowed.contains($0) }) {
        throw ExtensionError("Invalid vmnet network name in broadcast URI '\(broadcastURI)'")
    }
    let mode = query.split(separator: "&").first { $0.hasPrefix("mode=") }.map { String($0.dropFirst(5)) } ?? "nat"
    switch mode {
    case "nat": return VmnetNetwork(name: name, isInternal: false)
    case "internal": return VmnetNetwork(name: name, isInternal: true)
    default: throw ExtensionError("Invalid vmnet network mode in broadcast URI '\(broadcastURI)'")
    }
}

public struct Nic {
    public let mac: String
    public let vmnet: VmnetNetwork?
}

/// The container network for each NIC, the last configured network repeating for further NICs.
public func nicNetworks(_ networks: [String], nicCount: Int) -> [String] {
    let last = networks.last ?? defaultNetwork
    return (0..<max(nicCount, 1)).map { $0 < networks.count ? networks[$0] : last }
}

/// Runtime state of a container snapshot. `container list --format json` nests
/// it in status.state, the ContainerSnapshot type serializes a bare status.
public func containerState(_ snapshot: JSONObject) -> String {
    if let status = snapshot["status"] as? JSONObject {
        return valueText(status["state"])
    }
    return valueText(snapshot["status"])
}

func containerNetworks(_ snapshot: JSONObject) -> [JSONObject] {
    let networks = snapshot["networks"] ?? (snapshot["status"] as? JSONObject)?["networks"]
    return networks as? [JSONObject] ?? []
}

/// Names of the networks a container is attached to, running or not; only
/// running containers report their network status.
public func networkNames(_ snapshot: JSONObject) -> [String] {
    let configured = (snapshot["configuration"] as? JSONObject)?["networks"] as? [JSONObject] ?? []
    var names: [String] = []
    for network in configured + containerNetworks(snapshot) {
        let name = valueText(network["network"])
        if !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
    }
    return names
}

public func containerID(_ snapshot: JSONObject) -> String {
    valueText((snapshot["configuration"] as? JSONObject)?["id"])
}

/// Whether a container or network carries the CloudStack label.
public func isManaged(_ snapshot: JSONObject) -> Bool {
    let labels = (snapshot["configuration"] as? JSONObject)?["labels"] as? JSONObject
    return valueText(labels?[managedLabel]) == "true"
}

public func powerState(_ state: String) -> String {
    switch state {
    case "running", "stopping": return "poweron"
    case "stopped": return "poweroff"
    default: return "unknown"
    }
}

/// IPv4 and IPv6 addresses of a container, without their prefix lengths.
public func ipAddresses(_ snapshot: JSONObject) -> [String] {
    var addresses: [String] = []
    for network in containerNetworks(snapshot) {
        for key in ["ipv4Address", "address", "ipv6Address"] {
            let address = String(valueText(network[key]).split(separator: "/", omittingEmptySubsequences: false).first ?? "")
            if !address.isEmpty && !addresses.contains(address) {
                addresses.append(address)
            }
        }
    }
    return addresses
}

public struct Config {
    public var url: String
    public var username: String
    public var password: String
    public var sshKey: String
    public var sshPort: String
    public var verifyHostKey: Bool
    public var local: Bool
    public var containerPath: String
    public var networks: [String]
    public var waitTimeout: UInt64
    public var pullTimeout: UInt64
    public var startService: Bool
    public var image: String
    public var command: [String]
    public var platform: String
    public var initProcess: Bool
    public var rosetta: Bool
    public var vmName: String
    public var cpus: UInt64?
    public var memory: UInt64?
    public var nics: [Nic]
    public var parameters: JSONObject

    public init(parsing data: JSONObject) throws {
        let section = { (value: Any?) in value as? JSONObject ?? [:] }
        let external = section(data["externaldetails"])
        let extensionDetails = section(external["extension"])
        let host = section(external["host"])
        let vm = section(external["virtualmachine"])

        func first(_ sections: [JSONObject], _ name: String, _ fallback: String) -> String {
            sections.map { valueText($0[name]) }.first { !$0.isEmpty } ?? fallback
        }
        func detail(_ name: String, _ fallback: String = "") -> String {
            first([host, extensionDetails], name, fallback)
        }
        func vmDetail(_ name: String, _ fallback: String = "") -> String {
            first([vm, host, extensionDetails], name, fallback)
        }
        func number(_ name: String, _ fallback: String) throws -> UInt64 {
            guard let value = UInt64(detail(name, fallback).trimmingCharacters(in: .whitespaces)) else {
                throw ExtensionError("Error parsing JSON: invalid \(name)")
            }
            return value
        }

        url = detail("url")
        username = detail("username")
        if url.isEmpty {
            throw ExtensionError("Missing required field in JSON: url")
        }
        local = localHosts.contains(url.lowercased()) && username.isEmpty
        if !local && username.isEmpty {
            throw ExtensionError("Missing required field in JSON: username")
        }
        networks = detail("network", defaultNetwork)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let vmDetails = section(data["cloudstack.vm.details"])
        let nics = (vmDetails["nics"] as? [JSONObject] ?? [])
            .enumerated()
            .sorted { lhs, rhs in
                // stable on equal device IDs, like Rust's sort_by_key
                let (l, r) = ((lhs.element["deviceId"] as? NSNumber)?.intValue ?? 0,
                              (rhs.element["deviceId"] as? NSNumber)?.intValue ?? 0)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
        self.nics = try nics.map {
            Nic(mac: valueText($0["mac"]), vmnet: try vmnetNetwork(valueText($0["broadcastUri"])))
        }

        password = detail("password")
        sshKey = detail("ssh_key")
        sshPort = detail("ssh_port", "22")
        verifyHostKey = detail("verify_host_key", "true").lowercased() == "true"
        containerPath = detail("container_path", defaultContainerPath)
        waitTimeout = try number("wait_timeout", "60")
        pullTimeout = try number("pull_timeout", "900")
        startService = detail("start_service", "true").lowercased() == "true"
        image = vmDetail("image")
        command = vmDetail("command").split(whereSeparator: \.isWhitespace).map(String.init)
        platform = vmDetail("platform")
        initProcess = vmDetail("init", "false").lowercased() == "true"
        rosetta = vmDetail("rosetta", "false").lowercased() == "true"
        vmName = valueText(vmDetails["name"])
        cpus = valueUInt64(vmDetails["cpus"])
        memory = valueUInt64(vmDetails["minRam"])
        parameters = section(data["parameters"])
    }
}
