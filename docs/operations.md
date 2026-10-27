# Operations

The runbooks for a deployment of this stack: the rules, the day-to-day
commands, changes, incidents and recovery. Every command here is one the
scripts really take; when a script changes, change this page with it.

The design is in [architecture.md](architecture.md), the reasons in
[decisions/](decisions/), alerts in [monitoring.md](monitoring.md), CI in
[ci.md](ci.md). How secrets are made and rotated is in the site's
`secrets/README.md` and [decision 0004](decisions/0004-secrets-across-machines.md).

The examples use the example site's hosts: `desk`, the Mac that runs the
services; `vault`, the Mac with the store's drives; `nas`, a NixOS machine.
Put your own site's hosts in their place.

## Orientation

### Where commands run from

Commands run from a checkout of this stack (`tinytrader-deploy`), with the
site found automatically (`scripts/lib/site.sh`), the first of:

- `TINYTRADER_SITE`, set by hand (or by the launchd jobs);
- the current directory's repository, when it has an `inventory.nix` (so
  `../tinytrader-deploy/scripts/deploy` works from inside the site);
- the one directory beside the stack checkout with an `inventory.nix` and a
  `flake.nix`. With more than one there, set `TINYTRADER_SITE`.

tinytrader itself is checked out beside them (`../tinytrader`, or
`TINYTRADER_SRC=<path>`). A typical layout:

```
~/repos/tinytrader          the platform
~/repos/tinytrader-deploy   this stack: the scripts, the modules, the role
~/repos/my-site             your site: inventory.nix, compose.yaml, secrets/, state/
```

