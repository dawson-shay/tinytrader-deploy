# 0013: The Databento key is held by databento-jobs and the OPRA relays alone

- **Status:** Accepted
- **Date:** 2026-10-22
- **Amends:** [0004](0004-secrets-across-machines.md) (secrets across
  machines): one file, the site's `secrets/databento.yaml`, is no longer the
  operator key's

## Context

databento-jobs does everything a purchase needs before it is made: the
quote, the exact confirmation, the checks against the store and Databento's
own job list, and the ledger (tinytrader decision 0019). Anything else
holding the Databento key can skip all of it: a research agent that
decrypts the key with the operator key, which every file was encrypted to
(0004), can buy data straight from Databento with `timeseries.get_range`,
and nothing stops it, because the key is everywhere an agent works:

- the operator key decrypts it, on every Mac you sit at, for anyone in the
  login user's shell, agents included;
- `scripts/deploy` and `scripts/local-up.sh` decrypt it into their
  environment for Compose;
- as a Docker secret of the relays, databento-jobs, research and the queue
  (which copies it into its volume for its jobs), it is readable by anyone
  who can use Docker (the login user, so every agent):
  `docker exec … cat /run/secrets/…`, or a container that mounts the volume.

The rule: only the services that need the key, wherever they run, may be
able to decrypt it.

## Decision

- **Who holds it:** databento-jobs, and the OPRA relays, which stream with
  the same key (the inventory's `relay-*` services placed natively; which
  run and their symbols are `deployment.native.<relay>`). Nothing else: not
  research, not the queue's jobs, not the console, not any shell. A relay
  of another provider (Alpaca's IEX feed) stays as it was.
- **Not containers:** they run natively on their Mac as launchd daemons, as
  `_ttdata` (uid 534), a hidden system user of their own, from tinytrader's
  service definitions built by Nix (`modules/databento-darwin.nix`, from
  `roles/darwin.nix` where they are placed with runtime `launchd`). Their
  ports, hours (`deployment.captureHours`) and addresses are the
  inventory's; containers reach them through `host.docker.internal`, other
  hosts through `tailscale serve`. On a NAS they are systemd units, which
  get the key as a credential (`modules/nas.nix`).
- **Decrypted by the host, not by you:** the site's `secrets/databento.yaml`
  (YAML, so sops-nix can write each key to a file of its own) is encrypted to
  its hosts' SSH host keys and the recovery key only. Not the operator key:
  the inventory's `secrets.hostOnly`, which `scripts/secrets-recipients` and
  the placement checks follow. sops-nix decrypts it as root at activation
  and at boot into `/run/secrets` (a RAM disk): `databento_api_key` and
  `jobs_approve_token`, each owned by `_ttdata`, mode 0400, read through
  `DATABENTO_API_KEY_FILE` and `JOBS_APPROVE_TOKEN_FILE`.
- **Checked:** a hostOnly file is usable only on a host granted it with a
  key of its own, by services that don't run in Compose
  (`placement-secrets`), and the site's compose.yaml may not name the key at
  all (`placement-no-databento-key`).
- **Data is bought through databento-jobs:** research's and the queue's own
  Databento clients stop with "purchases go through databento-jobs". What
  it bought is read from the store (`tt.tapes`, `tt.read_dbn`).
- **The host key's backup**, wherever the machines repository keeps it, is
  encrypted to the recovery key alone, since the host key opens this file.

## Consequences

- **What you lose:** reading or editing the Databento key from a Mac
  without sudo. `sops decrypt secrets/databento.yaml` fails with the
  operator key, on purpose. To change it, on its host:
  `scripts/databento-key edit` (or `set DATABENTO_API_KEY`), which runs sops
  as root with the host key; or anywhere, the recovery key from where it is
  kept offline. Then commit, merge, apply the host's role, and after hours
  restart databento-jobs and the relays (`scripts/databento-key` says how).
  `scripts/secrets-recipients` can't re-key this file with the operator key:
  `scripts/databento-key updatekeys` on its host does.
- **sudo is the boundary.** Root on the host (you, with your password) can
  read the key; the login user, and an agent running as it, can't: not the
  file, not the daemons' environment or memory, not a container. An agent
  must never be given sudo there.
- **Old copies stay readable.** Moving to this changes who can decrypt from
  then on, not the key's value. A site whose history has the key encrypted
  to the operator key still opens the old value from history
  (`git show <old>:<file> | sops decrypt …`), and anything that read it
  before still has it. Until the key is rotated (a new key from Databento,
  set with `scripts/databento-key set DATABENTO_API_KEY`), the boundary
  holds against a fresh mistake, not against someone who keeps the old
  value.
- **The approval token** is in two places: `JOBS_APPROVE_TOKEN` here
  (databento-jobs' alone), and `CONSOLE_JOBS_APPROVE_TOKEN` in the site's
  `secrets/console.env`, which the console gets as a Docker secret. The
  console's copy is readable by the operator key and by anyone with Docker
  access, as every console secret is.
- **The ledger** is `/var/lib/tinytrader/databento-jobs/submissions.jsonl`
  on its host (owned by `_ttdata`; the nightly backup copies it), not a
  Docker volume. databento-jobs refuses to start without it.
- **One session per stream:** each native daemon refuses to start while its
  ports are taken, so the container it replaces must be stopped first
  (`scripts/deploy --remove`), and there are never two Databento sessions
  on one stream.
- **Logs** are `/Library/Logs/tinytrader-data/<name>.log`, readable by
  you; restarting is `sudo launchctl kickstart -k system/com.tinytrader.<name>`.
