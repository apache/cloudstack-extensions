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

import Foundation

/// Output of a child process, filled in by the threads draining its pipes.
private final class ProcessOutput: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}

public struct ContainerManager {
    public var config: Config

    public init(config: Config) {
        self.config = config
    }

    func sshCommand(_ remoteArgv: [String]) -> [String] {
        let c = config
        var cmd = [
            "ssh",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=\(c.verifyHostKey ? "yes" : "no")",
            "-p", c.sshPort,
        ]
        if !c.verifyHostKey {
            cmd += ["-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"]
        }
        if !c.sshKey.isEmpty {
            cmd += ["-i", c.sshKey]
        }
        if !c.password.isEmpty {
            cmd.insert(contentsOf: ["sshpass", "-e"], at: 0)
            cmd += ["-o", "BatchMode=no"]
        } else {
            cmd += ["-o", "BatchMode=yes"]
        }
        cmd.append("\(c.username)@\(c.url)")
        cmd.append("--")
        cmd.append(remoteArgv.map(shellQuote).joined(separator: " "))
        return cmd
    }

    func run(_ argv: [String], timeout: TimeInterval) throws -> String {
        let cmd = config.local ? argv : sshCommand(argv)
        let process = Process()
        if cmd[0].contains("/") {
            guard FileManager.default.isExecutableFile(atPath: cmd[0]) else {
                throw ExtensionError("Command not found: \(cmd[0])")
            }
            process.executableURL = URL(fileURLWithPath: cmd[0])
            process.arguments = Array(cmd.dropFirst())
        } else {
            // let env search PATH, like a shell would
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = cmd
        }
        if !config.local && !config.password.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            environment["SSHPASS"] = config.password
            process.environment = environment
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ExtensionError("Failed to run \(cmd[0]): \(error.localizedDescription)")
        }
        // drain both pipes while the process runs, a full pipe would block it
        let output = ProcessOutput()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) {
            output.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: readers) {
            output.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            throw ExtensionError("Timed out running: \(argv.joined(separator: " "))")
        }
        readers.wait()

        let stdout = String(decoding: output.stdout, as: UTF8.self)
        let status = process.terminationStatus
        if status == 127 && !cmd[0].contains("/") {
            throw ExtensionError("Command not found: \(cmd[0])")
        }
        if status != 0 {
            let stderr = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
            throw ExtensionError(message.isEmpty ? "'\(argv.joined(separator: " "))' exited with \(status)" : message)
        }
        return stdout
    }

    /// Run the container tool with the given arguments, waiting at most the given seconds.
    func container(_ args: [String], seconds: UInt64? = nil) throws -> String {
        let seconds = seconds ?? config.waitTimeout
        return try run([config.containerPath] + args, timeout: TimeInterval(seconds + 30))
    }

    public func requireVMName() throws {
        let name = config.vmName
        if name.isEmpty {
            throw ExtensionError("Missing required field in JSON: cloudstack.vm.details.name")
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if !name.allSatisfy({ allowed.contains($0) }) || name.hasPrefix(".") || name.hasPrefix("-") {
            throw ExtensionError("Invalid instance name '\(name)'")
        }
    }

    /// Start the container system service, without installing a kernel as that prompts.
    func startService() throws {
        do {
            _ = try container(["system", "start", "--disable-kernel-install", "--timeout", "\(config.waitTimeout)"])
        } catch let error as ExtensionError {
            throw ExtensionError("The container system service is not running and failed to start: \(error.message)")
        }
    }

    /// All containers, running or not, keyed by container ID. Containers do
    /// not survive the system service, so when it is down it is started to
    /// report them as stopped instead of failing.
    func listContainers() throws -> [String: JSONObject] {
        let args = ["list", "--all", "--format", "json"]
        let output: String
        do {
            output = try container(args)
        } catch let error as ExtensionError where config.startService && error.message.contains(serviceDownHint) {
            try startService()
            output = try container(args)
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(output.utf8))
        } catch {
            throw ExtensionError("Failed to parse the container list: \(error.localizedDescription)")
        }
        var containers: [String: JSONObject] = [:]
        for snapshot in parsed as? [JSONObject] ?? [] {
            containers[containerID(snapshot)] = snapshot
        }
        return containers
    }

    func findContainer() throws -> JSONObject? {
        try listContainers()[config.vmName]
    }

    func requireContainer() throws -> JSONObject {
        guard let snapshot = try findContainer() else {
            throw ExtensionError("Container '\(config.vmName)' not found")
        }
        return snapshot
    }

    public func createArguments() -> [String] {
        let c = config
        var args = ["create", "--name", c.vmName, "--label", "\(managedLabel)=true"]
        if let cpus = c.cpus {
            args += ["--cpus", "\(max(cpus, 1))"]
        }
        if let memory = c.memory {
            args += ["--memory", memoryArgument(memory)]
        }
        for (i, network) in nicNetworks(c.networks, nicCount: c.nics.count).enumerated() {
            let nic = i < c.nics.count ? c.nics[i] : nil
            let network = nic?.vmnet?.name ?? network
            if let nic, !nic.mac.isEmpty {
                args += ["--network", "\(network),mac=\(nic.mac.lowercased())"]
            } else {
                args += ["--network", network]
            }
        }
        if !c.platform.isEmpty {
            args += ["--platform", c.platform]
        }
        if c.initProcess {
            args.append("--init")
        }
        if c.rosetta {
            args.append("--rosetta")
        }
        args.append(c.image)
        args += c.command
        return args
    }

    /// The distinct vmnet extension networks of the instance's NICs.
    public func vmnetNetworks() -> [VmnetNetwork] {
        var networks: [VmnetNetwork] = []
        for network in config.nics.compactMap(\.vmnet) where !networks.contains(where: { $0.name == network.name }) {
            networks.append(network)
        }
        return networks
    }

    /// All container networks keyed by name.
    func listNetworks() throws -> [String: JSONObject] {
        let output = try container(["network", "list", "--format", "json"])
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(output.utf8))
        } catch {
            throw ExtensionError("Failed to parse the network list: \(error.localizedDescription)")
        }
        var networks: [String: JSONObject] = [:]
        for network in parsed as? [JSONObject] ?? [] {
            networks[valueText(network["id"])] = network
        }
        return networks
    }

    /// Create the vmnet extension networks the instance needs and that do not
    /// exist yet. An existing network is only used when CloudStack created it.
    func ensureNetworks() throws {
        let wanted = vmnetNetworks()
        if wanted.isEmpty {
            return
        }
        let existing = try listNetworks()
        for network in wanted {
            if let found = existing[network.name] {
                if isManaged(found) {
                    continue
                }
                throw ExtensionError("Container network '\(network.name)' exists but was not created by CloudStack")
            }
            var args = ["network", "create", "--label", "\(managedLabel)=true"]
            if network.isInternal {
                args.append("--internal")
            }
            args.append(network.name)
            do {
                _ = try container(args)
            } catch let error as ExtensionError {
                // Another instance may have created it meanwhile.
                if !(try listNetworks()[network.name].map(isManaged) ?? false) {
                    throw ExtensionError("Failed to create container network '\(network.name)': \(error.message)")
                }
            }
        }
    }

    /// Delete the given networks when CloudStack created them and no other
    /// container uses them; the container tool refuses to delete networks in use.
    func deleteUnusedNetworks(_ names: [String]) throws {
        if names.isEmpty {
            return
        }
        let existing = try listNetworks()
        for name in names where existing[name].map(isManaged) ?? false {
            _ = try? container(["network", "delete", name])
        }
    }

    func pullImage() throws {
        var args = ["image", "pull", "--progress", "none"]
        if !config.platform.isEmpty {
            args += ["--platform", config.platform]
        }
        args.append(config.image)
        do {
            _ = try container(args, seconds: config.pullTimeout)
        } catch let error as ExtensionError {
            throw ExtensionError("Failed to pull image '\(config.image)': \(error.message)")
        }
    }

    func startContainer() throws {
        _ = try container(["start", config.vmName])
    }

    func stopContainer() throws {
        _ = try container(["stop", "--time", "\(config.waitTimeout)", config.vmName])
    }

    func deleteContainer() throws {
        _ = try container(["delete", "--force", config.vmName])
    }

    func create() throws -> JSONObject {
        try requireVMName()
        let name = config.vmName
        if config.image.isEmpty {
            throw ExtensionError("Missing required field in JSON: image")
        }
        if config.cpus == nil || config.memory == nil {
            throw ExtensionError("Missing CPU or memory in cloudstack.vm.details")
        }
        if try findContainer() != nil {
            throw ExtensionError("A container named '\(name)' already exists")
        }
        try pullImage()
        try ensureNetworks()
        _ = try container(createArguments())
        do {
            try startContainer()
        } catch let error as ExtensionError {
            try? deleteContainer()
            throw ExtensionError("Failed to start container '\(name)': \(error.message)")
        }
        return successMessage("Instance created")
    }

    func start() throws -> JSONObject {
        try requireVMName()
        if containerState(try requireContainer()) != "running" {
            try ensureNetworks()
            try startContainer()
        }
        return successMessage("Instance started")
    }

    func stop() throws -> JSONObject {
        try requireVMName()
        if let snapshot = try findContainer(), containerState(snapshot) != "stopped" {
            try stopContainer()
        }
        return successMessage("Instance stopped")
    }

    func reboot() throws -> JSONObject {
        try requireVMName()
        if containerState(try requireContainer()) != "stopped" {
            try stopContainer()
        }
        try ensureNetworks()
        try startContainer()
        return successMessage("Instance rebooted")
    }

    func delete() throws -> JSONObject {
        try requireVMName()
        if let snapshot = try findContainer() {
            // The expunge payload has no NICs, so take the networks from the container.
            let networks = networkNames(snapshot)
            try deleteContainer()
            // Best effort: a leftover network is reused or deleted with a later instance.
            try? deleteUnusedNetworks(networks)
        }
        return successMessage("Instance deleted")
    }

    func status() throws -> JSONObject {
        try requireVMName()
        let state = try findContainer().map { powerState(containerState($0)) } ?? "unknown"
        return ["status": "success", "power_state": state]
    }

    func statuses() throws -> JSONObject {
        var powerStates: JSONObject = [:]
        for (id, snapshot) in try listContainers() where isManaged(snapshot) {
            powerStates[id] = powerState(containerState(snapshot))
        }
        return ["status": "success", "power_state": powerStates]
    }

    func getIPAddresses() throws -> JSONObject {
        try requireVMName()
        return ["status": "success", "printmessage": "true", "message": ipAddresses(try requireContainer())]
    }

    func getLogs() throws -> JSONObject {
        try requireVMName()
        let lines = valueUInt64(config.parameters["lines"]) ?? defaultLogLines
        var args = ["logs", "-n", "\(lines)"]
        if valueText(config.parameters["boot"]).lowercased() == "true" {
            args.append("--boot")
        }
        args.append(config.vmName)
        return ["status": "success", "printmessage": "true", "message": try container(args)]
    }
}

