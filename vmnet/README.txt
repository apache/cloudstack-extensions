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

vmnet Network Extension
=======================

NetworkOrchestrator extension that gives CloudStack L2 networks to the
orchestrator extensions running instances on Macs, as macOS vmnet
networks. Each CloudStack network becomes its own vmnet network, so
instances on different CloudStack networks cannot reach each other.

The networks are local to the Macs, so this extension only names them.
When CloudStack implements a network, the script returns the vmnet network
name and mode, which CloudStack stores as the network's broadcast URI:

  vs://cs-net-<network id>?mode=<nat|internal>

Every NIC of an instance carries that URI. The orchestrator extension
running the instance reads it, creates the vmnet network on the Mac the
first time an instance needs it, attaches the NIC to it, and deletes the
network with its last instance.

Orchestrator extensions that read these URIs:
  apple-container   container networks ("container network create")

Requirements
------------

Management server:
  - python3, the script uses only the standard library
  - CloudStack with NetworkOrchestrator extensions

Mac: whatever the orchestrator extension needs; for apple-container, macOS
26 or later, which can create vmnet networks with their own subnet.

Supported networks and services
-------------------------------

  - L2 networks only. The vmnet networks hand out their own IP addresses
    with DHCP, so CloudStack cannot manage the addresses of Isolated or
    Shared networks; implementing such a network fails.
  - Modes: nat, where instances reach the outside world through the Mac,
    and internal (host-only), where they reach only the Mac and each other.
  - UserData is declared but not delivered yet. CloudStack only uses an
    extension for networks whose offering names it as a service provider,
    and L2 offerings may only have the UserData service. All commands
    besides ensure-network-device and implement-network are no-ops.

Configuration details
---------------------

Physical network registration details (registerExtension):
  mode          Optional, nat (default) or internal
  name_prefix   Optional, prefix of the vmnet network names, default
                cs-net-. Use another prefix per CloudStack installation when
                several share a Mac.

Setup
-----

1. Copy vmnet.py to every management server:

     mkdir -p /usr/share/cloudstack-management/extensions/vmnet
     cp vmnet.py /usr/share/cloudstack-management/extensions/vmnet/vmnet.py
     chmod 755 /usr/share/cloudstack-management/extensions/vmnet/vmnet.py
     chown -R cloud:cloud /usr/share/cloudstack-management/extensions/vmnet

   The unit tests run with: python3 -m unittest test_vmnet.py

2. Create the extension:

     cmk create extension name=vmnet type=NetworkOrchestrator path=vmnet.py \
         "details[0].network.services=UserData" \
         "details[0].network.service.capabilities={}" \
         "details[0].network.isolation.method=NetworkExtension" \
         "details[0].network.allocate.extension.ip=false"

   network.isolation.method=NetworkExtension makes CloudStack store the
   broadcast URI the script returns, instead of allocating a VLAN.

3. Register it to the zone's physical network; this also adds the vmnet
   network service provider, enabled:

     cmk register extension extensionid=<extension id> \
         resourcetype=PhysicalNetwork resourceid=<physical network id> \
         "details[0].mode=nat"

4. Create and enable an L2 network offering with UserData from vmnet:

     cmk create networkoffering name=vmnet-l2 displaytext="L2 on vmnet" \
         guestiptype=L2 traffictype=GUEST supportedservices=UserData \
         "serviceproviderlist[0].service=UserData" \
         "serviceproviderlist[0].provider=vmnet"
     cmk update networkoffering id=<offering id> state=Enabled

5. Create networks from that offering and deploy instances on them to
   clusters of an orchestrator extension that supports vmnet networks.

Limitations
-----------

  - CloudStack does not know the instances' IP addresses; use the
    orchestrator extension's GetIpAddresses custom action.
  - The mode applies to the whole physical network. Changing it affects
    networks created on the Mac afterwards; an existing network keeps its
    mode until its last instance is deleted.
  - A vmnet network exists per Mac: instances of one CloudStack network on
    different Macs are on different segments.
  - No user data, DHCP reservations, port forwarding or other services.
  - Tested on macOS 26.6 with Apple container 1.5.0 and a local management
    server: two instances on one internal network reach each other, not
    the internet, and are not reachable from containers on other networks;
    the network is created with the first instance, created again when it
    was removed, and deleted with the last instance.
