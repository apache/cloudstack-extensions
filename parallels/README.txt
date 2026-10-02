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

Parallels Desktop Orchestrator Extension
========================================

Orchestrator extension that lets Apache CloudStack manage virtual machines
in Parallels Desktop (https://www.parallels.com/products/desktop/) on macOS.
Each macOS machine running Parallels Desktop is added to CloudStack as a
host in a cluster mapped to this extension.

The script runs on the management server and drives Parallels Desktop on
the Mac through SSH, using its command line tool `prlctl`. When the
management server itself runs on the Mac (e.g. a development setup), the
host url can be "localhost" and no SSH is used.

Requirements
------------

Management server:
  - python3 (standard library only)
  - ssh client; sshpass only when password authentication is used

Mac:
  - Parallels Desktop Pro or Business Edition; prlctl refuses most commands
    on the Standard Edition ("The command is available only in Parallels
    Desktop for Mac Pro or Business Edition")
  - Remote Login (SSH) enabled for the user owning the Parallels VMs
  - One or more Parallels virtual machines or templates to clone from;
    Parallels Tools installed in them for graceful stop and IP reporting

Supported operations
--------------------

  create          Clone the template VM, name it after the CloudStack
                  instance's internal name, set CPU count, memory and NIC
                  MAC addresses (adding or removing NICs to match the
                  instance), then start it. The clone is removed again when
                  any step fails.
  start, stop, reboot, delete, status, statuses
                  stop shuts down gracefully and kills the VM when that
                  does not finish within wait_timeout
  getconsole      Not supported, prlctl has no VNC endpoint to hand out.

Custom actions (register them with addCustomAction):
  Suspend         Pause the VM in memory
  Resume          Resume a paused VM
  GetIpAddresses  List IP addresses reported by Parallels Tools
  ListSnapshots   List the VM's snapshots
  CreateSnapshot  Create a snapshot, parameter snapshot_name
  RestoreSnapshot Revert to a snapshot, parameter snapshot_name
  DeleteSnapshot  Delete a snapshot, parameter snapshot_name

Configuration details
---------------------

Extension or host details (host details win):
  url               Mac hostname/IP, or "localhost" to run locally
  username          SSH user owning the Parallels VMs; leave empty for local
  password          Optional SSH password (needs sshpass); keys preferred
  ssh_key           Optional private key path on the management server
  ssh_port          Optional, default 22
  verify_host_key   Optional, "true" (default) or "false"
  prlctl_path       Optional; by default /usr/local/bin/prlctl and the one in
                    /Applications/Parallels Desktop.app are tried, then the
                    Parallels Desktop bundle is looked up with Spotlight
  template_name     Optional default Parallels VM or template to clone
  linked_clone      Optional, "true" to create linked clones, default "false"
  network_mode      Optional: shared, bridged or host-only. When set it is
                    applied to every NIC, otherwise template NICs keep their
                    mode and additional NICs use shared
  bridge_interface  macOS interface for bridged mode, e.g. en0
  headless          Optional, "true" to start instances without a window
  wait_timeout      Optional, seconds to wait for state changes, default 120

Template, service offering or instance details:
  template_name     Parallels VM to clone, overrides the host/extension value

Setup
-----

1. Copy parallels.py to every management server:

     mkdir -p /usr/share/cloudstack-management/extensions/Parallels
     cp parallels.py /usr/share/cloudstack-management/extensions/Parallels/parallels.py
     chmod 755 /usr/share/cloudstack-management/extensions/Parallels/parallels.py
     chown -R cloud:cloud /usr/share/cloudstack-management/extensions/Parallels

   For SSH key authentication, create a key for the cloud user and add the
   public key to ~/.ssh/authorized_keys of the user on the Mac.

2. Register the extension and its custom actions (CloudMonkey):

     cmk create extension name=Parallels type=Orchestrator path=parallels.py
     cmk add customaction extensionid=<id> name=Suspend resourcetype=VirtualMachine
     cmk add customaction extensionid=<id> name=Resume resourcetype=VirtualMachine
     cmk add customaction extensionid=<id> name=GetIpAddresses resourcetype=VirtualMachine
     cmk add customaction extensionid=<id> name=ListSnapshots resourcetype=VirtualMachine
     for action in CreateSnapshot RestoreSnapshot DeleteSnapshot; do
       cmk add customaction extensionid=<id> name=$action resourcetype=VirtualMachine \
         parameters[0].name=snapshot_name parameters[0].type=STRING \
         parameters[0].validationformat=NONE parameters[0].required=true
     done

3. Create a cluster with hypervisor External, register the extension to it,
   and add each Mac as a host with url, username and (optionally) ssh_key,
   network_mode and bridge_interface as details.

4. Register a template with hypervisor External and extension Parallels,
   using a dummy url, and set the external detail template_name to the name
   of the Parallels VM to clone.

5. Deploy instances from that template.

Limitations
-----------

  - No VLAN isolation: Parallels Desktop cannot tag VLANs. Instances get the
    CloudStack MAC addresses and the configured network mode only, so the
    guest network must be reachable through the Mac's shared or bridged
    networking.
  - No console access.
  - The Parallels VM name equals the CloudStack internal instance name;
    renaming the VM in Parallels Desktop breaks the mapping.
  - Linked clones need a snapshot on the template VM.
  - Tested against prlctl 26.4 without a Pro license and without VMs
    (status, statuses, delete of a missing VM, error handling). create, NIC
    reconfiguration and the snapshot actions still need verification on a
    Pro/Business installation.