public func execute(operation: String, jsonFilePath: String) throws -> JSONObject {
    // CloudStack also passes commands it has no extension operation for, such as
    // com.cloud.agent.api.GetVmIpAddressCommand, without host details.
    guard operations.contains(operation) else {
        throw ExtensionError("Operation not supported: \(operation)")
    }
    guard let content = FileManager.default.contents(atPath: jsonFilePath) else {
        let exists = FileManager.default.fileExists(atPath: jsonFilePath)
        throw ExtensionError(exists ? "Failed to read \(jsonFilePath)" : "JSON file not found: \(jsonFilePath)")
    }
    guard let data = (try? JSONSerialization.jsonObject(with: content)) as? JSONObject else {
        throw ExtensionError("Invalid JSON in file")
    }
    let manager = ContainerManager(config: try Config(parsing: data))

    switch operation {
    case "create": return try manager.create()
    case "start": return try manager.start()
    case "stop": return try manager.stop()
    case "reboot": return try manager.reboot()
    case "delete": return try manager.delete()
    case "status": return try manager.status()
    case "statuses": return try manager.statuses()
    case "getconsole": throw ExtensionError("Operation not supported")
    case "getipaddresses": return try manager.getIPAddresses()
    case "getlogs": return try manager.getLogs()
    default: preconditionFailure("operation \(operation) is checked above")
    }
}

/// One line of JSON, as CloudStack reads the extension's standard output.
public func jsonLine(_ object: JSONObject) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}
