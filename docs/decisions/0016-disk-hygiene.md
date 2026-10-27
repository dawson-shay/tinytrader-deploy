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
  `CARGO_TARGET_DIR`, `~/.cache/cargo-target/<repo>/target`, set by this
  stack's `scripts/cargo-shim`, which the machines repository installs as
  `cargo` ahead of the real one, so non-interactive shells get it too. Per
  repository rather than one for everything: one repository's builds don't
  wait on another's lock, and a repository no longer built ages out on its
  own. The global `target-dir` in `~/.cargo/config.toml` goes, with no
  fallback (docs/operations.md, Agent hygiene, has the move). The Nomad
  build and test jobs set the deploy checkout's own target, so a working
  copy's build never overwrites a deploy's binaries.
- **A daily `disk-hygiene` job on every Mac** (the site's
  `deploy/nomad/jobs/disk-hygiene.nomad.hcl`; the example's is the
  template), a periodic `sysbatch` job, so each Mac gets a run. It starts at
  18:30 New York time and its gate waits for the close, so it never runs
  09:25-16:20 on a trading day. Its work is this stack's
  `deploy/nomad/disk-hygiene.sh`, natively, under `taskpolicy -b`:
  - deletes Rust `target/` folders (beside a `Cargo.toml`, or tagged by
    cargo's `CACHEDIR.TAG`, as the per-repository ones are) under the
    node's `cleanRoots` (`deployment.nomad.nodes.<host>`), only when nothing
    in one was modified for 7 days and no process has a file open in it
    (cargo holds its build lock for a whole build; lsof is read once per
    run);
  - `nix-collect-garbage --delete-older-than 14d` (the user's profiles);
  - `docker image prune -f` and `docker builder prune -f --filter
    until=336h` where an engine answers, skipped while auto-deploy's lock
    is open. Containers (a stopped one under a hold, say), networks and
    volumes stay.

  It never touches `/Volumes`: a root there, or resolving there, is
  refused; it follows no symlinks and enters no other file system. It logs
  each folder deleted with its size, and the bytes freed. `dry_run = "1"`
  in the job (or `--dry-run`) removes nothing and says what it would.
  `checks.disk-hygiene` runs it on disposable folders.
- **Disk warnings earlier on system disks** (amending 0006's thresholds):
  `watch` has one set of thresholds per host, so a host that watches only
  `/` gets `monitoring.systemDisk`, by default a warning at 85% used and
  high priority at 95% or below 20 GiB free: reported below 15% or 20 GiB
  free, whichever is more. A host that watches other disks too keeps
  `monitoring.disk` (90%, 95%, 10 GiB in the example), so a full archive
  drive doesn't warn on every run. Thresholds per disk would be a change to
  tinytrader's `watch`.

## Consequences

- A target untouched for a week is deleted and rebuilt from scratch the
  next time. That includes a target whose binaries are only run, never
  rebuilt: after 7 days without a build it goes. The in-use check keeps
  it while a process runs from it, but not between runs.
- Stopped containers, networks and recent build cache are left alone;
  dangling images and build cache older than 14 days go.
- Old Nix generations can't be rolled back to after 14 days. The system
  profile is root's and isn't collected by this job.
- The 20 GiB floor is high priority, not a warning: `watch` has one
  free-space floor. On disks under about 130 GiB it is reached before the
  15% warning.
- A host with a store's drives keeps the old thresholds for its system disk
  too, until `watch` takes thresholds per disk.
- lsof is read once at the start: a build that starts during the run is
  seen only through the 7-day rule.
