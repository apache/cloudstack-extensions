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

Apple container Orchestrator Extension
======================================

Orchestrator extension that lets Apache CloudStack run Linux instances with
Apple container (https://github.com/apple/container) on Apple silicon Macs.
Apple container runs every container from an OCI image in its own
lightweight virtual machine, so each CloudStack instance gets its own Linux
kernel. Each Mac running the container system service is added to
CloudStack as a host in a cluster mapped to this extension.

The extension is a Rust program that runs on the management server and
drives the "container" command line tool on the Mac through SSH. Every
CloudStack instance is one container named after the instance's internal
name (e.g. i-2-10-VM) and labelled org.apache.cloudstack.managed=true. When
the management server itself runs on the Mac (e.g. a development setup),
the host url can be "localhost" and no SSH is used.

Requirements
------------

Management server:
  - The apple-container binary built for the management server's platform
    (see Setup); it has no runtime dependencies besides the C library
  - ssh client; sshpass only when password authentication is used

Building:
  - A current stable Rust toolchain with cargo (https://rustup.rs)

Mac:
  - Apple silicon, macOS 26 or later
  - Apple container 1.5 or later, installed from the signed package on
    https://github.com/apple/container/releases, with the system service
    started by the SSH user: container system start
  - Remote Login (SSH) enabled for that user

Supported operations
--------------------

  create          Pull the image, create a container with the instance's CPU
                  count, memory (rounded up to whole MiB), one network
                  attachment per NIC with the CloudStack MAC address, then
                  start it. The container is removed again when it fails
                  to start. See Networks for which network each NIC uses.
  start, stop, reboot, delete, status, statuses
                  stop sends SIGTERM and kills the container after
                  wait_timeout seconds; statuses reports only containers
                  carrying the CloudStack label. Containers stop together
                  with the container system service, so when the service is
                  not running it is started first (see start_service) and
                  its containers are reported as stopped, instead of
                  CloudStack seeing an unknown power state.
  getconsole      Not supported, Apple container has no VNC endpoint.
                  Other operations CloudStack passes through, such as its
                  periodic GetVmIpAddressCommand, are answered with
                  "Operation not supported".

Custom actions (register them with addCustomAction):
  GetIpAddresses  List the IPv4/IPv6 addresses of the instance's network
                  attachments
  GetLogs         Show the last lines of the container output. Optional
                  parameters: lines (default 100), boot ("true" shows the
                  VM boot log instead)

Configuration details
---------------------

Extension or host details (host details win):
  url               Mac hostname/IP, or "localhost" to run locally
  username          SSH user running the container system service; leave
                    empty for local
  password          Optional SSH password (needs sshpass); keys preferred
  ssh_key           Optional private key path on the management server
  ssh_port          Optional, default 22
  verify_host_key   Optional, "true" (default) or "false"
  container_path    Optional, default /usr/local/bin/container
  network           Optional, comma separated container networks, one per
                    NIC in device order; the last one is used for further
                    NICs. Default: default. Create other networks with
                    "container network create <name>". Not used for NICs on
                    vmnet extension networks (see Networks).
  wait_timeout      Optional, seconds a stop waits before killing the
                    container, and the limit for other commands, default 60
  pull_timeout      Optional, seconds an image pull may take, default 900
  start_service     Optional, "true" (default) starts the container system
                    service when a command finds it not running

Template, service offering or instance details (instance details win; they
can also be set on the host or extension as defaults):
  image             OCI image reference, e.g. docker.io/library/alpine:3.22
  command           Optional command line replacing the image's default
                    arguments, split on whitespace, e.g. "sleep infinity"
  platform          Optional image platform, e.g. linux/amd64
  init              Optional, "true" runs an init process in the container
                    that reaps zombies and forwards signals
  rosetta           Optional, "true" enables Rosetta, for linux/amd64 images

Networks
--------

A NIC on a CloudStack network of the vmnet network extension (an L2 network
whose broadcast URI looks like vs://cs-net-42?mode=nat, see the vmnet
extension's README.txt) is attached to the container network of that name.
That network gets one vmnet network per CloudStack network, so instances on
different CloudStack networks are isolated from each other:

  - It is created with "container network create", labelled
    org.apache.cloudstack.managed=true and with --internal for mode
    internal, before an instance using it is created, started or rebooted.
    A network of that name not created by CloudStack is not used, and the
    instance fails to deploy.
  - It is deleted when an instance using it is deleted and no other
    container uses it any more.

Any other NIC uses the network detail: the container network at its
position in the list, the last one for further NICs.

Setup
-----

1. On the Mac, install Apple container and start its system service as the
   user CloudStack will connect as:

     container system start --enable-kernel-install

   The service does not start again by itself after a reboot or logout.
   The extension starts it when it finds it down, but only once CloudStack
   asks for a status (about once a minute), and starting it over SSH is not
   verified yet. To start it at login instead, create a launchd
   agent ~/Library/LaunchAgents/org.apache.cloudstack.container.plist:

     <?xml version="1.0" encoding="UTF-8"?>
     <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
       "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
     <plist version="1.0">
     <dict>
       <key>Label</key><string>org.apache.cloudstack.container</string>
       <key>ProgramArguments</key>
       <array>
         <string>/usr/local/bin/container</string>
         <string>system</string>
         <string>start</string>
         <string>--disable-kernel-install</string>
       </array>
       <key>RunAtLoad</key><true/>
     </dict>
     </plist>

   and load it with: launchctl load ~/Library/LaunchAgents/org.apache.cloudstack.container.plist

2. Build the binary on (or for) the management server's platform, e.g. on
   a Linux management server:

     cargo build --release

   and copy it to every management server:

     mkdir -p /usr/share/cloudstack-management/extensions/apple-container
     cp target/release/apple-container /usr/share/cloudstack-management/extensions/apple-container/apple-container
     chmod 755 /usr/share/cloudstack-management/extensions/apple-container/apple-container
     chown -R cloud:cloud /usr/share/cloudstack-management/extensions/apple-container

   The unit tests run with "cargo test".

   For SSH key authentication, create a key for the cloud user and add the
   public key to ~/.ssh/authorized_keys of the user on the Mac.

3. Register the extension and its custom actions (CloudMonkey):

     cmk create extension name=apple-container type=Orchestrator path=apple-container
     cmk add customaction extensionid=<id> name=GetIpAddresses resourcetype=VirtualMachine
     cmk add customaction extensionid=<id> name=GetLogs resourcetype=VirtualMachine

4. Create a cluster with hypervisor External, register the extension to it,
   and add each Mac as a host with url, username and (optionally) ssh_key
   and network as details.

5. Register a template with hypervisor External and extension
   apple-container, using a dummy url, and set the external detail image to
   the OCI image to run, plus command when the image's default command
   exits right away (e.g. image=alpine:3.22, command=sleep infinity).

6. Deploy instances from that template.

Limitations
-----------

  - Instances are containers: the image's command is the container's main
    process and the instance stops when it exits. Use an image with a long
    running command, a command detail such as "sleep infinity", or an image
    with an init system.
  - Networking is limited to container (vmnet) networks on the Mac: no VLAN
    isolation, only networks of the vmnet network extension or ones
    created by hand, and CloudStack does not manage the IP addresses. Apple
    container assigns them, possibly a different IPv4 address on every
    start; GetIpAddresses reports the current ones. The IPv6 address is
    derived from the MAC address and stays the same.
  - The command detail is split on whitespace, quoting is not supported.
  - Changing the service offering is not applied to an existing container.
  - No console access, no volumes and no snapshot support.
  - The container name equals the CloudStack internal instance name;
    renaming or recreating it outside CloudStack breaks the mapping.
  - Tested on macOS 26.6 with Apple container 1.5.0, locally (url
    localhost): deploy, stop, start, reboot and destroy from CloudStack,
    the CloudStack MAC address inside the guest, GetIpAddresses and GetLogs
    with alpine:3.22 and command "sleep infinity"; and with a vmnet
    extension network in mode internal: two instances reach each other but
    not the internet, the network is created with the first instance and
    deleted with the last. SSH to a remote Mac and multiple NICs still need
    verification.
