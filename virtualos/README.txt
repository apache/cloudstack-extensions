Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.

virtualOS Orchestrator Extension
================================

Orchestrator extension that lets Apache CloudStack manage macOS virtual
machines in virtualOS (https://github.com/yep/virtualOS) on Apple silicon
Macs. Each Mac running virtualOS is added to CloudStack as a host in a
cluster mapped to this extension.

virtualOS has no command line interface or scripting dictionary. The script
therefore works on the virtualOS VM bundles directly and starts a VM by
launching a separate virtualOS process with the autostartVMBundlePath user
default passed as launch argument:

  open -n -g -a virtualOS --args -autostartVMBundlePath <dir>/<name>.bundle

Each running instance is one virtualOS process; stopping an instance
terminates that process. The extension is a Rust program that runs on the
management server and reaches the Mac through SSH. When the management server itself runs on the
Mac (e.g. a development setup), the host url can be "localhost" and no SSH
is used.

Requirements
------------

Management server:
  - The virtualos binary built for the management server's platform (see
    Building); it has no runtime dependencies besides the C library
  - ssh client; sshpass only when password authentication is used

Building:
  - A current stable Rust toolchain with cargo (https://rustup.rs)

Mac:
  - Apple silicon, virtualOS 3.0 or later (the autostart setting is used)
  - The SSH user logged in to the GUI session, virtualOS is a GUI app
  - Remote Login (SSH) enabled, with "Allow full disk access for remote
    users" when vm_directory is inside the virtualOS sandbox container
    (the default), as macOS protects other apps' containers
  - One or more installed macOS VMs in virtualOS to clone from, stopped
  - An APFS volume for vm_directory, so clones are copy-on-write

Supported operations
--------------------

  create          Clone the template VM bundle, name it after the CloudStack
                  instance's internal name, give it a new machine
                  identifier, set CPU count, memory (rounded up to whole
                  GiB), MAC address and network mode, then start it. The
                  clone is removed again when any step fails.
  start, stop, reboot, delete, status, statuses
                  start waits a few seconds and fails when virtualOS logs
                  an error for the VM; stop terminates the virtualOS
                  process, which powers the guest off without a shutdown
  getconsole      Not supported, virtualOS has no VNC endpoint to hand out.

Custom actions (register them with addCustomAction):
  GetIpAddresses  List the IP addresses the Mac's DHCP server leased to the
                  instance's MAC address (NAT network mode only)

Configuration details
---------------------

Extension or host details (host details win):
  url               Mac hostname/IP, or "localhost" to run locally
  username          SSH user owning the virtualOS VMs; leave empty for local
  password          Optional SSH password (needs sshpass); keys preferred
  ssh_key           Optional private key path on the management server
  ssh_port          Optional, default 22
  verify_host_key   Optional, "true" (default) or "false"
  app_path          Optional, default /Applications/virtualOS.app, falling
                    back to a Spotlight lookup of the app bundle
  vm_directory      Optional, directory holding the <name>.bundle VMs. It
                    must be the "VM files" directory configured in virtualOS
                    as the sandboxed app can not open bundles elsewhere.
                    Default: ~/Library/Containers/com.github.yep.ios.virtualOS
                    /Data/Documents
  template_name     Optional default VM bundle to clone, without .bundle
  network_mode      Optional: nat or bridged. When set it is applied to the
                    instance, otherwise the template's mode is kept
  bridge_interface  macOS interface for bridged mode, e.g. en0, or its
                    virtualOS name, e.g. "Wi-Fi (en0)"
  wait_timeout      Optional, seconds to wait for state changes, default 120

Template, service offering or instance details:
  template_name     VM bundle to clone, overrides the host/extension value

Setup
-----

1. In virtualOS, install a macOS VM to use as template, e.g. "macOS-15".
   Set it up as wanted (user account, Remote Login, ...) and shut it down.

2. Build the binary on (or for) the management server's platform, e.g. on
   a Linux management server:

     cargo build --release

   and copy it to every management server:

     mkdir -p /usr/share/cloudstack-management/extensions/virtualOS
     cp target/release/virtualos /usr/share/cloudstack-management/extensions/virtualOS/virtualos
     chmod 755 /usr/share/cloudstack-management/extensions/virtualOS/virtualos
     chown -R cloud:cloud /usr/share/cloudstack-management/extensions/virtualOS

   The unit tests run with "cargo test".

   For SSH key authentication, create a key for the cloud user and add the
   public key to ~/.ssh/authorized_keys of the user on the Mac.

3. Register the extension and its custom action (CloudMonkey):

     cmk create extension name=virtualOS type=Orchestrator path=virtualos
     cmk add customaction extensionid=<id> name=GetIpAddresses resourcetype=VirtualMachine

4. Create a cluster with hypervisor External, register the extension to it,
   and add each Mac as a host with url, username and (optionally) ssh_key,
   network_mode and bridge_interface as details.

5. Register a template with hypervisor External and extension virtualOS,
   using a dummy url, and set the external detail template_name to the name
   of the virtualOS VM to clone.

6. Deploy instances from that template, using a service offering with at
   least the CPU count and memory macOS needs (e.g. 2 CPUs, 4 GiB).

Limitations
-----------

  - One NIC per instance and no VLAN isolation: virtualOS configures a single
    NAT or bridged network device. Instances get the CloudStack MAC address
    only, so the guest network must be reachable through the Mac's NAT or
    bridged networking.
  - Apple's macOS license and the Virtualization framework allow at most
    two macOS VMs running at the same time per Mac.
  - No graceful shutdown: stop and reboot power the guest off.
  - Status is derived from the virtualOS process. When the guest shuts
    itself down, its virtualOS process keeps running and the instance is
    still reported as running until it is stopped from CloudStack. VMs
    started from the virtualOS window are not seen at all.
  - No console access, no root disk resizing and no snapshot support;
    virtualOS 3.0 only offers snapshots through its window.
  - The bundle name equals the CloudStack internal instance name; renaming
    the VM in virtualOS breaks the mapping.
  - Tested on macOS 26.6 with virtualOS 3.0 without an installed macOS
    guest: launching through the autostart argument, the start error
    detection with an invalid bundle, cloning, machine identifier and
    Parameters.txt generation, DHCP lease parsing, status, statuses and
    delete. Running a real macOS guest still needs verification.
