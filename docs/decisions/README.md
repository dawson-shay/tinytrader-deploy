# Decisions

Why the stack is the way it is, one record per decision. A record keeps its
number and title once accepted (code comments cite them); a later decision
amends it rather than rewriting it. The numbers have gaps: 0001 and 0003
were about the first deployment alone and stayed in its site
([0015](0015-stack-and-site.md)).

| No. | Decision | In short |
|---|---|---|
| [0002](0002-platform-and-deployment-split.md) | Split the platform from the deployment | tinytrader (platform), tinytrader-deploy (this stack) and the site (a deployment's private repository), and what goes where. |
| [0004](0004-secrets-across-machines.md) | Secrets across machines | sops files decrypted per file by operator, recovery and host keys, from the inventory. |
| [0005](0005-placement-map.md) | One placement map: what runs where | The inventory's `services` says each service's host and runtime; scripts and checks follow it. |
| [0006](0006-host-monitoring.md) | Each host watches itself, and alerts reach the phone | `watch` natively on every host, ntfy alerts and healthchecks.io heartbeats. |
| [0007](0007-research-reads-through-the-store.md) | Research reads market data through the store | Notebooks fetch DBN files by logical name from the store, never by mount path. |
| [0008](0008-addresses-from-the-placement-map.md) | Services find each other from the placement map | Generated addresses, `tailscale serve` forwarding, the tailnet policy as code, a store write token. |
| [0009](0009-console-state-in-git.md) | The console's reminders and curated views live in git | Reminders, curated views and the journal are files in the site's `state/console`. |
| [0010](0010-all-service-ports-on-the-tailnet.md) | All service ports on the tailnet | Every port but the `localOnly` ones is forwarded; ports are distinct per host. |
| [0011](0011-auto-deploy-from-main.md) | Deploy merged code from main automatically (step 1) | A launchd job fast-forwards and deploys what changed, after hours, never the excluded services. |
| [0012](0012-deploy-checkouts.md) | The services run from deploy checkouts, not working copies | Plain clones under `<deployRoot>` that only auto-deploy changes. |
| [0013](0013-databento-key-held-by-its-services.md) | The Databento key is held by databento-jobs and the OPRA relays alone | Native daemons as their own user; the key is host-only, never the operator key's. |
| [0014](0014-nomad-batch-scheduler.md) | Nomad runs batch work, on every machine in the pool | Agents from the inventory, the gate for start conditions, ACLs on; policy and job specs are the site's. |
| [0015](0015-stack-and-site.md) | A public stack, a private site | The stack is generic, a new repository; everything specific comes from the site. |
| [0016](0016-disk-hygiene.md) | The Macs clean up after builds, and warn before the disk is full | A cargo target per repository (a cargo shim), a daily disk-hygiene job, system-disk warnings below 15% or 20 GiB free. |
