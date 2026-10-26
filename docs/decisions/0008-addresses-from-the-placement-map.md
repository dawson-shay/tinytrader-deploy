# 0008: Services find each other from the placement map

- **Status:** Accepted; which ports each host forwards amended by
  [0010](0010-all-service-ports-on-the-tailnet.md) (all of them but the
  `localOnly` ones)
- **Date:** 2026-10-16
- **Builds on:** [0005](0005-placement-map.md) (the placement map),
  [0006](0006-host-monitoring.md) (monitoring),
  [0007](0007-research-reads-through-the-store.md) (research through the store)

## Context

The placement map (0005) says where each service runs, but the addresses
services used to reach each other were written by hand, assuming one host:

- containers used Docker names (`console:8080`);
- containers reached the native store as `host.docker.internal:9120`;
- native services used loopback;
- the console's topology file had addresses too.

Each service's ports were in compose.yaml and in tinytrader's service
definitions, and nowhere in the map. Once the containers run on one host and
the store and research on another, research (`console:8080`), and the
console and databento-jobs (`host.docker.internal:9120`), point at nothing.
Every service listens on loopback, and the store's writes had no
authentication beyond a same-origin check.

## Decision

**Ports and uses in the inventory.** Each service in the site's
`inventory.nix` `services` gets the ports it serves, by name (`ports = { http = 8080; }`; a
relay's `stream` and `observe`, a gateway's `orders`), and the services it
connects to (`uses = [ "console" "relay-opra-spy:observe" ]`).
`colocateWith` is left for real constraints: the same Docker engine or
network, a Compose `depends_on`, or a service that is never remote. Uses that
were colocations only for their addresses (the relays and accounts, research
and the store) are now plain `uses`.

**Addresses are generated** by `deploy/local/endpoints.nix` (plain Nix, a
function of the site's inventory; the site flake's `endpoints` package has `endpoints.json` and one `<host>.env` per
host). For a client on a host:

| Client | Service on the same host | On another host |
|---|---|---|
| A container | `<name>:<port>`, or `host.docker.internal:<port>` for a native service (or one marked `viaHost`: the live gateway, reached through the host as before) | `<tailnetName>.<tailnet.domain>:<port>` |
| A native service | `127.0.0.1:<port>` | the same |
| A browser (the notebook link) | `localhost:<port>` | the same |

The site's compose.yaml names them as `${TT_ADDR_<SERVICE>}` (host:port) and
`${TT_URL_<SERVICE>}` (`http://` + host:port). For a service with several
ports the port's name is appended (`TT_URL_RELAY_OPRA_SPY_OBSERVE`).
`scripts/placement endpoints` prints this host's values, and `local-up.sh`
and `deploy` export them before Compose runs. The role modules (the queue's
host runner, a NAS's services) use `endpoints.address`. `topology.nix`
writes the console's addresses into its topology: native services' observe
URLs, each host's node_exporter, and the notebook link. The full DNS name is
used, not the short MagicDNS name, because containers don't reliably get the
tailnet's search domain.

While everything is on one host, the generated values are the ones a
single-host compose.yaml would hard-code: `docker compose config` with them
gives the same environment and commands. The additions are the store
token's file and secret, `TT_URL_CONSOLE` in the queue's environment (for
its templates), `expose` on the Docker proxies, and an `exporter` per host in
the topology.

**Cross-host listeners: everything stays on loopback, and `tailscale serve`
forwards.** A host forwards from its tailnet address the ports of its
services (`serve.<host>` in endpoints.nix). This decision forwarded only
those a client on another host uses; since
[0010](0010-all-service-ports-on-the-tailnet.md) it is every port but the
`localOnly` ones:
`tailscale serve --bg --tcp <port> tcp://127.0.0.1:<port>`, applied by
`scripts/tailnet-serve --apply` (without `--apply` it only shows the changes).
The other options considered:

- **Publish containers on the Tailscale IP.** It doesn't work under Colima:
  the Docker engine runs in a VM that has no such address. Docker Desktop
  could bind it, but it also needs the IP known when Compose runs and
  tailscaled up before Docker.
- **Bind 0.0.0.0.** That also opens the ports on the local network, where the
  tailnet policy doesn't apply.
- **Bind the store to another address.** The store already has the option
  (`STORE_LISTEN`, the module's `observe.bind`), but containers, the monitor
  and deploy reach it on loopback, and it binds one address.

`tailscale serve` works the same for Colima, Docker Desktop and the native
store. It listens on the tailnet only, persists in tailscaled, and the
console is already published that way (HTTPS on 443).

**Never a remote order gateway.** The gateways (the services whose ports
are `monitoring.gatewayPorts`) and the Docker proxies (`localOnly`) are never
forwarded, are absent from the policy, and get an address on another host
that can't resolve (`<name>.not-on-this-host.invalid`). `nix flake check`
fails when a client on another host uses one.

**The tailnet policy as code.** The site's `tailscale/policy.hujson` is
generated from its inventory (`tailscale/policy.nix`,
`scripts/tailscale-policy`; a check fails while the file is stale). It grants:

- `tag:tinytrader`, the hosts that run services, reaches the other
  tinytrader hosts on every port a service may be reached on across hosts:
  every service port but the gateways' and the Docker proxies'. A move then
  needs no policy change; a port is open only where `tailscale serve`
  forwards it.
- SSH (port 22) between your devices and those hosts, either way, plus
  Tailscale SSH rules for the hosts that run it.
- Your devices reach the console's HTTPS (443).
- Your own devices keep full access to each other.

Its tests require the service ports to be accepted and the gateway and proxy
ports denied. Nothing here applies it. To apply it, the operator:

1. In the admin console's Machines page, gives `tag:tinytrader` to the
   hosts that run services (and each new one when it joins). A tagged node
   belongs to the tailnet, not to you, and its key no longer expires.
2. In Access controls, pastes the site's `tailscale/policy.hujson` over the policy.
   Tailscale runs its tests on save. Keep the old policy to paste back.
3. Checks that SSH still works both ways, and the console's HTTPS from the
   phone.

Later, the `tailscale/gitops-acl-action` GitHub Action can apply the file
on each push to the site's main (an API key or OAuth client as a
repository secret, with `policy-file: tailscale/policy.hujson`). After that, the admin console
is read only.

**The store's writes need a token** (tinytrader's store: `STORE_WRITE_TOKEN`
or `_FILE`, a bearer token; reads stay open, behind the policy). With no
token configured, writes are open as before. It is the site's
`secrets/store.env`:

