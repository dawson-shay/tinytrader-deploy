# Batch jobs: what the queue's templates need

tinytrader removes its job queue (tinytrader decision 0020): batch work goes
to a scheduler the deployment runs. This page says exactly what a site's
`deploy/local/queue-templates.yaml` asks of the queue, so that any scheduler
(Nomad, k3s Jobs and CronJobs, or launchd and `docker run`) can be checked
against it. It describes the scheduler only in general terms: resources,
time windows, and waiting on another service's health.

Until a replacement works end to end, the queue runs where the placement
map puts `queue` (with its Docker proxy, `queue-docker-proxy`), and its host
runner where it puts `queue-host-runner`, off unless the inventory's
`deployment.native.queue-host-runner.enable` is set (`roles/darwin.nix`).
The queue keeps its history in its own volume (`jobs.jsonl`), so check that
before moving: a site whose queue has run nothing loses nothing.

The examples use the example site's `desk`, the Mac that runs the services.

## What every job shares

| | Today (the queue) | A replacement must |
|---|---|---|
| **Unit** | A one-off container (docker runner), or a command on the Mac (host runner) | Run OCI containers on the services' host's Docker engine (Colima), and, for host templates, a command on macOS itself |
| **Parameters** | Each template's parameters, each checked against a regex and placed only in `{slots}` in `command` / `args`, never through a shell | The same patterns, checked before the work runs. Values go into argv, never into a shell string |
| **Start conditions** (any job) | `notBefore` (a time); `after` (other jobs that succeeded); `when`: `anytime`, `after-close` or `background-may-run` | All three, per job: a start time, a dependency, and the two waits below |
| **after-close** | Reads `QUEUE_CALENDAR` (the accounts service's `GET /calendar`: `{"days": [{date, open, close}]}`, New York times), at most hourly. Today's `close` has passed, or today isn't in the list (a holiday). Outside the list's range: weekends, or weekdays after 16:00 New York | The same rule, against `${TT_URL_ACCOUNTS}/calendar` from the Compose network |
| **background-may-run** | Waits while any `QUEUE_YIELD_TO` service's `GET /health` gives a `state` other than `idle`. A service that doesn't answer within 3 s counts as not capturing | Waits on the relays the site names (their `observe` URLs, `TT_URL_RELAY_<NAME>_OBSERVE`), from the Compose network. Configurable as a list of `NAME=URL` |
| **Concurrency** | `QUEUE_MAX_RUNNING` docker jobs at once (for example 2), first come first served. Host jobs: one at a time (one runner) | A small cap on research containers at once. Host builds one at a time |
| **CPU priority** | `class: background`: Docker `CpuShares` 128 (512 otherwise). Host: `taskpolicy -b` | A low CPU share for containers, and macOS background QoS (`taskpolicy -b`) for host commands |
| **Deadline** | `activeDeadlineSeconds`: stopped and marked Failed when exceeded. A waiting job's clock starts when it starts | A runtime limit per job |
| **Retries** | `backoffLimit: 0` only: never retried | No automatic retries |
| **Network** | Docker jobs join the Compose project's default network (`QUEUE_NETWORK`, `<deployment.name>_default`), so `console:8080` and `accounts:<port>` resolve | Containers on that network, or the same addresses reached another way (see below) |
| **Secrets** | None. The Databento key and the purchase approval token are databento-jobs' alone ([decision 0013](decisions/0013-databento-key-held-by-its-services.md)). A collector that calls Databento directly stops with "purchases go through databento-jobs" | No secret at all. In particular, never `DATABENTO_API_KEY` or `JOBS_APPROVE_TOKEN`, and no Docker socket |
| **Logs and history** | Each job's output is kept in the queue volume (`logs/`). An append-only `jobs.jsonl` journal records every state change, so a restart never runs a job twice. List, log, cancel, edit while waiting, run now: through `/jobs`, the console's Queue widget, and `tt queue` | Each run's output and exit status kept after the job ends, a list of past runs, cancel, and "run now" (skip the waits). A UI the operator reaches from any of their devices (over the tailnet), and a CLI agents can use |
| **Who may submit** | Anyone who reaches the queue's loopback port or the console's write gate, and only from the templates | Only the job definitions in the site. Who may submit is the scheduler's to decide (the tailnet is trusted) |

Addresses come from `deploy/local/endpoints.nix` ([decision 0008](decisions/0008-addresses-from-the-placement-map.md));
`scripts/placement endpoints` prints a host's. From a container on the
services' host they look like:

| Variable | From a container on `desk` |
|---|---|
| `TT_URL_CONSOLE` | `http://console:8080` (the jobs' `TT_CONSOLE`) |
| `TT_URL_ACCOUNTS` | `http://accounts:<port>` (the calendar is `/calendar`) |
| `TT_URL_RELAY_<NAME>_OBSERVE` | `http://host.docker.internal:<port>` (a native relay) |

`TINYTRADER_SITE` is the site's deploy checkout, `<deployRoot>/<site>`
([decision 0012](decisions/0012-deploy-checkouts.md)), with
`<deployRoot>/tinytrader` beside it. Jobs never run from a working copy.

## The template kinds

A site's templates are its own; these are the kinds the queue supports, and
what each asks of a scheduler.

### A research collector (docker)

| | |
|---|---|
| Image | The site's research image (built from this stack's `deploy/local/research` by the site's compose.yaml; runs as an unprivileged `research` user, its venv first on PATH) |
| Parameter | `script`: `^collect_[a-z0-9_]+\.py$` (a collector in the site's `research/`) |
| Command | `python {script}`, working directory `/work` |
| Mount | `${TINYTRADER_SITE}/research` → `/work`, read-write (collectors write their outputs there) |
| Environment | `TT_CONSOLE=${TT_URL_CONSOLE}` |
| Limits | CPU 1, memory 1 GiB |
| Deadline | 14400 s (4 h) |
| Class | background |

### A research notebook (docker)

| | |
|---|---|
| Image | The site's research image |
| Parameter | `notebook`: `^[a-z0-9-]+\.ipynb$` |
| Command | `jupyter nbconvert --to notebook --execute --inplace {notebook}`, in `/work` |
| Mount | `${TINYTRADER_SITE}/research` → `/work`, read-write (outputs are saved in place) |
| Environment | `TT_CONSOLE=${TT_URL_CONSOLE}` |
| Limits | CPU 1, memory 2 GiB |
| Deadline | 7200 s (2 h) |
| Class | background |

### A tinytrader build (host)

| | |
|---|---|
| Runs on | The Mac itself (macOS, aarch64), as the primary user, not in a container |
| Parameter | `package`: `^[a-z][a-z0-9-]*$` (a Cargo workspace package) |
| Command | `cargo build -j 2 --release -p {package}`, under `taskpolicy -b` |
| Working directory | `${TINYTRADER_SITE}/../tinytrader` (the deploy checkout of tinytrader) |
| Needs | `cargo` on PATH (`~/.nix-profile/bin`), `HOME` (the shared cargo target, `~/.cargo/config.toml`) |
| Deadline | 5400 s |
| Class | background. No builds 09:25-16:20 New York time on trading days, so queue it `after-close` or `background-may-run` |

### A tinytrader test (host)

The same as the build, but the command is `cargo test -j 2 -p {package}`.

## Not carried over

- The console's Queue widget and `/api/queue` proxy (removed in tinytrader).
  The scheduler's own UI replaces them, linked from the console's Services
  widget through the topology's `links`.
- `tt queue` (removed). Agents use the scheduler's CLI, or a small wrapper
  in `scripts/`.
- The queue's own Docker proxy, `queue-docker-proxy`. A replacement that
  starts containers needs Docker write access of its own (Nomad's docker
  driver uses the socket directly), or its own runtime (k3s's containerd).

## Choosing the scheduler: notes from trying Nomad

Most of these hold for k3s too.

- **Colima shares only `$HOME` with its VM** (`--mount ~:w`, set by the
  machine's configuration). A bind mount from anywhere else, such as
  `/var/lib/<scheduler>`, comes up empty inside a container. Nomad's
  per-allocation directories (`client.alloc_dir`) must be under `$HOME`, even
  with `data_dir` in /var/lib. k3s hostPath volumes are VM paths: `$HOME`
  appears at the same path, so `<deployRoot>/<site>/research` works as is.
- **Containers reach host loopback** through `host.docker.internal`. A
  scheduler API on 127.0.0.1 is therefore reachable from every container,
  including research's JupyterLab. With ACLs off, Nomad's API plus
  `raw_exec` lets any container run commands on the Mac as the primary user.
  Mitigations: turn ACLs on, or drop `raw_exec` and leave host builds out.
  k3s's API needs a client certificate, so it doesn't have this problem.
- **Host jobs**: Nomad runs them natively (`raw_exec` on macOS). k3s can't:
  it runs only in the Linux VM. The cargo templates would need a host runner
  of their own (a launchd agent, or a self-hosted CI job), or would be
  dropped.
- **The Compose network**: Nomad's docker driver joins
  `<deployment.name>_default` by name (`network_mode`), so `console:8080`
  resolves, as it does for the queue's jobs. k3s pods (Colima's built-in
  k3s, `colima start --kubernetes`) aren't on Compose's network. They'd reach
  the console and accounts through `host.docker.internal` on their published
  loopback ports instead of by name.
- **Concurrency**: neither has `MAX_RUNNING`. Nomad places by node
  resources: set `client.memory_total_mb` / `cpu_total_compute` to a budget
  (for example, 3 GiB holds one notebook and one collector). In k3s, a
  ResourceQuota on the jobs' namespace (`limits.memory: 3Gi`), or Kueue.
  Under either, a job that is waiting in a pre-start check already holds its
  reservation. Many after-close jobs queued during the day can delay an
  `anytime` one until the close, which the queue never did.
- **The waits are the same container either way**: a prestart task (Nomad)
  or an init container (k3s), with `curl` and `sh`, configured by
  environment: `GATE_NOT_BEFORE` (Unix seconds), `GATE_AFTER_CLOSE_CALENDAR`
  (the calendar URL), `GATE_YIELD_TO` (`name=url;...`). Dependencies:
  ordered tasks in one job (Nomad lifecycle, or k3s init containers in
  sequence), or a wait on the other job's status through the scheduler's API.
- **Schedules**: both take cron with a time zone (Nomad
  `periodic { crons, time_zone = "America/New_York" }`; Kubernetes CronJob
  `timeZone: America/New_York`). The queue had no repeating jobs.
- **Parameters**: Nomad `parameterized { meta_required = [...] }` and
  `nomad job dispatch -meta script=…`. Kubernetes has no equivalent: a
  wrapper fills a Job from a template (`kubectl create job --from=cronjob/…`
  takes no parameters).
- **Packaging**: Nomad is BSL-licensed, so nixpkgs marks it unfree. It needs
  an `allowUnfreePredicate`, and there is no binary cache: it builds from
  source (Go, a few minutes). k3s is free and in nixpkgs (NixOS
  `services.k3s`); on the Mac it comes with Colima.
- **Linux hosts later**: Nomad clients join a server over the tailnet (one
  binary, systemd on NixOS). k3s agents join with a token (NixOS
  `services.k3s.role = "agent"`). Either is a few lines in `modules/nas.nix`.

## Nomad ([decision 0014](decisions/0014-nomad-batch-scheduler.md))

The queue stays until each job has run end to end; then tinytrader #47
removes it.

| | |
|---|---|
| Agents | `modules/nomad.nix` (options), `nomad-darwin.nix` (launchd, as the primary user), `nomad-nixos.nix` (`services.nomad`), on each host the inventory places `nomad` on (`perHost`, with its `http` and `rpc` ports). `roles/darwin.nix` and `modules/nas.nix` add them |
| Policy | The site's `deployment.nomad`: the `server`, each node's `pool`, budget (`memoryMB`, `cpuMHz`), `feed` (background work there yields to `yieldTo`) and `builds`. `deploy/nomad/node.nix` turns it into each host's agent settings and node metadata. A Mac without deploy checkouts names the site checkout research mounts with `deployment.hosts.<host>.siteCheckout` |
| Jobs | The site's `deploy/nomad/jobs/*.nomad.hcl` (the example's are the four templates above, as parameterized batch jobs). Each starts with the gate (`deploy/nomad/gate.sh`, read from this stack at registration): parameters checked against their patterns, then `not_before`, then `when` |
| Use | `scripts/job run research-collector script=collect_x.py`, `list`, `logs`, `cancel`, `pool off <node>` / `pool on <node>`, `ui` |
| Access | The UI and API at `http://<server's tailnet name>:4646` from any device on the tailnet (read-only without a token); changes through `scripts/job`, with the site's `secrets/nomad.env` |
| Registration | `scripts/job register`; auto-deploy runs it when the site's `deploy/nomad/` or this stack's `gate.sh` or `acl/` change |

Setting it up, once:

1. Allow the unfree `nomad` package by name on each machine
   (`nixpkgs.config.allowUnfreePredicate`), and switch them, outside the
   capture hours (a switch restarts native services).
2. `scripts/tailnet-serve --apply` on each host (its Nomad ports).
3. On the server's host: `scripts/nomad-bootstrap` (ACLs: the token into
   the site's secrets/nomad.env, the anonymous policy, the jobs), then
   commit secrets/nomad.env in the site.
4. Run each job once (`scripts/job run …`).

Differences from the queue: preempted work isn't rescheduled; no `after`
dependencies; CPU is Docker shares (128) rather than a 1-CPU limit.

## Earlier target design (k3s, proposed; superseded by decision 0014)

Kept for the controller it describes, which Nomad still needs (throttling in
place by calendar window).

- **Substrate:** one k3s cluster over every machine. Macs join through their
  Colima VMs; Linux hosts (a NAS, a VPS) join natively; rented cloud
  machines join over Tailscale for bursts. Work is plain containers.
  Meaning lives in labels (`class=research`, `long-running`), never in code.
- **Generic mechanism (tinytrader):** a small controller that reads time
  windows from a calendar feed (data: open, close and holiday times, no
  cron with holiday checks in job specs). Per window and node it:
  - throttles labelled pods' CPU in place (Kubernetes in-place pod
    resize), with no eviction or restart; the pod keeps its memory, so
    research pods on feed hosts carry a memory ceiling;
  - blocks new pods of a class on chosen nodes (taints);
  - sets compute quotas per class (ResourceQuota).

  PriorityClasses order the work: feed and gateways, then services, then
  research. Nothing in the controller is trading-specific; "market hours"
  is just a window named in config.
- **Policy (the site):** the calendar URL, which nodes host the feed, the
  windows, class priorities, quotas (CPU, memory, GPU; compute only), and
  the node pool. Each node is switchable by one config entry or command
  (for example a Mac you carry, when travelling), optionally automatically
  (on battery → leave the pool).
- **Note:** the feed runs outside the cluster, as native services under a
  system user of their own, so the scheduler can't see its usage. Feed
  protection is therefore windows plus taints and throttling on feed hosts,
  not contention detection.
