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

UTM Orchestrator Extension
==========================

Orchestrator extension that lets Apache CloudStack manage virtual machines
in UTM (https://mac.getutm.app), the QEMU / Apple Virtualization front end
for macOS. Each macOS machine running UTM is added to CloudStack as a host
in a cluster mapped to this extension.

The script runs on the management server and drives UTM on the Mac through
SSH, using UTM's command line tool `utmctl` and its AppleScript interface
(`osascript`). When the management server itself runs on the Mac (e.g. a
development setup), the host url can be "localhost" and no SSH is used.

Requirements
------------

Management server:
  - python3 (standard library only)
  - ssh client; sshpass only when password authentication is used

Mac:
  - UTM 4.x with a logged-in GUI session of the configured user; UTM is
    controlled through Apple Events, which need that session
  - Remote Login (SSH) enabled for that user
  - The SSH session must be allowed to control UTM. If commands fail with
    "OSStatus error -1743", grant the permission under System Settings >
    Privacy & Security > Automation (run a utmctl command once from an SSH
    session to get the prompt)
  - One or more UTM virtual machines prepared as templates

Supported operations
--------------------

  create          Clone the template VM (APFS clone, so it is cheap), name it
                  after the CloudStack instance's internal name, set CPU
                  cores, memory and NIC MAC addresses, then start it. The
                  clone is removed again when any step fails. See Networks
                  for how the NICs are connected.
  start, stop, reboot, delete, status, statuses
  getconsole      Only with console_url set (see Configuration details):
                  returns console_url with the instance's websocket port and
                  name as a direct console. The QEMU console arguments are
                  applied when the VM is created or started while stopped.

Custom actions (register them with addCustomAction, no parameters):
  Suspend         Pause the VM in memory
  Resume          Resume a suspended VM
  GetIpAddresses  List IP addresses reported by the QEMU guest agent

Configuration details
---------------------

Extension or host details (host details win):
  url               Mac hostname/IP, or "localhost" to run locally
  username          SSH user owning the UTM library; leave empty for local
  password          Optional SSH password (needs sshpass); keys preferred
  ssh_key           Optional private key path on the management server
  ssh_port          Optional, default 22
  verify_host_key   Optional, "true" (default) or "false"
  utmctl_path       Optional; by default /Applications/UTM.app is tried,
                    then the UTM bundle is looked up with Spotlight
  template_name     Optional default UTM VM to clone
  network_mode      Optional: shared, bridged, host or emulated (QEMU
                    backend; Apple Virtualization VMs only support shared
                    and bridged). When set it is applied to every NIC,
                    otherwise template NICs keep their mode and additional
                    NICs use shared
  bridge_interface  macOS interface for bridged mode, e.g. en0
  isolated_network_uuid
                    Optional UUID of a private vmnet host-only segment (QEMU
                    backend). When set, NICs that are not on a vmnet
                    extension network are attached to it instead of using
                    network_mode; VMs with the same UUID share one L2
                    segment without DHCP server or host address
  wait_timeout      Optional, seconds to wait for state changes, default 120
  console_url       Optional URL of a noVNC page that takes ?port=<websocket
                    port>. When set, each instance gets a QEMU VNC server on
                    127.0.0.1 with a websocket, showing its serial console as
                    a text console, and getconsole returns this URL as a
                    direct console (QEMU backend only)
  console_websocket_base
                    Optional, websocket port = this + instance id, default 5700
  console_vnc_display_base
                    Optional, VNC display = this + instance id, default 200

Template, service offering or instance details:
  template_name     UTM VM to clone, overrides the host/extension value

Networks
--------

Without further configuration the NICs use UTM's network modes (see
network_mode). The QEMU backend can also attach them to private vmnet
host-only segments: L2 segments on the Mac, without DHCP server and without
a host address, that only VMs with the same segment UUID share.

  - A NIC on a CloudStack network of the vmnet network extension (an L2
    network whose broadcast URI looks like vs://cs-net-42?mode=internal,
    see the vmnet extension's README.txt) gets a segment of its own, with a
    UUID derived from the network name. All instances on that CloudStack
    network on the same Mac share it, and other networks cannot reach it.
    Only mode internal is supported, deploying to a nat network fails.
  - With isolated_network_uuid set, the other NICs are attached to that
    segment, e.g. one served by a router VM.
  - Otherwise, when at least one NIC is on a vmnet extension network, the
    other NICs use vmnet-shared, vmnet-host or vmnet-bridged according to
    network_mode (emulated is not supported then).

These NICs are passed to QEMU as additional arguments (-netdev/-device with
ids csnic1, csnic2, ...) in place of UTM's network interfaces. Guests need
their addresses configured by other means than DHCP, for instance a second
NIC on a network with DHCP.

Setup
-----

1. Copy utm.py to every management server:

     mkdir -p /usr/share/cloudstack-management/extensions/UTM
     cp utm.py /usr/share/cloudstack-management/extensions/UTM/utm.py
     chmod 755 /usr/share/cloudstack-management/extensions/UTM/utm.py
     chown -R cloud:cloud /usr/share/cloudstack-management/extensions/UTM

   For SSH key authentication, create a key for the cloud user and add the
   public key to ~/.ssh/authorized_keys of the user on the Mac.

2. Register the extension and its custom actions (CloudMonkey):

     cmk create extension name=UTM type=Orchestrator path=utm.py
     cmk add customaction extensionid=<id> name=Suspend resourcetype=VirtualMachine
     cmk add customaction extensionid=<id> name=Resume resourcetype=VirtualMachine
     cmk add customaction extensionid=<id> name=GetIpAddresses resourcetype=VirtualMachine

3. Create a cluster with hypervisor External, register the extension to it,
   and add each Mac as a host with url, username and (optionally) ssh_key,
   network_mode and bridge_interface as details.

4. Register a template with hypervisor External and extension UTM, using a
   dummy url, and set the external detail template_name to the name of the
   UTM VM to clone.

5. Deploy instances from that template.

Limitations
-----------

  - No VLAN isolation: UTM cannot tag VLANs. Instances get the CloudStack
    MAC addresses and the configured network mode only, so the guest network
    must be reachable through the Mac's shared or bridged networking, unless
    vmnet extension networks or isolated_network_uuid are used (see
    Networks), which are local to one Mac.
  - No snapshots (not exposed by utmctl or UTM's AppleScript dictionary).
  - Console access only through console_url, as a text console on the
    guest's serial port, and only for the QEMU backend.
  - The UTM VM name equals the CloudStack internal instance name; renaming
    the VM in UTM breaks the mapping.
  - Tested against UTM 4.6.4 (clone, configure, status, delete). Starting
    VMs through Apple Events was refused by the sandboxed UTM build used for
    testing ("Operation not permitted"), so start/reboot/resume still need
    verification on a UTM installation that allows scripted starts.
