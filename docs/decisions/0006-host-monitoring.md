# 0006: Each host watches itself, and alerts reach the phone

- **Status:** Accepted
- **Date:** 2026-10-15
- **Builds on:** [0004](0004-secrets-across-machines.md) (secrets),
  [0005](0005-placement-map.md) (the placement map); tinytrader decision 0015
  (`watch`)

## Context

The failures that matter most are the ones that take the monitoring down
with them. A Mac's internal disk fills, Docker's VM stops, and every
container is down for hours before anyone notices; the symptoms (a relay
outage, say) point somewhere else. The console's push notices
(`CONSOLE_NOTIFY`) die with Docker, and are easy to leave unconfigured. A
console that counts a restart loop or a service reporting `failed` only as
"needs attention", and skips a container that disappeared, says nothing
urgent. And node_exporter run by hand in a terminal doesn't survive a
reboot.

## Decision

- **Every host runs tinytrader's `watch`** natively, outside Docker: a
  launchd agent on a Mac (`modules/watch-darwin.nix`, from
  `roles/darwin.nix` where `watch` is placed), a systemd unit on a NAS
  (`modules/nas.nix`). Its settings come from the site's inventory
  (`modules/watch.nix`): the containers expected are the compose services
  placed on its host in the default profile; it reads the console's
  `/api/state` where the console runs and the store's `/health` where the
  store runs, checks the native services its role enables, and the disks in
  `hosts.<host>.watch.disks` (for example `/` and each of the store's
  drives, `/Volumes/<drive>`, on the store's host; `/` elsewhere) against
  `monitoring.disk` (90% a warning; 95% or under 10 GiB free high priority;
  an unplugged drive too).
- **Alerts go to a private ntfy topic**, and each run pings that host's
  healthchecks.io check, which alerts (by ntfy and email) when the pings stop:
  a host that is off, asleep or offline, or whose monitor died. Both URLs are
  in the site's `secrets/notify.env` (`NTFY_URL`, `HC_PING_<HOST>`, named in
  `monitoring`). The console pushes to the same topic (`CONSOLE_NOTIFY`, from
  local-up and deploy), faster but only while Docker runs.
- **The monitor never connects to an order gateway.** Gateways are judged by
  their containers' state and restart counts; `monitoring.gatewayPorts` are
  refused as URLs.
- **node_exporter is a launchd agent** on each Mac
  (`tinytrader.services.node-exporter`, 127.0.0.1:9100), not a process run by
  hand. A NAS gets it from tinytrader's NixOS module.
- **Host agents in the placement map.** `watch` and `node-exporter` run on
  several hosts, so a service may give `perHost = { <host> = <runtime>; }`
  instead of `host` and `runtime`; the checks treat each as one instance per
  host. Services in a Compose profile say so (`profile`), and the checks hold
  it to compose.yaml, so the monitor doesn't expect containers that are off
  by design.
- **A missing notify.env breaks nothing.** The role modules include it only
  when the encrypted file is in the site's flake; without it, or when it
  can't be decrypted, the monitor runs and logs what it would send.

## Consequences

- A stopped engine, a full disk or a vanished container reaches the phone in
  about two minutes (two runs a minute apart); a dead host in five (the
  check's period plus grace).
- A host's monitor expects every container placed on it: place `watch` on a
  new services host only once its containers are there, or it will
  (rightly) report them missing.
- Monitoring on a host can't report that host's network being down; the
  heartbeat covers that, from outside. The site's internet connection down
  silences both, an open question in the architecture.
- A notice that can't be delivered is retried every run, and the run's
  heartbeat goes to `/fail`, so healthchecks.io's email carries it.
