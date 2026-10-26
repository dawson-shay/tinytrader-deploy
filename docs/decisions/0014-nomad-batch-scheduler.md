# 0014: Nomad runs batch work, on every machine in the pool

- **Status:** Accepted
- **Date:** 2026-10-25
- **Replaces, once it has run a job end to end:** tinytrader's job queue
  (tinytrader decision 0012; its removal is tinytrader PR #47)

## Context

The queue runs one-off containers and Mac commands on one host. What's
wanted is a scheduler for all of a deployment's compute (its Macs, a NAS,
a laptop when idle, rented machines for bursts): work as containers,
priorities, preemption, budgets per node, and a node taken out of the pool
with one command (a laptop on battery). Research jobs also need the Mac
itself: Apple Silicon's GPU, and native processes beside the store.

k3s was tried first (in-place resize, PriorityClasses, preemption and
ResourceQuota all worked). But on a Mac it runs only inside a Linux VM: no
Metal GPU, no native process. Swarm has no priorities, preemption or quotas.

## Decision

Nomad, open source:

- **Agents** on each host the inventory places `nomad` on (perHost), from
  one module (`modules/nomad.nix`; launchd on a Mac, `services.nomad` on
  NixOS). The server is the site's `deployment.nomad.server`. Each listens
  on loopback; `tailscale serve` forwards its ports (the inventory's `nomad`
  ports), so the UI and the CLI work from any device on the tailnet.
- **Containers** through the docker driver (the Mac's engine, Colima's by
  default); **Mac processes** through raw_exec, as the primary user.
- **Preemption** on for every scheduler (open source since 0.12, off by
  default). Priorities are the jobs' own (the example: builds 40, research 30).
- **Budgets** per node (`memoryMB`, `cpuMHz` in `deployment.nomad.nodes`):
  what jobs may reserve there, not the machine's size. Nomad's quotas are
  Enterprise; node budgets and pools do the job.
- **Start conditions** in a generic gate (`deploy/nomad/gate.sh`), each job's
  prestart task: a start time, after the close by a calendar passed as data,
  and waiting while named health URLs report capture. Nothing in it is
  trading-specific; the calendar and URLs come from node metadata
  (`deploy/nomad/node.nix`).
- **ACLs on**: containers reach the host's loopback, and raw_exec runs
  commands there, so an open API would let a container run anything on the
  Mac. Anonymous requests read (the UI, logs; `deploy/nomad/acl/anonymous.hcl`,
  or the site's own); changes take the management token in the site's
  `secrets/nomad.env`, which `scripts/nomad-bootstrap` stores and
  `scripts/job` uses.
- **Split as everywhere else** (decision 0015): the mechanism (the modules,
  node.nix, the gate, `scripts/job`) is this stack's; the policy (the
  server, each node's pool, budget, feed and build roles) is the site's
  inventory, and the job specs are the site's `deploy/nomad/jobs/`
  (the example's are a template).

## Consequences

- Nomad is BSL-licensed: nixpkgs marks it unfree. Machines allow it by name
  (`nixpkgs.config.allowUnfreePredicate`), and it builds from source (no
  binary cache).
- No live resize of a running job: preemption stops the lower-priority work
  (it isn't rescheduled: jobs are never retried). Throttling in place
  (`docker update`, `taskpolicy`, `renice`) by calendar window is a
  controller's job, still to build.
- No job dependencies (`after`) yet: the queue had them, no job used them.
- The queue stays until Nomad has run each job end to end; then tinytrader
  #47 removes it.
