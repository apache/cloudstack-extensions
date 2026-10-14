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

import AppleContainerCore
import Foundation

var failures = 0
var current = ""

func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "", line: Int = #line) {
    do {
        if try !condition() {
            failures += 1
            print("  FAILED \(current) (line \(line)) \(message)")
        }
    } catch {
        failures += 1
        print("  FAILED \(current) (line \(line)) threw \(error)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures
    do {
        try body()
    } catch {
        failures += 1
        print("  FAILED \(name) threw \(error)")
    }
    print("test \(name) ... \(failures == before ? "ok" : "FAILED")")
}

func json(_ text: String) -> JSONObject {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSONObject ?? [:]
}

func config(_ data: JSONObject) throws -> Config {
    try Config(parsing: data)
}

/// Base payload with three NICs out of device order, plus the given virtualmachine details.
func base(_ vm: String = "{}") -> JSONObject {
    json("""
    {"externaldetails": {"extension": {"url": "localhost"},
                         "host": {"network": "default, isolated"},
                         "virtualmachine": \(vm)},
     "cloudstack.vm.details": {"name": "i-2-10-VM", "cpus": 2, "minRam": 1610612736,
                               "nics": [{"deviceId": 1, "mac": "02:00:0A:00:00:02"},
                                        {"deviceId": 0, "mac": "02:00:0a:00:00:01"},
                                        {"deviceId": 2, "mac": "02:00:0a:00:00:03"}]}}
    """)
}

func setting(_ data: JSONObject, _ section: String, _ key: String, _ value: Any) -> JSONObject {
    var data = data
    var external = data["externaldetails"] as? JSONObject ?? [:]
    var details = external[section] as? JSONObject ?? [:]
    details[key] = value
    external[section] = details
    data["externaldetails"] = external
    return data
}

test("quotes_shell_arguments") {
    check(shellQuote("i-2-10-VM") == "i-2-10-VM")
    check(shellQuote("") == "''")
    check(shellQuote("a b") == "'a b'")
    check(shellQuote("it's") == "'it'\"'\"'s'")
}

test("rounds_memory_up_to_mib") {
    check(memoryArgument(1610612736) == "1536M")
    check(memoryArgument(1024 * 1024 + 1) == "2M")
    check(memoryArgument(0) == "1M")
}

test("repeats_last_network_for_extra_nics") {
    check(nicNetworks(["a", "b"], nicCount: 3) == ["a", "b", "b"])
    check(nicNetworks(["a", "b"], nicCount: 0) == ["a"])
    check(nicNetworks([], nicCount: 2) == ["default", "default"])
}

test("parses_details") {
    let c = try config(base(#"{"image": "alpine:3.22", "command": "sleep  infinity", "init": "TRUE"}"#))
    check(c.local)
    check(c.containerPath == defaultContainerPath)
    check(c.networks == ["default", "isolated"])
    check(c.nics.map(\.mac) == ["02:00:0a:00:00:01", "02:00:0A:00:00:02", "02:00:0a:00:00:03"])
    check(c.nics.allSatisfy { $0.vmnet == nil })
    check(c.command == ["sleep", "infinity"])
    check(c.initProcess)
    check(!c.rosetta)
    check(c.waitTimeout == 60)
    check(c.startService)
    check(c.memory == 1610612736)
    check((try? config(json(#"{"externaldetails": {"extension": {"url": "mac"}}}"#))) == nil, "username required")
    check((try? config(json(#"{"externaldetails": {"extension": {"url": "localhost", "wait_timeout": "x"}}}"#))) == nil,
          "invalid wait_timeout")
    check(try config(setting(base(), "host", "ssh_port", 2222)).sshPort == "2222", "numeric detail")
    check(try !config(setting(base(), "host", "start_service", false)).startService, "boolean detail")
}

test("instance_image_overrides_host_default") {
    check(try config(setting(base(#"{"image": "alpine:3.22"}"#), "host", "image", "ubuntu:24.04")).image == "alpine:3.22")
    check(try config(setting(base(), "extension", "image", "ubuntu:24.04")).image == "ubuntu:24.04")
}

test("builds_create_arguments") {
    let manager = ContainerManager(config: try config(
        base(#"{"image": "alpine:3.22", "command": "sleep infinity", "init": "true"}"#)))
    check(manager.createArguments() == [
        "create", "--name", "i-2-10-VM", "--label", "org.apache.cloudstack.managed=true",
        "--cpus", "2", "--memory", "1536M",
        "--network", "default,mac=02:00:0a:00:00:01",
        "--network", "isolated,mac=02:00:0a:00:00:02",
        "--network", "isolated,mac=02:00:0a:00:00:03",
        "--init", "alpine:3.22", "sleep", "infinity",
    ], "\(manager.createArguments())")
}

test("parses_vmnet_broadcast_uris") {
    check(try vmnetNetwork("vs://cs-net-42?mode=nat") == VmnetNetwork(name: "cs-net-42", isInternal: false))
    check(try vmnetNetwork("vs://cs-net-7?mode=internal") == VmnetNetwork(name: "cs-net-7", isInternal: true))
    check(try vmnetNetwork("vs://cs-net-7") == VmnetNetwork(name: "cs-net-7", isInternal: false))
    check(try vmnetNetwork("vlan://300") == nil)
    check(try vmnetNetwork("") == nil)
    for invalid in ["vs://cs-net-7?mode=bridged", "vs://Bad_Name", "vs://"] {
        check((try? vmnetNetwork(invalid)) == nil, invalid)
    }
}

test("attaches_vmnet_nics_to_their_own_networks") {
    var data = base(#"{"image": "alpine:3.22"}"#)
    var vmDetails = data["cloudstack.vm.details"] as? JSONObject ?? [:]
    vmDetails["nics"] = json(#"""
    {"nics": [{"deviceId": 0, "mac": "02:00:0a:00:00:01", "broadcastUri": "vs://cs-net-42?mode=internal"},
              {"deviceId": 1, "mac": "02:00:0a:00:00:02", "broadcastUri": "vlan://300"},
              {"deviceId": 2, "mac": "02:00:0a:00:00:03", "broadcastUri": "vs://cs-net-42?mode=internal"}]}
    """#)["nics"]
    data["cloudstack.vm.details"] = vmDetails
    let manager = ContainerManager(config: try config(data))
    check(manager.vmnetNetworks() == [VmnetNetwork(name: "cs-net-42", isInternal: true)])
    let args = manager.createArguments()
    let networks = zip(args, args.dropFirst()).filter { $0.0 == "--network" }.map(\.1)
    check(networks == [
        "cs-net-42,mac=02:00:0a:00:00:01", "isolated,mac=02:00:0a:00:00:02", "cs-net-42,mac=02:00:0a:00:00:03",
    ], "\(networks)")
}

test("rejects_unsafe_instance_names") {
    for name in ["", "-rf", "../x", "a b"] {
        var data = base()
        var vmDetails = data["cloudstack.vm.details"] as? JSONObject ?? [:]
        vmDetails["name"] = name
        data["cloudstack.vm.details"] = vmDetails
        let manager = ContainerManager(config: try config(data))
        check((try? manager.requireVMName()) == nil, name)
    }
}

test("rejects_unsupported_operations_before_reading_details") {
    do {
        _ = try execute(operation: "com.cloud.agent.api.getvmipaddresscommand", jsonFilePath: "/nonexistent.json")
        check(false, "no error")
    } catch let error as ExtensionError {
        check(error.message == "Operation not supported: com.cloud.agent.api.getvmipaddresscommand", error.message)
    }
    do {
        _ = try execute(operation: "statuses", jsonFilePath: "/nonexistent.json")
        check(false, "no error")
    } catch let error as ExtensionError {
        check(error.message.hasPrefix("JSON file not found"), error.message)
    }
}

test("reads_container_snapshots") {
    let current = json("""
    {"configuration": {"id": "i-2-10-VM", "labels": {"\(managedLabel)": "true"}},
     "status": "running",
     "networks": [{"network": "default", "hostname": "i-2-10-VM",
                   "ipv4Address": "192.168.64.3/24", "ipv4Gateway": "192.168.64.1",
                   "ipv6Address": "fd00::3/64"}]}
    """)
    check(containerID(current) == "i-2-10-VM")
    check(powerState(containerState(current)) == "poweron")
    check(isManaged(current))
    check(ipAddresses(current) == ["192.168.64.3", "fd00::3"])
    check(networkNames(current) == ["default"])
    let stopped = json("""
    {"configuration": {"id": "i-2-11-VM", "networks": [{"network": "cs-net-42", "options": {}},
                                                       {"network": "default", "options": {}}]},
     "status": "stopped"}
    """)
    check(networkNames(stopped) == ["cs-net-42", "default"])

    let listed = json("""
    {"configuration": {"id": "buildkit", "labels": {}},
     "status": {"state": "stopped", "networks": [{"address": "192.168.64.2/24"}]}}
    """)
    check(powerState(containerState(listed)) == "poweroff")
    check(!isManaged(listed))
    check(ipAddresses(listed) == ["192.168.64.2"])
    check(powerState("unknown") == "unknown")
}

print(failures == 0 ? "test result: ok" : "test result: FAILED, \(failures) failed checks")
exit(failures == 0 ? 0 : 1)
