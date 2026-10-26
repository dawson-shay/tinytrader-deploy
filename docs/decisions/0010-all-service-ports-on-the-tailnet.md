# 0010: All service ports on the tailnet

- **Status:** Accepted
- **Date:** 2026-10-19
- **Amends:** [0008](0008-addresses-from-the-placement-map.md) (which ports
  each host forwards)

## Context

Under 0008 a host forwarded from the tailnet only the ports that a client on
another host `uses`. With the containers on one host and the store and
research on another, anything on the second host that wasn't declared
couldn't reach the first: research, other clients and ad hoc tools couldn't
read the relays, accounts, alpaca-data, databento-jobs or the other host's
node_exporter. Each new use needed an inventory edit, a deploy and a
`tailscale serve` change first.

## Decision

**Each host forwards every port of every service placed on it**, used from
another host or not (endpoints.nix `serve.<host>`; a host agent's, such as
node_exporter, on each host it runs on). So services and research on any of
the operator's machines reach each other without a per-use declaration.
`uses` still gives a service its address; it no longer decides what is
forwarded.

**The mechanism is 0008's:** containers publish on `127.0.0.1` only, and
`tailscale serve --tcp <port> tcp://127.0.0.1:<port>` forwards each one
(`scripts/tailnet-serve --apply`). Nothing binds the Tailscale address or
`0.0.0.0`.

**Exceptions, the `localOnly` services**, never forwarded, absent from the
policy, refused by `scripts/tailnet-serve` and the checks:

- the order gateways (their ports are `monitoring.gatewayPorts`): real money;
- the console's raw port (8080): its write gate trusts the
  `Tailscale-User-Login` header, which anything reaching the raw port could
  forge. Browsers and research use its HTTPS name (443);
- the Docker proxies (2375): the Docker API.

**Ports are distinct per host.** Every forwarded port is published on its
host at its own number, so services that shared a port inside their
containers each get one of their own in the inventory: each relay its own
observe port (9110, 9111, 9112, ... rather than 9110 in every container),
and no two services on one port (alpaca-data on 9125, tinytrader's default,
not the queue's 9123).

**The policy is unchanged in shape:** `tag:tinytrader` reaches the other
tagged hosts on `aclPorts`, every non-`localOnly` port, which is now exactly
the set the hosts forward. Untagged devices still get only 443 and SSH.

## Consequences

- The site's compose.yaml publishes every port of every non-`localOnly`
  container; the checks require it, and that each forwarded port is in
  `aclPorts` and none is `localOnly`.
- Moving or adding a service needs `scripts/tailnet-serve --apply` on its
  hosts, never a new `uses` entry just to be reachable.
- More is reachable from the other tagged hosts, including services with no
  token of their own: the queue (adds jobs from templates only) and
  databento-jobs (a charge needs a fresh quote and an exact confirmation).
  Only tagged hosts reach them, and anything on those hosts could already
  reach them on loopback.
- A service whose port changes is reached at its new address by its clients
  from their next deploy: they take it from the placement map.
