# 0005: One placement map: what runs where

- **Status:** Accepted
- **Date:** 2026-10-15

## Context

Once more than one machine runs services (say one Mac runs the containers
while another keeps the native store beside its external drives, until the
disks move to a NAS), where each service runs gets written in several places
that can disagree: host `role` strings in the inventory, comments in
`compose.yaml`, the role modules and the decision records. And scripts that
start whatever they are given on whatever machine runs them can start the
same service (a live order gateway, say) on two machines.

## Decision

The site's `inventory.nix` has a `services` attrset, the one source of truth
for placement. Each service has:

| Field | Means |
|---|---|
| `host` | The inventory host that runs it |
| `runtime` | `compose` (the site's deploy/local/compose.yaml), `launchd` (a nix-darwin role module) or `systemd` (a NixOS role module) |
| `dataRoots` | The data roots it reads or writes; each must be on its host |
| `colocateWith` | Services it reaches by Compose name or on loopback, so must share its host |
| `secrets` | The `secrets.files` patterns it uses; its host must be able to decrypt them |
| `profile` | Its Compose profile, if not the default: not started by local-up, not expected by the monitor (added by [0006](0006-host-monitoring.md)) |
| `perHost` | Instead of `host` and `runtime`, for a host agent run on several hosts: `{ <host> = <runtime>; }`, native runtimes only (added by [0006](0006-host-monitoring.md)) |

Host `role` strings stay as descriptions in words.

- **One compose file, every host.** `scripts/local-up.sh` and `scripts/deploy`
  act only on the services placed on the machine they run on. The machine is
  `TINYTRADER_HOST` if set, else the host whose name or tailnet name is its
  LocalHostName (`scripts/placement host`). `scripts/deploy` refuses a service
  placed elsewhere unless `--force`. A site's own launchers for native
  services can check the same way (`scripts/placement host`).
- **Checks keep it true.** `nix flake check` on the site (the checks
  `lib.mkDeployment` returns, `checks/placement.nix`) fails when a service in
  compose.yaml or a role module isn't in `services` (or the reverse), when a
  runtime doesn't fit its host, when a data root or a `colocateWith` or
  `depends_on` target is on another host, and when a host can't decrypt a
  secret its services use. A host decrypts a file if `secrets.files` grants
  it, or if it is in `secrets.operatorKeyHosts`: the Macs you sit at, which
  decrypt with the operator key (decision 0004). Role modules of planned
  hosts (a NAS) are written ahead of their placement, so the services they
  enable only need to be in the map.
- **The role follows the map.** `roles/darwin.nix` (and the NixOS role, `modules/nas.nix`)
  enables on a host the native services placed there, so moving a native
  service is an inventory edit too.
- **The console draws it.** `deploy/local/topology.nix` layers the placement
  over the site's `deploy/local/topology.json`: each service's host and
  runtime, and a host entry for each machine that runs something. It is the
  site flake's `topology` package, and local-up and deploy write it to
  `~/.local/state/<deployment>/topology.json` (the inventory's
  `deployment.name`) for the console.

## Moving a service

1. Change its `host` in the site's `inventory.nix` `services`.
   `nix flake check` says what else must follow: services it must stay
   beside, data roots, secrets recipients.
2. If it uses secrets and the new host decrypts with its own key, run
   `scripts/secrets-recipients` (decision 0004).
3. Commit, and pull on both hosts.
4. On the new host: `scripts/deploy <service>`. On the old host:
   `scripts/deploy --remove <service>` for a container, or apply its role
   (`scripts/darwin-switch`) on both hosts for a native one. The console's
   graph follows at the next deploy on its host, which rewrites its topology
   file.

## Consequences

- Starting a service on the wrong machine through these scripts takes
  `--force`, so two live order gateways can't start by accident.
- The map alone doesn't rewrite addresses: services that talk across hosts
  need addresses the other host can reach, and `colocateWith` lists the ones
  that must share a host instead. (Resolved by
  [0008](0008-addresses-from-the-placement-map.md): addresses come from the
  map, and `tailscale serve` forwards.)