- the store's host decrypts it into the store's environment
  (`modules/store-darwin.nix` on a Mac);
- local-up and deploy pass it to the console and databento-jobs as a Compose
  secret (`CONSOLE_STORE_TOKEN_FILE`, `JOBS_STORE_TOKEN_FILE`);
- a NAS's role hands it to its store and writers as credentials.

Until the file exists, nothing changes.

**Checks** (`checks/placement.nix`):

- every use names a service and a port it has;
- no client on another host uses a gateway or another `localOnly` service;
- a service named like a gateway has a gateway port;
- no host forwards two services on one port;
- compose.yaml publishes only a service's inventory ports, on 127.0.0.1, at
  the same number;
- each inventory port appears in the service's definition, as does its
  `tinytrader.observe` label;
- a port its host forwards (or a `viaHost` one) is published (since 0010:
  every port of a service that isn't `localOnly`), and each forwarded port
  is in the policy's ports and isn't `localOnly`;
- every `${TT_*}` a service names is generated, for a service and port in
  its `uses`;
- compose.yaml interpolates on every container host with that host's values;
- a role module's `observe.port` is the inventory's.

## Moving a service now

1. Change its `host` in the site's `inventory.nix`. `nix flake check` says what must
   follow: neighbours, data roots, secrets, and a port a remote client now
   needs published on loopback.
2. Commit, push, and pull on every host involved.
3. On each host whose forwards change (`scripts/placement serve` before and
   after): `scripts/tailnet-serve`, then `--apply`.
4. On the old host `scripts/deploy --remove <service>`. On the new host
   `scripts/deploy <service>`, and `scripts/deploy` again for the clients on
   other hosts, so they pick up its new address. local-up and deploy export
   the addresses every time.

## Consequences

- Moving a service is the inventory edit, the forwards and a redeploy of the
  clients that use it. compose.yaml doesn't change, unless a port newly used
  from another host isn't published yet. The checks name each one.
- Cross-host traffic goes through tailscaled (WireGuard). That's fine for
  control traffic, the console and single-file reads (0007). Bulk data moves
  by the LAN routes the architecture describes, later.
- `docker compose` run by hand needs the addresses exported
  (`eval "$(scripts/placement endpoints)"`), as it already needed
  `TINYTRADER_TOPOLOGY`.
- Services see forwarded connections as coming from loopback. Nothing here
  relies on a peer's address.
- Worth verifying on a new host: its containers resolve the tailnet's full
  names and reach tailnet addresses; its engine's `host.docker.internal`
  reaches the host's loopback (node_exporter, say); its Tailscale accepts
  `serve --tcp`.
