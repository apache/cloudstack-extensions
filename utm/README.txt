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
                  clone is removed again when any step fails.
  start, stop, reboot, delete, status, statuses
  getconsole      Not supported, UTM has no VNC endpoint to hand out.

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
  wait_timeout      Optional, seconds to wait for state changes, default 120

Template, service offering or instance details:
  template_name     UTM VM to clone, overrides the host/extension value

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
    must be reachable through the Mac's shared or bridged networking.
  - No console access and no snapshots (neither is exposed by utmctl or
    UTM's AppleScript dictionary).
  - The UTM VM name equals the CloudStack internal instance name; renaming
    the VM in UTM breaks the mapping.
  - Tested against UTM 4.6.4 (clone, configure, status, delete). Starting
    VMs through Apple Events was refused by the sandboxed UTM build used for
    testing ("Operation not permitted"), so start/reboot/resume still need
    verification on a UTM installation that allows scripted starts.
