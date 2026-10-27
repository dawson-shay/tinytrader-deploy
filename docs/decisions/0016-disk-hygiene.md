# 0016: The Macs clean up after builds, and warn before the disk is full

- **Status:** Accepted
- **Date:** 2026-10-26
- **Amends:** [0006](0006-host-monitoring.md) (the disk thresholds),
  [0014](0014-nomad-batch-scheduler.md) (a periodic job on every Mac)

## Context

A Mac with a small internal disk fell to about 3 GiB free. Most of what
filled it was Rust `target/` folders, one per agent worktree: five
worktrees of one repository each had a full build of their own. Nix's old
generations and Docker's build cache add to it. The monitor's warning came
at 90% used, which on a small disk is already too late to clean up calmly.

## Decision

- **A shared target per repository, per machine.** Every checkout of a
  repository on a machine (its worktrees included) builds into one
  `CARGO_TARGET_DIR`, `~/.cache/cargo-target/<repo>/target`, set by the
  machine's shell configuration (docs/operations.md, Agent hygiene). Per
  repository rather than one for everything: one repository's builds don't
  wait on another's lock, and a repository no longer built ages out on its
  own.
- **A daily `disk-hygiene` job on every Mac** (the site's
  `deploy/nomad/jobs/disk-hygiene.nomad.hcl`; the example's is the
  template), a periodic `sysbatch` job, so each Mac gets a run. It starts at
  18:30 New York time and its gate waits for the close, so it never runs
  09:25-16:20 on a trading day. Its work is this stack's
  `deploy/nomad/disk-hygiene.sh`, natively, under `taskpolicy -b`:
  - deletes Rust `target/` folders (beside a `Cargo.toml`, or tagged by
    cargo's `CACHEDIR.TAG`) under the node's `cleanRoots`
    (`deployment.nomad.nodes.<host>`), only when nothing in one was
    modified for 7 days and no process has a file open in it (cargo holds
    its build lock for a whole build);
  - `nix-collect-garbage --delete-older-than 14d` (the user's profiles);
  - `docker system prune -f` where an engine answers. Never `--volumes`.

  It never touches `/Volumes`: a root there, or resolving there, is
  refused; it follows no symlinks and enters no other file system. It logs
  each folder deleted with its size, and the bytes freed. `dry_run = "1"`
  in the job (or `--dry-run`) removes nothing and says what it would.
  `checks.disk-hygiene` runs it on disposable folders.
- **Disk warnings earlier** (amending 0006's thresholds): the stack's
  defaults are a warning at 85% used and high priority at 95% or below
  20 GiB free, so a disk is reported below 15% or 20 GiB free, whichever is
  more. A site's `monitoring.disk` still overrides them. The backup's
  free-space floor follows `minFreeGiB`, as before.

## Consequences

- A target untouched for a week is rebuilt from scratch the next time; an
  active one is kept, as is any target a running binary was started from.
- `docker system prune -f` removes stopped containers and unused networks
  as well as dangling images and build cache. Compose recreates its
  containers on the next deploy; the volumes stay.
- Old Nix generations can't be rolled back to after 14 days. The system
  profile is root's and isn't collected by this job.
- The 20 GiB floor is high priority, not a warning: `watch` has one
  free-space floor. On disks under about 130 GiB it is reached before the
  15% warning.
- The 85% warning applies to every disk the monitor watches, data drives
  included.
