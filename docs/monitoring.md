# Monitoring: setting up alerts to your phone

Each host's monitor (tinytrader's `watch`, decision
[0006](decisions/0006-host-monitoring.md)) pushes problems to a private
[ntfy](https://ntfy.sh) topic, and pings a [healthchecks.io](https://healthchecks.io)
check after every run so a host that stops altogether is noticed too. This is
the one-time setup for a site. Nothing breaks before it is done: the monitors
log what they would send.

## 1. A private ntfy topic

Anyone who knows a topic's name on ntfy.sh can read it, so the name is the
secret: make it random and long.

```sh
printf 'tt-%s\n' "$(openssl rand -hex 20)"   # 43 characters; keep it to yourself
```

Install **ntfy** on your phone, tap **+**, and subscribe to that topic on
`ntfy.sh`. Allow notifications. Your URL is `https://ntfy.sh/<topic>`. (Test
it: `curl -d test https://ntfy.sh/<topic>`.) A self-hosted ntfy server works
the same way.

## 2. healthchecks.io: one check per host

Create a free account, then one check for each host that runs a monitor
(each host in the site's `services.watch.perHost`; in the example site,
`desk` and `vault`, and `nas` once it exists).

- **Period:** 1 minute. **Grace:** 4 minutes.
- **Integrations:** add **ntfy** (the same topic URL) and **Email**, and turn
  both on for each check. Email still reaches you if ntfy is the problem.

Each check's **ping URL** (`https://hc-ping.com/<uuid>`) is a secret too.

## 3. The site's secrets/notify.env

The inventory names the file and its keys:

```nix
# the site's inventory.nix
monitoring = {
  notify = { file = "notify.env"; url = "NTFY_URL"; };
  heartbeat = {             # each monitored host's healthchecks.io ping URL
    desk = "HC_PING_DESK";
    vault = "HC_PING_VAULT";
    nas = "HC_PING_NAS";
  };
  # disk, backup, gatewayPorts: the thresholds and the never-probed ports
};
```

Encrypt the values into the site's `secrets/notify.env` with sops, in your
own terminal in the site's checkout, so they are never on disk in plain
text (the file's recipients come from the inventory, decision
[0004](decisions/0004-secrets-across-machines.md)):

```sh
read -rs NTFY && read -rs DESK && read -rs VAULT
printf 'NTFY_URL=%s\nHC_PING_DESK=%s\nHC_PING_VAULT=%s\n' "$NTFY" "$DESK" "$VAULT" \
  | sops encrypt --input-type dotenv --output-type dotenv \
      --filename-override secrets/notify.env /dev/stdin > secrets/notify.env
unset NTFY DESK VAULT
git add secrets/notify.env && git commit -m "Alerts: ntfy topic and heartbeats" && git push
```

(To add a key later: `sops secrets/notify.env`.) The role modules read the
file from the flake's source, so it must be committed. Then apply each host's
role: on a Mac, update the site's input in your machines repository
(`nix flake update <site>`) and switch, or `scripts/darwin-switch`; on NixOS,
deploy the host. Redeploy the console (`scripts/deploy console`) on the host
that runs it, so it gets `CONSOLE_NOTIFY` (the same `NTFY_URL`) for its own
notices.

## What you'll get

`watch` has one set of disk thresholds per host. A host that watches only
`/` uses `monitoring.systemDisk` (by default a warning at 85% used, high
priority at 95% or under 20 GiB free); a host that watches other disks too
keeps `monitoring.disk` (decision [0016](decisions/0016-disk-hygiene.md)).

| Notice | When | Repeats |
|---|---|---|
| High priority | Docker engine not answering; an expected container missing, stopped or restarting; the console not answering; a service `failed`; a native service not running; a disk at `monitoring.disk.critPercent` or under `minFreeGiB` free, or not mounted | every 30 min |
| Warning | a container restarted; a service degraded for 3+ min; a disk at `monitoring.disk.warnPercent`; the newest backup, or its off-host copy, older than `monitoring.backup` allows | every 6 h |
| Resolved | when it clears | once |
| healthchecks.io "down" | a host's pings stopped for 5 min (off, asleep, offline, or its monitor died), or a notice couldn't be delivered | by healthchecks.io |

A problem must be seen two runs in a row (a minute apart) before it is sent.
The monitor never connects to an order gateway (`monitoring.gatewayPorts`):
those are judged by their containers alone.

Logs: `~/Library/Logs/tinytrader/watch.log` on a Mac, `journalctl -u
tinytrader-watch` on NixOS. To check a host by hand:
`launchctl print system/com.tinytrader.watch` (a boot-time daemon on a Mac;
no sudo needed). A monitor without a usable notify.env says so in its log
and keeps running: notices are logged, not sent, and there is no heartbeat.