On a services host the services themselves run from the deploy checkouts,
not those ([below](#the-deploy-checkouts)).

### Reaching the hosts

Over Tailscale only; nothing listens beyond loopback and the tailnet. Each
host forwards every port of its services from the tailnet with
`tailscale serve` (`scripts/placement serve` lists them,
`scripts/tailnet-serve --apply` sets them;
[decision 0010](decisions/0010-all-service-ports-on-the-tailnet.md)), so
another tagged host reaches any service at `<host's tailnet name>.<tailnet
domain>:<port>` (the inventory's `hosts.<host>.tailnetName` and
`tailnet.domain`). Never forwarded (`localOnly`): the order gateways, the
console's raw port (its HTTPS name instead) and the Docker proxies.

The console listens on `127.0.0.1:8080` of the host that runs it, and
`tailscale serve` publishes it over HTTPS at that host's tailnet name. From
any machine, a tunnel works too: `ssh -N -L 8080:127.0.0.1:8080 desk`, then
http://localhost:8080 (read-only: see [The console's write gate](#the-consoles-write-gate)).

### What runs where

The site's `inventory.nix` `services` is the placement map
([decision 0005](decisions/0005-placement-map.md)): each service's host and
runtime (`compose`, `launchd` or `systemd`).

```sh
scripts/placement host              # which inventory host this machine is
scripts/placement services          # what is placed on it
scripts/placement services compose  # just its containers (or launchd, systemd)
scripts/placement check console     # fails, saying where, unless it runs here
scripts/placement serve             # what this host forwards from the tailnet
```

`scripts/placement host` matches the Mac's LocalHostName (or a Linux host's
short hostname) against the inventory's host names and tailnet names
(`TINYTRADER_HOST=<host>` overrides). In the console, the deployment graph
draws each service on its host, from the topology file that `scripts/deploy`
and `scripts/local-up.sh` write to `~/.local/state/<deployment name>/topology.json`
(the deployment's name is the inventory's `deployment.name`; it is also the
Compose project's).

What is actually running, on a Mac:

```sh
docker ps --format '{{.Names}}\t{{.Status}}' | sort
launchctl list | grep com.tinytrader
```

## Rules

- **Market hours: no deploys, builds or heavy work 09:25-16:20 New York
  time on trading days**, unless the operator asks. Builds take the CPUs the
  relays read from, and a relay starved of CPU falls behind its feed and
  loses records. `scripts/deploy` refuses then on weekdays (it doesn't know
  holidays; `--force` overrides), and auto-deploy doesn't start a run after
  09:00.
- **The live order gateway is real money.** Change it (deploy, restart,
  move, settings) only with the operator's explicit go-ahead, after hours,
  and never run two live gateways at once, anywhere: before starting it on
  one host, check it is stopped on every other (`docker ps --filter
  name=order-gateway` and `pgrep -fl order-gateway` on each host). The
  inventory places it on one host only, and the scripts refuse it elsewhere
  without `--force`: never pass `--force` for it.
- **Never commit a secret.** Secrets are sops files in the site's
  `secrets/`, decrypted only into a process's environment (or, for the
  Databento key, into `/run/secrets` for its own user), never onto disk in
  the clear. `nix flake check` fails on an unencrypted file under `secrets/`.
- **The data roots and the Docker volumes hold state that can't be
  rebuilt.** Nothing deletes from a data root (the store's drives), a Docker
  volume or `~/.local/state/order-gateway` to make room.
- **Agents** follow [Agent hygiene](#agent-hygiene).

## Daily

### Deploy a service

```sh
scripts/deploy console                 # rebuild, recreate, and check it came back
scripts/deploy console databento-jobs  # several at once
scripts/deploy store                   # a native service: applies this Mac's nix-darwin config (asks for your password)
```

`scripts/deploy` acts only on services placed on this machine. It refuses,
unless `--force`: a service placed elsewhere, any build in market hours, and
restarting a relay that is live (its clients would drop). It always recreates
the containers, then waits for each to report `ready`, `idle` or `degraded`,
and exits 1 if one doesn't (`NOT BACK`). Secrets are decrypted into its own
environment only.

- Containers are built from the **tinytrader checkout's working tree**
  (`../tinytrader`, or `TINYTRADER_SRC=<path>`; the deploy checkout where
  there is one): what git tracks there, uncommitted changes included.
  `git add` a new file before deploying it.
- Native services are built from the tinytrader revision the site's
  `flake.lock` pins (see [Update the tinytrader pin](#update-the-tinytrader-pin)).
- The console's page is built into its image, so a `git pull` in the
  checkout doesn't change the running console: a page change ships with
  `scripts/deploy console` (after hours, since the build takes CPU).

Everything placed here at once, and all of it down:

```sh
scripts/local-up.sh     # build and start every container placed here (default profile)
scripts/local-down.sh   # stop every container of the project on this machine: the live gateway too
```

Services in a Compose profile other than the default (idle relays, say) are
left off by `local-up.sh`; `scripts/deploy <service>` starts one.

After a deploy that adds, moves or removes a service, set the host's
forwards to match:

```sh
scripts/tailnet-serve           # what would change; changes nothing
scripts/tailnet-serve --apply   # add the forwards the placement map wants, remove the stale ones
```

### Auto-deploy

On a services host, `scripts/auto-deploy` can deploy what is merged to main
by itself, every 5 minutes ([decision 0011](decisions/0011-auto-deploy-from-main.md)).
It commits and pushes the console's state (the site's `state/console`:
reminders, journal and layouts, "Console state: ..."), fast-forwards the
three deploy checkouts (only on `main`, with no tracked changes but the
console's own under `state/console`, never forcing), works out which
containers the new commits change, and runs `scripts/deploy` for them,
outside 09:25-16:20 New York time on weekdays (no start after 09:00). Never
what the inventory's `deployment.autoDeploy.never` lists (by default the
order gateways and the relays): those, and native or tailnet changes, arrive
as a "manual deploy needed" notice.

```sh
scripts/auto-deploy --dry-run                     # what it would do now (changes nothing)
scripts/auto-deploy --dry-run --since-site HEAD~5 # as if the last deploy were 5 site commits back
scripts/auto-deploy                               # one run by hand (retries a failed deploy)
touch ~/.config/tinytrader/auto-deploy.off        # kill switch: runs do nothing while it exists
rm ~/.config/tinytrader/auto-deploy.off           # resume
cat ~/.local/state/<deployment name>/auto-deploy.json   # the deployed commits, services, time; history
tail ~/Library/Logs/tinytrader/auto-deploy.log
```

(`--since-stack` and `--since-tinytrader` do the same for the other two
checkouts.)

**Turning it on:** in the machine's configuration (your machines
repository), set `tinytrader-deploy.autoDeploy.enable = true;`, update the
site input there, and switch. It is a launchd agent
(`com.tinytrader.auto-deploy`, running while you are logged in: a private
site's `git fetch` uses gh's keychain token, which a daemon can't read).
Make the deploy checkouts first. The first run takes what is checked out as
already deployed. A failed deploy is notified once and not retried until
new commits arrive or you run it by hand. Notices go to the site's
`secrets/notify.env`, as the monitor's do.

### The deploy checkouts

On a services host the containers, auto-deploy and the nightly backup use
clones that nothing else touches ([decision 0012](decisions/0012-deploy-checkouts.md)):

```
<deployRoot>/<site name>         the site: the Compose project, state/console, the queue's templates
<deployRoot>/tinytrader-deploy   this stack: the scripts the launchd jobs run
<deployRoot>/tinytrader          TINYTRADER_SRC: the images are built from it; its docs in the console
```

`<deployRoot>` is nix-darwin's `tinytrader-deploy.deployRoot` (default
`~/.local/share/tinytrader/deploy`), given to the launchd jobs and the
shells nix-darwin manages as `TINYTRADER_DEPLOY_ROOT`; the scripts default to
the same path (moving it means exporting `TINYTRADER_DEPLOY_ROOT` in your
shell too). `<site name>` is the inventory's `deployment.name`
(`tinytrader-deploy.checkouts.site` overrides it). Don't edit, commit or
switch branches in them: auto-deploy keeps them on `main`. Your working
copies are ordinary; nothing live reads them. `scripts/deploy`,
`scripts/local-up.sh` and `scripts/auto-deploy` run from a working copy say
so and run the deploy checkout's copy with the same arguments, so a deploy
by hand is of what is merged (as of the last auto-deploy run), never of the
branch you are on. A machine without deploy checkouts (a Mac you sit at, CI)
runs from the checkout the script is in.

Making them (once per services host, before turning on auto-deploy, and on
a rebuilt host):

```sh
root=~/.local/share/tinytrader/deploy           # or your tinytrader-deploy.deployRoot
name=$(nix eval --raw --file ~/repos/my-site/inventory.nix deployment.name)
mkdir -p "$root"
git clone <your site's git URL> "$root/$name"
git clone https://github.com/<owner>/tinytrader-deploy.git "$root/tinytrader-deploy"
git clone https://github.com/<owner>/tinytrader.git "$root/tinytrader"
```

Each must be on `main`. A script that finds the site's clone but not the
other two says which is missing and stops.

**A console-state conflict** (notified as "console state conflicts with
origin/main"): a commit on main changed a reminder, the journal or the
layouts the console changed too. Auto-deploy stops (it deploys nothing until
it is fixed); the console's edits are committed in the site's deploy
checkout. Merge them there, after hours:

```sh
cd ~/.local/share/tinytrader/deploy/<site name>
git log --oneline origin/main..HEAD     # the console's commits
git rebase origin/main                  # resolve state/console/*.json, keeping both sides' entries
python3 -m json.tool state/console/reminders.json >/dev/null   # it parses (the console refuses edits until it does)
git push origin HEAD:main
```

A container keeps the paths it was created with: one created before the
deploy checkouts existed still mounts the old checkout until it is
redeployed. Services auto-deploy never touches (strategies, gateways,
relays) are the ones to watch: redeploy each by hand once.

### Check health

The console's Services page, or from a shell on the host that runs it:

```sh
curl -s http://127.0.0.1:8080/api/state | python3 -c '
import json, sys
for k, v in sorted(json.load(sys.stdin)["services"].items()):
    b = (v.get("health") or {}).get("body") or {}
    print("%-24s %-10s %s" % (k, b.get("state", "-"), b.get("detail", "")))'
curl -s http://127.0.0.1:9120/health      # the store (native), on its host
df -h / <each data root>                  # the disks (on macOS read Avail, not Capacity, for /)
```

`idle` outside a service's hours is normal (relays, accounts). `-` is a
service without tinytrader's health endpoints (gateways, strategies,
research): judge it by `docker ps`.

### Logs

```sh
docker logs --tail 200 -f <deployment name>-console-1   # any container: <deployment name>-<service>-1
tail -f ~/Library/Logs/tinytrader/store.log             # native services: <name>.log
launchctl print gui/$(id -u)/com.tinytrader.store       # a native agent's state
tail /Library/Logs/tinytrader-data/databento-jobs.log   # the Databento key's holders
```

Containers keep 3 x 10 MB of logs; native logs are rotated by newsyslog past
10 MB, keeping 7. Order journals are in `~/.local/state/order-gateway/<account>`.

### Backups

Every night (the inventory's `backup.at`, outside market hours) the host
that runs the services takes a snapshot of its state, keeps the inventory's
`backup.keep.daily` daily and `backup.keep.weekly` weekly snapshots, and
sends the newest, encrypted, to another host. It is the `backup` service in
the inventory (placed with the services, so it moves with them): on a Mac a
launchd daemon, `com.tinytrader.backup`, run as the primary user
(`modules/backup-darwin.nix`); on NixOS a systemd timer (`modules/nas.nix`).
The monitor warns when the newest snapshot, or the newest off-host copy, is
older than `monitoring.backup.maxAgeHours`.

```sh
scripts/backup-state                       # a snapshot now, into ~/Backups/tinytrader/<date-time>
scripts/backup-state --dry-run             # what it would copy, pause and send; writes nothing
scripts/backup-state --scheduled --dry-run # the nightly job, as a dry run
scripts/backup-state --prune --dry-run     # what the retention would delete
scripts/backup-state --list-volumes        # the volumes it copies, and why
scripts/backup-state --offhost             # send the newest snapshot off the host again
sudo launchctl kickstart system/com.tinytrader.backup   # run the nightly job now
tail ~/Library/Logs/tinytrader/backup.log
ls -l ~/.local/state/tinytrader-backup     # last-backup, last-offhost: when each last succeeded
```

**What a snapshot holds** (`~/Backups/tinytrader/<date-time>`, mode 700):

- `volumes/<v>.tar`: every named volume in the site's `compose.yaml`
  (`volumes:`; the list isn't written anywhere else), plus any other volume
  labelled with the project, as a tar that keeps owners and modes. While a
  volume is copied, the running containers that mount it are **paused**
  (`docker pause`, a freeze for a second or two, then unpaused), so the copy
  is consistent: what a power cut at that instant would leave. Gateways are
  never paused.
- `order-gateway/`: the gateways' state roots, copied **live**. A journal is
  append-only, one file per UTC day, each line fsync'd before what it
  announces, and a closed day is never rewritten, so a copy taken while the
  gateway runs is the journal up to a moment, plus at most one half-written
  last line. The copy cuts that line (as the gateway does on start), then
  verifies each account's hash chain and `seq`; a broken chain fails the
  backup. `KILL` is kept; `lock` is not.
- `repos/`: the site, this stack and tinytrader, with `.git` and uncommitted
  files, without build output (unchanged files are hard links to the
  previous snapshot): the deploy checkouts where the host has them, else
  `BACKUP_REPOS` (`~/repos`). Work in progress in a working copy on a host
  with deploy checkouts is not in the snapshot: push it.
- `MANIFEST.json` (each volume, each gateway's last `seq`) and `SHA256SUMS`.

Not in it: market data (the store's drives), and **no key of any kind**.
Secrets are recovered with the operator key (on the machines you sit at and
in your password manager) or the recovery key (the inventory's
`secrets.recovery`, its private half kept offline); see
[Losing the age key](#losing-the-age-key).

`nix flake check` fails if `compose.yaml` gains a writable mount the backup
doesn't cover (`checks/backup.nix`), or if a host with stateful containers
has no backup.

**The off-host copy.** After each snapshot, the newest is packed into one
file, `<date-time>.tar.zst.age`, encrypted with age to the operator key and
the recovery key (their public halves, from the inventory), and sent with
rsync over SSH on the tailnet to the inventory's `backup.offHost.<host>`
host, as its `backup.accounts.<that host>` user, into
`~/Backups/tinytrader-from-<host>` (mode 700). Older copies there are
deleted as the snapshots are pruned here, so it keeps the same daily and
weekly set. The sending host uses its own key, `~/.ssh/tinytrader-backup`,
which never leaves it; the receiving host accepts that key only with
`restrict,from="<the tailnet's ranges>",command="rrsync -wo <that directory>"`:
no shell, no forwarding, write-only, one directory. It can't read anything
back. Nothing is sent without age recipients: never plain text off the host.

**Setting up the off-host copy** (once per sending host; here `desk` sends
to `vault`):

1. On the sending host (`desk`): `ssh-keygen -t ed25519 -N '' -C tinytrader-backup@$(hostname -s) -f ~/.ssh/tinytrader-backup`
2. In the site's `inventory.nix`: the `.pub` file's line as
   `backup.keys.desk`, `backup.offHost.desk = "vault"`, and the receiving
   user as `backup.accounts.vault`; `nix flake check`, commit, push.
3. On the receiving host (`vault`): its machine configuration sets
   `tinytrader-deploy.backup.receive = true;`; update the site input and
   switch (on NixOS, `modules/nas.nix` does the same). Remote Login (sshd)
   must be on there.
4. On the sending host, apply its role again (it now sends, and its monitor
   watches the copy's age), then `scripts/backup-state --offhost`. The first
   connection records the receiver's host key in
   `~/.local/state/tinytrader-backup/known_hosts`.
5. On the receiving host: `ls -l ~/Backups/tinytrader-from-desk`.

When the services move to another host, the backup moves with them: give
the new sender its own key the same way.

Run `scripts/backup-state` by hand before any change to the gateways, a
Docker engine change, or moving services between hosts.

### Console layouts

The console's reminders, journal and curated views live in git, in the
site's `state/console/` ([decision 0009](decisions/0009-console-state-in-git.md));
the checkout's folder is mounted into the console, writable. Day-to-day
settings and profile recordings stay in the `console-data` volume.
`scripts/backup-state` copies both: the volume, and the repository with its
uncommitted files, so reminder edits not yet committed are in the snapshot
too.

```sh
scripts/console-promote            # the console's views, watchlists, theme and palette into state/console/layouts.json
scripts/console-promote KEY...     # other settings instead
scripts/console-promote --reset    # after a pull or hand edit: the committed views apply; reload open tabs
git -C <site> diff state/console   # review (no tokens, no account numbers), then commit
```

Reminders and journal entries edited in the console land in `state/console/`
of the checkout the console runs from (the deploy checkout, on a services
host), and auto-deploy commits and pushes them; `git pull` brings them to
your working copy. Where there are deploy checkouts, `scripts/deploy console`
mounts the deploy checkout whichever checkout you run it from; elsewhere,
deploy the console from the main checkout, never a worktree: the mount
follows the checkout the script runs from.

## Changes

Every change: edit, `nix flake check`, commit on a branch, merge, push.
Where there are deploy checkouts auto-deploy picks it up; elsewhere `git
pull` on each host it touches before deploying.

### Move a service

1. Change its `host` in the site's `inventory.nix` `services` (for a native
   service, its runtime and `deployment.native.<service>` settings follow).
   `nix flake check` says what else must follow: neighbours
   (`colocateWith`), data roots, secrets.
2. If the new host decrypts with its own key, `scripts/secrets-recipients`.
3. Commit, push, and pull on both hosts, then `scripts/tailnet-serve --apply`
   on both (its forwards move with it).
4. On the old host, stop it: `scripts/deploy --remove <service>` for a
   container (refused while it is still placed there, and for a live relay),
   or apply that host's config for a native one.
5. On the new host: `scripts/deploy <service>` (a native one: apply its
   machine configuration, after updating the site input).

Stop on the old host before starting on the new one for anything with state
(the gateways, strategies, the queue), and carry its state across (its
volume, through `scripts/backup-state` and `scripts/restore-state`, or
`~/.local/state/order-gateway/<account>`). Never two Databento sessions on
one stream: a relay or databento-jobs refuses to start while its ports are
taken, so stop the old one first. The live gateway follows [Rules](#rules).

Moving every service at once (a new services host) is the same, after
hours, with the operator's go-ahead: a backup on the old host; change
`servicesHost`; `scripts/deploy --remove` everything on the old host, the
live gateway among them, and confirm it is gone; restore the state on the
new host; `scripts/local-up.sh` there; apply both hosts' roles (the monitor
expects what is placed on it); `scripts/tailnet-serve --apply` on both.
Rolling back is the same in reverse, the live gateway again stopped on one
host before it starts on the other.

### Add a host

1. Give it a machine configuration in your machines repository (Nix,
   Tailscale, SSH, the Docker engine where it runs containers) that imports
   the site's `darwinModules.<host>` (a Mac) or `nixosModules.<host>`.
2. Add it to the site's `inventory.nix` `hosts`: its name, `tailnetName`
   and `tailnetAddress`, its data roots, and under `deployment.hosts.<host>`
   its `dockerSocket` if not Colima's. If it decrypts secrets with its own
   SSH host key, its `secrets.hosts.<host>` recipient, then
   `scripts/secrets-recipients`.
3. Regenerate the tailnet policy (`scripts/tailscale-policy`) if its tags
   or ports change who may connect.
4. Switch it, join it to the tailnet (`scripts/tailscale-join`), then place
   services on it ([Move a service](#move-a-service)).

### Add a service

1. A tinytrader service lands in tinytrader first (with its image,
   `image-<name>`), then in the site.
2. Add it to the site's `deploy/local/compose.yaml`, following the others
   (`<<: *service`, a memory cap, every port published on `127.0.0.1` at
   its own number, secrets as files). Unless it is `localOnly`, its host
   forwards them from the tailnet: `scripts/tailnet-serve --apply` there
   after the deploy.
3. Add it to `inventory.nix` `services`: `host` (usually `servicesHost`),
   `runtime`, and its `colocateWith`, `secrets`, `dataRoots`, `profile`.
4. Optionally a panel or edges for it in `deploy/local/topology.json`.
5. `nix flake check`, commit, push, pull on its host, `scripts/deploy <name>`.

### Rotate or add a secret

Run these yourself, in your own terminal: agents never create or print
secrets. The exact commands are in the site's `secrets/README.md`:

- **Replace a value:** the file's create command again (each re-encrypts the
  whole file), commit, then redeploy what reads it: `scripts/deploy <service>`
  (gateway tokens: the gateway and its clients).
- **Add a gateway token:** `scripts/gateway-token GATEWAY_<NAME>_TOKEN`.
- **Add a file:** create it with sops, add its pattern to `secrets.files`
  in `inventory.nix` with the hosts that use it, then
  `scripts/secrets-recipients`.
- **Add a recipient** (a server's SSH host key, or the recovery key): put the
  age public key in `inventory.nix` (`secrets.hosts.<host>` from
  `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` on that host, or
  `secrets.recovery`), then:

  ```sh
  scripts/secrets-recipients --check   # what .sops.yaml would be
  scripts/secrets-recipients           # write it and re-encrypt every file
  git -C <site> add .sops.yaml secrets && git -C <site> commit
  ```

- **Retire a machine:** remove its recipient, re-run, and rotate every secret
  it could read.

### The Databento key

Only databento-jobs and the OPRA relays can read it
([decision 0013](decisions/0013-databento-key-held-by-its-services.md)):
native launchd daemons on their host, run as `_ttdata`, a hidden system user
of their own, from `modules/databento-darwin.nix` (the role imports it where
the placement map runs databento-jobs or a `relay-*` with runtime
`launchd`). The site's `secrets/databento.yaml` is encrypted to that host's
SSH host key and the recovery key, not the operator key (the inventory's
`secrets.hostOnly`), and sops-nix writes `/run/secrets/databento_api_key`
and `/run/secrets/jobs_approve_token` (`_ttdata`, 0400). You can't read it
without sudo; agents can't at all. No container holds it.

```sh
sudo launchctl print system/com.tinytrader.<relay> | grep -E 'state|pid'
tail -f /Library/Logs/tinytrader-data/<relay>.log            # and databento-jobs.log
sudo launchctl kickstart -k system/com.tinytrader.databento-jobs   # restart (after hours for a relay)
scripts/databento-key keys          # the names it holds, never the values (on its host; sudo)
scripts/databento-key set DATABENTO_API_KEY   # replace a value, read without echo
scripts/databento-key edit          # open it in $EDITOR
scripts/databento-key updatekeys    # re-encrypt after scripts/secrets-recipients changed .sops.yaml
```

After changing it: commit, merge, apply the host's role (update the site
input in your machines repository and switch), so sops-nix writes the new
values, then after hours restart what reads them with `launchctl kickstart
-k`. Without that host (or its host key): the recovery key, `SOPS_AGE_KEY_FILE=<file
with it> sops edit secrets/databento.yaml`.

Each daemon refuses to start while its ports are taken (an old container,
or the same service elsewhere), and databento-jobs while it has no ledger
(`/var/lib/tinytrader/databento-jobs/submissions.jsonl`), so no purchase is
made without the record of the earlier ones; both say so in their log and
try again a minute later. A relay's symbols and whether it starts are the
inventory's `deployment.native.<relay>` (`symbols`, `enable`), its hours
`deployment.captureHours`. Data for research is bought in the console's Data
section; `tt.databento()` stops with "purchases go through databento-jobs".

**Moving them from containers to the daemons** (once, after a close; the
same for moving them to another host): stop the containers that held the
key first (`scripts/deploy --remove databento-jobs <relays>`, which sends
SIGTERM so the relays close their sessions), check nothing listens on their
ports (`lsof -nP -iTCP -sTCP:LISTEN`), and remove any copy of the key left
in a volume. Apply the host's role (the user, the secrets, the daemons).
Copy the ledger out of the old volume into place:

```sh
docker run --rm --network none -v <deployment name>_jobs-data:/d:ro alpine:3 cat /d/submissions.jsonl > /tmp/submissions.jsonl
sudo install -o _ttdata -g _ttdata -m 644 /tmp/submissions.jsonl /var/lib/tinytrader/databento-jobs/submissions.jsonl && rm /tmp/submissions.jsonl
```

Then check the daemons run as `_ttdata` and are healthy, and the login user
can't read the key anywhere:

```sh
ps -axo user,pid,command | grep -E '[r]elay|[d]atabento-jobs'      # _ttdata
cat /run/secrets/databento_api_key                                 # Permission denied
ls -lL /run/secrets/databento_api_key /run/secrets/jobs_approve_token   # -r-------- _ttdata
sops decrypt secrets/databento.yaml                                # fails: no operator key recipient
```

The next session, at the capture hours' start, the relays' `/health` says
`ready` and the console's graph shows them on their host.

### The console's write gate

Reads are open; every write to the console (orders, settings, reminders,
the journal) needs the page opened at its tailnet name and an allowed
Tailscale login, and a live order, or any flatten or resume, also the order
token (tinytrader's console API, "The write gate"). In the stack:

- `CONSOLE_HOSTS` is the console host's tailnet name (`TT_HTTPS_NAME_CONSOLE`
  from the placement map), so only `https://<its tailnet name>.<tailnet
  domain>` can write.
- `CONSOLE_ORDER_LOGINS` and the order token are in the site's
  `secrets/console.env`. `scripts/deploy` and `local-up.sh` decrypt it; the
  token is mounted as `/run/secrets/console_order_token`. Paper flatten and
  resume need the token too (the default).
- The console's port is `localOnly`: never forwarded across hosts, only
  `tailscale serve`'s HTTPS reaches it. Research reads it there.

Writes from the host's own shell (`http://127.0.0.1:8080`, such as
`scripts/console-promote --reset`) are refused: use the page.

To add a login, in your own terminal:

```sh
sops edit secrets/console.env    # in the site: CONSOLE_ORDER_LOGINS=you@example.com,other@example.com
git commit secrets/console.env   # then, on the console's host:
scripts/deploy console
```

`GET /api/write-gate` says whether writes are on (never the logins or the
token).

### Update the tinytrader pin

In the site:

```sh
nix flake update tinytrader   # take tinytrader's main
nix flake check
git commit -am "Pin tinytrader at <rev>: <why>"
```

The pin decides the native services (the store, the monitor, the Databento
key's holders) and what the checks evaluate. Containers build from the
checkout instead, so for them `git -C ../tinytrader pull` and
`scripts/deploy <service>` (auto-deploy does both where it runs). Then apply
the native side on each Mac: in your machines repository, update the site
input, commit, and switch (or `scripts/darwin-switch`, for a Mac whose whole
configuration is in the site). The same for `tinytrader-deploy` itself: the
site pins it too.

`TINYTRADER_SRC=../tinytrader scripts/darwin-switch` builds native services
from a local checkout instead of the pin, for development only.

### Native services: agents and daemons

A native service on a Mac runs either as a launchd agent of the primary
user (it starts at login, in `gui/<uid>`) or as a boot-time daemon
(`launchd = "daemon"` on its `tinytrader.services` definition; it starts at
boot with no login, in `system`). The monitor and node_exporter are daemons
(`modules/watch-darwin.nix`), and so are the Databento key's holders (as
`_ttdata`); the store and alpaca-history (`modules/store-darwin.nix`) are
agents.

```sh
launchctl print system/com.tinytrader.watch | grep -E 'state|last exit'    # a daemon (no sudo needed)
launchctl print gui/$(id -u)/com.tinytrader.store | grep -E 'state|last exit'  # an agent
sudo launchctl kickstart -k system/com.tinytrader.watch                    # restart a daemon
```

**Switching a service from agent to daemon:** nix-darwin removes the
agent's plist, but can't unload a running agent from your login session,
and a leftover agent keeps running beside the new daemon (the daemon then
loops on "already running", or can't take its port). Activation boots the
old agent out before loading the daemon (tinytrader's darwin-services).
Right after the switch, as the primary user, check that it did, and boot out
anything left:

```sh
launchctl print gui/$(id -u)/com.tinytrader.<name> >/dev/null 2>&1 && launchctl bootout gui/$(id -u)/com.tinytrader.<name>
launchctl print system/com.tinytrader.<name> | grep 'state ='   # running
ls ~/Library/LaunchAgents | grep tinytrader                    # only the agents that should be there
```

A daemon that started while the agent still held its port retries and
comes up once the agent is gone; `sudo launchctl kickstart -k
system/com.tinytrader.<name>` hurries it.

## Incidents

When something is down, look at the disk and the Docker engine first: a
full system disk stops the Docker engine's VM, and then every container
looks down at once, relays included, though no relay is at fault.

### The disk is full

```sh
df -h /                            # Avail is what's left on the system disk
du -sh ~/repos ~/.cache/* ~/.colima ~/Backups 2>/dev/null | sort -h
docker system df
```

Clean, in this order, until there is room again (well above the monitor's
`monitoring.disk.minFreeGiB` floor):

1. **Agent worktrees** that are finished: `git -C ~/repos/<repo> worktree list`,
   then `git -C ~/repos/<repo> worktree remove <path>` (check `git -C <path>
   status` first: uncommitted work is lost). `git worktree prune` after.
2. **Rust build output.** The daily `disk-hygiene` job removes idle targets
   (decision [0016](decisions/0016-disk-hygiene.md)); to see what it would
   remove now: `DISK_HYGIENE_ROOTS=repos:.cache/cargo-target sh
   <stack>/deploy/nomad/disk-hygiene.sh --dry-run`. A shared target (see
   [Agent hygiene](#agent-hygiene)) can go when no build is running.
   Older checkouts may still have their own:
   `find ~/repos -maxdepth 3 -type d -name target -prune -exec du -sh {} +`.
3. **Nix:** `nix store gc` (unreferenced paths only; generations stay for
   rollback).
4. **Docker:** `docker image prune` (dangling images), `docker builder prune`.
5. **Old backup folders** in `~/Backups/tinytrader`, once copied elsewhere
   (the retention keeps the rest).

**Never:** `docker volume prune`, `docker system prune --volumes`, `docker
compose down -v`, deleting the engine's disk image, or anything on a data
root or in `~/.local/state/order-gateway`. The volumes are the console's
state, the submissions ledger, the strategies' state and the queue.
`docker system df` counts volumes as "reclaimable" whenever their container
is stopped: they are not.

Then, if Docker stopped, the next section.

### The Docker engine is down

`docker info` fails, or every container is gone from the console.

**Colima as a boot daemon** (the stack's default engine on a Mac):

```sh
colima status                                    # as the primary user
sudo launchctl print system/org.nixos.colima | head -20
tail -50 ~/Library/Logs/colima.err.log
sudo launchctl kickstart -k system/org.nixos.colima   # restart it
```

Don't run `colima start` or `colima stop` by hand while the daemon runs:
launchd keeps it alive, and the daemon's flags (CPUs, memory, disk, mounts,
in the machine's configuration) are the configuration. Change them there and
switch. Containers under Colima restart with the engine (`unless-stopped`).

**An engine started by hand or at login** (Docker Desktop, say): start it
and wait until `docker info` answers. Quitting or crashing such an engine
counts as stopping the containers, so `unless-stopped` doesn't bring them
back:

```sh
docker ps -a --filter label=com.docker.compose.project=<deployment name> --format '{{.Names}}\t{{.Status}}'
docker start $(docker ps -aq --filter label=com.docker.compose.project=<deployment name>)
```

`docker start` restarts them as they were, with no build.
`scripts/local-up.sh` also works but rebuilds every image (not in market
hours).

### A relay is down

1. Is it in its hours? Outside them `idle` is normal. Relays left off in
   the inventory (`enable = false`) or in a non-default Compose profile are
   off by design.
2. The disk and the engine, above.
3. Its log: a native relay's `/Library/Logs/tinytrader-data/<relay>.log`,
   a container's `docker logs --tail 100 <deployment name>-<relay>-1`. Look
   for a provider error (the key, a session limit), a port taken, or a
   crash.
4. Restart it without a build: `sudo launchctl kickstart -k
   system/com.tinytrader.<relay>` (a container: `docker restart
   <deployment name>-<relay>-1`).

Its clients (the data services, the queue, databento-jobs, strategies)
reconnect; records missed while it was down are not recovered.

### A relay falls behind

The relay is up but slow: its health says `degraded`, its clients see stale
data, or the provider reports skipped records. Almost always the host's CPUs
are taken by something else: an image build, a Rust build, a backup's
compression, research.

1. Look at the load: `top -o cpu` on the relay's host, and `docker stats
   --no-stream` for the containers.
2. Stop what is taking it: a build (it should not have run in market hours:
   find out why, [Rules](#rules)), a research job (pause it in the queue), a
   process an agent started.
3. Don't restart the relay to fix it: a restart drops its clients and loses
   more records than the lag. Restart only if it doesn't catch up once the
   load is gone.
4. Note the gap: records skipped by the provider are not recovered by the
   relay; if they matter, buy the window afterwards through databento-jobs.

To keep it from happening: builds only outside market hours, heavy research
through the queue (it runs host jobs one at a time under `taskpolicy -b`),
and, if a host keeps running out, the relays on a host of their own.

### The store is down

On the store's host (`vault` in the example site):

```sh
curl -s http://127.0.0.1:9120/health
launchctl print gui/$(id -u)/com.tinytrader.store | grep -E 'state|last exit'
tail -50 ~/Library/Logs/tinytrader/store.log
ls /Volumes                        # every drive mounted?
launchctl kickstart -k gui/$(id -u)/com.tinytrader.store
```

On a Mac it is a launchd agent, so it runs only while the primary user is
logged in (unlike the monitor and node_exporter, boot-time daemons).
`degraded` with "fullest critical" means a drive is near full: new downloads
go only to a drive below the threshold. Making room is the operator's
decision (moving data, a new drive), never deleting market data.

### The console is down

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/state
docker logs --tail 100 <deployment name>-console-1
docker restart <deployment name>-console-1
```

It needs the topology file: if the log says so,
`scripts/placement topology ~/.local/state/<deployment name>/topology.json`,
then `scripts/deploy console`. Reachable on the host but not from the phone:
`tailscale serve status` on the host, and Tailscale signed in there.

### A host is down or rebooted

Set each Mac to restart after a power cut (`pmset autorestart`). What comes
back depends on FileVault:

- **FileVault on:** after any restart it stops at the FileVault unlock
  screen with no network: no Tailscale, no SSH, nothing runs until someone
  types the password at the machine. For a planned remote restart use
  `sudo fdesetup authrestart`, which unlocks the next boot once. After the
  unlock, the boot-time daemons (the monitor, node_exporter, Colima) start
  before anyone logs in; agents (the store) wait for a login.
- **FileVault off:** it boots to the login window on its own, and the
  boot-time daemons start with no login. The containers come back with
  Colima, and the heartbeat resumes without anyone at the machine.

Then check health as in [Daily](#check-health).

### An alert arrived

Alerts need the site's `secrets/notify.env` ([monitoring.md](monitoring.md));
without it the monitors only log (`~/Library/Logs/tinytrader/watch.log`).

| Notice | Go to |
|---|---|
| Docker engine not answering | [The Docker engine is down](#the-docker-engine-is-down) |
| A disk at its warning or high-priority threshold, under the free-space floor, or not mounted | [The disk is full](#the-disk-is-full); a drive unplugged: plug it in, `launchctl kickstart -k gui/$(id -u)/com.tinytrader.store` |
| A container missing, stopped or restarting | `docker logs` for it, then the section for its kind |
| The console not answering, or a service `failed` / degraded | [The console is down](#the-console-is-down), or that service's logs |
| A native service not running | `launchctl print system/com.tinytrader.<name>` (a daemon) or `gui/$(id -u)/com.tinytrader.<name>` (an agent), and its log |
| A backup or off-host copy too old | [Backups](#backups): its log, then `scripts/backup-state --scheduled --dry-run` |
| The heartbeat "down" | [A host is down or rebooted](#a-host-is-down-or-rebooted): the host is off, offline, locked at FileVault, or its monitor died |

A "resolved" notice follows when it clears.

## Recovery

### Rebuild a host from scratch

The machine comes from your machines repository; this stack only adds its
role. Keep the host's identity where you can: the same SSH host key (so
known_hosts everywhere, and any sops recipient made from it, still hold) and
the same Tailscale name and address (the inventory's
`hosts.<host>.tailnetName` and `tailnetAddress`).

**Before the wipe** (if the machine still runs):

- a snapshot: `scripts/backup-state`, and check the newest off-host copy
  landed;
- the SSH host keys, saved encrypted wherever your machines repository keeps
  host identities (or, if you won't keep them, plan to replace the host's
  sops recipient: [Rotate or add a secret](#rotate-or-add-a-secret));
- what is in neither git nor a backup: unpushed work, other hosts' off-host
  copies it receives (`~/Backups/tinytrader-from-*`), launchd jobs and
  tools that aren't the machine configuration's;
- that the new configuration builds, from another machine.

**Then, on the rebuilt machine** (`desk` in the example):

1. Install Nix, clone your machines repository and switch: that applies the
   machine (Tailscale, SSH, the Docker engine) and this stack's role. Turn on
   Remote Login. If you saved the SSH host keys, put them back before
   anything else connects.
2. Join the tailnet and take back the old name and address, from a machine
   already on it (`TARGET` is an ssh destination, before Tailscale its LAN
   address):

   ```sh
   scripts/tailscale-join TARGET                    # prints a login URL: open it, sign in (a machine you own)
   scripts/tailscale-join TARGET --tags tag:<tag>   # or tagged and unattended, with the site's OAuth client
   scripts/tailscale-pin desk <its tailnetAddress>          # dry run: lists the devices
   scripts/tailscale-pin --apply --prune desk <its tailnetAddress>  # deletes the stale ones, renames, sets the address
   ssh desk true                                    # the old known_hosts entry holds: no warning
   ```

   `scripts/tailscale-pin` uses the site's `secrets/tailscale.env` OAuth
   client (devices:core scope to rename, set the address and prune).
3. The operator age key, if this is a machine you decrypt secrets on, from
   your password manager:

   ```sh
   mkdir -p "$HOME/Library/Application Support/sops/age"
   pbpaste > "$HOME/Library/Application Support/sops/age/keys.txt" && chmod 600 "$HOME/Library/Application Support/sops/age/keys.txt"
   ```

   A host whose services decrypt with its own SSH host key needs no copy;
   with a new host key, add its recipient ([Rotate or add a secret](#rotate-or-add-a-secret)).
4. Your working copies (`tinytrader`, `tinytrader-deploy`, the site, side
   by side), and on a services host the deploy checkouts
   ([The deploy checkouts](#the-deploy-checkouts)).
5. `scripts/tailnet-serve --apply`, then restore the state
   ([Restore from backup](#restore-from-backup)) and `scripts/local-up.sh`
   once services are placed on it. If it sends backups, it needs a new
   backup key ([Backups](#backups), "Setting up the off-host copy").
6. Check health ([Daily](#check-health)), and that the next nightly backup
   and off-host copy land.

### Tailnet Lock

With Tailnet Lock on, a device joins only when one of the signing machines
signs it, so Tailscale's coordination server can't add one by itself
(https://tailscale.com/kb/1226/tailnet-lock). `scripts/tailnet-lock init
SSH_TARGET...` turns it on (this machine and the targets sign; two or more),
saving the disablement secrets sops-encrypted without showing them (the
site's `secrets/tailnet-lock.yaml` by default, or `--secrets FILE`). Run
these on a signing machine, in a terminal (they sudo):

| When | Run |
|---|---|
| A new or reinstalled device shows "Locked out" | `scripts/tailnet-lock sign NAME` (its name in `status`'s locked-out list), or `sign SSH_TARGET`. `scripts/tailscale-join` does this itself |
| Another machine should sign too | `scripts/tailnet-lock trust SSH_TARGET` |
| A signer is wiped or gone | `scripts/tailnet-lock untrust tlpub:KEY` (keep at least two) |
| Turn it off (every signer lost) | `tailscale lock disable <secret>`, a secret from the encrypted file (`sops -d`). One use makes that secret public; turning it on again makes new ones |

A phone can be signed from the admin console too (Machines, the "Locked
out" badge, Sign). Device approval and Tailnet Lock can't both be on.

### Restore from backup

`scripts/restore-state` is a dry run unless `--apply`: it checks the
snapshot's `SHA256SUMS`, then says what it would do. It refuses a volume
that a running container mounts, and a gateway that is running or whose
journal here is **ahead** of the snapshot's (a higher `seq`: orders the
snapshot doesn't know; `--force` only after you have looked). What it
replaces is kept: a volume's contents in
`~/Backups/tinytrader-pre-restore/<time>/volumes`, a gateway's state root
moved there, never deleted.

On the host that should hold the state (the services' host), with the
services stopped:

```sh
ls ~/Backups/tinytrader/                          # local snapshots, newest last
b=~/Backups/tinytrader/<date-time>
jq . "$b/MANIFEST.json"                            # what it holds; each gateway's last seq
scripts/deploy --remove <services>                 # stop what uses the state (the live gateway last)
scripts/restore-state "$b"                         # dry run: every volume and gateway
scripts/restore-state "$b" volume:console-data gateway:<account>   # or some of them
scripts/restore-state --apply "$b" volume:console-data gateway:<account>
scripts/deploy <services>
```

From another host's encrypted copy (this host's disk lost): copy the file
over, then restore from it with the operator key (found under your home by
default) or the recovery key:

```sh
scp vault:Backups/tinytrader-from-desk/<date-time>.tar.zst.age ~/
scripts/restore-state ~/<date-time>.tar.zst.age                     # decrypts into a private temporary folder, dry run
scripts/restore-state --key ~/recovery-key.txt --apply ~/<date-time>.tar.zst.age
```

(`--key` takes the recovery key pasted from your password manager into a
file; delete it after.) Then compare each gateway's last `seq` with what the
broker shows, before it trades: a gateway restored from last night's journal
reconciles with the broker on start, but orders placed since are only at
the broker. Repositories are never written: clone them, and take unpushed
work from `$b/repos/<name>` with git
(`git -C $b/repos/<name> log --branches --not --remotes`).

### Losing the age key

The operator key (`~/Library/Application Support/sops/age/keys.txt`)
decrypts every secret but the host-only ones, and the off-host backups.
Keep copies on the machines you sit at and in your password manager; no
backup holds it. If every copy is lost, the recovery key (`secrets.recovery`
in the inventory, its private half kept offline) decrypts every secret and
every off-host backup made since it was added:
`SOPS_AGE_KEY_FILE=<file with it> sops decrypt ...`, and
`scripts/restore-state --key <file with it> <date-time>.tar.zst.age`. Then
make a new operator key, put its public half in the inventory
(`secrets.operator`) and run `scripts/secrets-recipients`.

## Agent hygiene

- **Work in a worktree on a branch, never on `main`**, and never in the
  deploy checkouts (`<deployRoot>/*`, by default
  `~/.local/share/tinytrader/deploy/*`) or any checkout a service runs from:
  `git -C ~/repos/<repo> worktree add ~/repos/wt/<name> -b <branch> origin/main`.
  Merging is the operator's call.
- **Remove your worktree when done:** `git -C ~/repos/<repo> worktree remove
  ~/repos/wt/<name>`, and delete scratch files.
- **One cargo target per repository, per machine** (decision
  [0016](decisions/0016-disk-hygiene.md)): every checkout of a repository,
  its worktrees included, builds into
  `~/.cache/cargo-target/<repo>/target`, never a `target/` of its own.
  This stack's `scripts/cargo-shim` sets `CARGO_TARGET_DIR` so, from the
  repository's common Git folder (a worktree gets its main checkout's).
  Your machines repository installs it as `cargo` on PATH ahead of the real
  one, for example in a directory first on PATH in `~/.zshenv`, so it
  covers interactive shells, `zsh -c` and agents' shells alike. A
  `CARGO_TARGET_DIR` already set wins: the Nomad build and test jobs set
  the deploy checkout's own (`<checkout>/target`), so a working copy's
  build never overwrites the binaries a deploy built. Concurrent builds of
  one repository wait for cargo's lock; that is expected. The
  `disk-hygiene` job deletes a target idle for 7 days (with
  `.cache/cargo-target` among the node's `cleanRoots`).

  Moving from one global target (`[build] target-dir` in
  `~/.cargo/config.toml`), once per machine:
  1. Drop `target-dir` from `~/.cargo/config.toml` in your machines
     repository, with no fallback: a global target nobody cleans is what
     filled the disk, and the per-repository ones would sit inside it.
  2. Install the shim and switch the machine.
  3. Outside market hours, with no build running, delete the old global
     target's own folders by hand:
     `cd ~/.cache/cargo-target && rm -rf debug release CACHEDIR.TAG .rustc_info.json`
     (and any target triple folder, such as `aarch64-apple-darwin`),
     leaving only `<repo>/target` folders.
- **No large outputs on the system disk:** no datasets, downloads or long
  logs under `~` or `/tmp`. Research output goes through the store or to a
  data root, with the operator's say.
- **Market hours** apply to agents too: no builds or heavy work 09:25-16:20
  New York time on trading days, on any host that runs services.
- Long-running processes started by hand go in a named tmux session so they
  survive the terminal: `tmux new-session -d -s <name> <command>`.
- Never print, create or commit secrets; never run `scripts/databento-key`;
  never touch the live gateway.
