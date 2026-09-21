# Operating a multi-AP wired cluster

## Topology

Connect every AP to the same trusted Ethernet Layer-2 management network or
VLAN. The APs do not need to connect directly to one another: any number of
intermediate switches is fine as long as the path carries unicast traffic and
mDNS multicast between members. Avoid loops unless the switching network has
a correctly configured loop-prevention protocol.

Ethernet is the backhaul. Client VLANs and management isolation remain the
responsibility of the surrounding network.

## Create the cluster

1. Install and provision each AP independently.
2. Change the default root password and configure the desired WLAN locally.
3. Open **Network → RG-MA2820 Cluster** on each AP.
4. Enter the same 1–32 character cluster name and the same 12–128 character
   secret on every member.
5. Open **Network → RG-MA2820 Wireless**, choose cluster scope, enter any
   required Wi-Fi passwords, and apply the shared profile once.
6. Confirm that every expected node is online, configuration is synchronized,
   both radios are ready, and each AP lists its remote neighbors.

The plain-text cluster secret is not stored. Each AP stores derived keys, so
rejoining or rotating credentials requires entering the same new secret on
every node.

## Add a third or later AP

There is no special leader or pair assignment:

1. connect and provision the new AP on the same VLAN;
2. configure the exact existing cluster name and secret on it; and
3. reapply the Wi-Fi profile in cluster scope, supplying passwords when the
   new AP does not already hold them locally.

Existing members discover it dynamically and refresh their 802.11k neighbor
sets. No firmware rebuild and no fixed management IP are required.
Active steering is enabled only while a recently authenticated neighbor has
been installed locally; losing discovery cannot trigger forced client moves.

The browser-derived timezone and explicit timezone changes are also validated
and distributed to every online authenticated member.

## Remove or replace an AP

Powering off or disconnecting a member does not stop the others from serving
clients. Its discovery entry expires naturally. To repurpose a reachable AP,
use **Leave cluster** before moving it to another site. To replace a failed
unit, provision the replacement as a new identity and join it normally; do
not restore the failed unit's writable overlay or SSH host keys.

## Channel planning

`auto` lets every radio select a channel with its local scan and deterministic
node-specific fallback. It is not a centralized RF optimizer. In dense or
large deployments, inspect the channel and client view from LuCI after all
members settle, then assign a deliberate channel reuse plan if co-channel
contention is high.

Use the regulatory profile permitted at the physical deployment. The project
does not bypass driver/firmware regulatory enforcement.

## Roaming expectations

All APs must advertise byte-identical SSID/security settings for seamless
roaming. The cluster provides 802.11k neighbor reports, 802.11v transition
suggestions, and 802.11r fast transition where supported. It cannot force a
client to roam; client firmware and RSSI hysteresis remain decisive.

Judge roaming with a continuous ping or call while walking between cells,
then inspect which BSSID serves the client. Do not infer roaming solely from
seeing one SSID name.

## Scale and failure model

Membership has no hardcoded two-node or fixed-IP limit. The implementation is
controllerless and each node queries every other visible member, so aggregate
control work grows approximately as `N × (N - 1)`. There is no claimed or
validated maximum yet. The source regression creates three independent nodes;
the hardware campaign has two physical nodes.

For larger installations:

- keep a cluster within one site and one management VLAN;
- use a distinct name and secret for each independent failure domain;
- monitor mDNS multicast, status latency, and radio neighbor-table size;
- avoid exposing the management VLAN to untrusted clients; and
- stage additions in small batches and verify configuration convergence.

A multicast outage prevents new discovery but does not stop already configured
radios from serving clients. An unavailable member is reported as such and
does not make the remaining APs dependent on a controller.

## Security note

Cluster messages use HMAC-SHA256 authentication, signed responses, and a bounded
recent-nonce replay cache for changes. A discovered candidate must answer an
authenticated status challenge before it receives a configuration body. The current
transport is still HTTP over the wired LAN, not confidential TLS. Treat the
management VLAN as trusted: a passive observer can see a newly distributed
Wi-Fi password even though they cannot forge an accepted request without the
cluster key.
