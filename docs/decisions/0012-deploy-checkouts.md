# 0012: The services run from deploy checkouts, not working copies

- **Status:** Accepted
- **Date:** 2026-10-20
- **Builds on:** [0009](0009-console-state-in-git.md) (the console's state in
  git), [0011](0011-auto-deploy-from-main.md) (auto-deploy from main)

## Context

A deployment that runs from the operator's own checkouts (the Compose
project, the console's bind mounts: its state, the docs collections; the
queue's templates, strategies run from the site, auto-deploy, the backup,
and `scripts/deploy`'s image builds) makes those checkouts unusable like any
other: a branch switched or a file left half-edited there changes what the
console serves and stops auto-deploy, and the console's edits sit
uncommitted in the operator's working tree.

## Decision

- **Deploy checkouts:** plain clones of `origin/main`, made once by hand
  ([operations](../operations.md#the-deploy-checkouts)):

  | Checkout | What | Option |
  |---|---|---|
  | `<deployRoot>/<site>` | the site, named after the inventory's `deployment.name` | `tinytrader-deploy.checkouts.site` |
  | `<deployRoot>/tinytrader-deploy` | this stack: the scripts the jobs run | `tinytrader-deploy.checkouts.stack` |
  | `<deployRoot>/tinytrader` | the platform the images are built from | `tinytrader-deploy.checkouts.tinytrader` |

  The location is one setting: nix-darwin's `tinytrader-deploy.deployRoot`
  (`modules/deploy-root-darwin.nix`; default
  `~/.local/share/tinytrader/deploy` of the primary user), which sets
  `TINYTRADER_DEPLOY_ROOT` for the launchd jobs (and the shells nix-darwin
  manages); the scripts default to the same path
  (`scripts/lib/deploy-root.sh`), so a deploy by hand finds it too.
- **Everything live uses them:** the Compose project directory and
  `TINYTRADER_SITE` / `TINYTRADER_DEPLOY` / `TINYTRADER_SRC` (so every bind
  mount: `state/console`, the docs, research, the queue's templates, a
  strategy's folder), the auto-deploy agent, the nightly backup's
  repositories, and the queue's host templates. The monitor and the CI
  runner never use a checkout.
- **Only auto-deploy changes them**: fetch and fast-forward (0011), and the
  console's state. Before the fast-forward it commits the site's
  `state/console` `reminders.json`, `layouts.json` and `journal.json` when
  they changed, as the operator (their git `user.name` and `user.email`),
  "Console state: <what changed>", and pushes to the site's main, rebased
  onto main when main has moved (with `git merge-tree`, so the checkout's
  files are never left half-merged). Never forced. A conflict stops the run,
  notified, with the edits kept committed in the deploy checkout until they
  are merged by hand. A commit there that isn't the console's is never
  pushed.
- **scripts/deploy, local-up.sh and auto-deploy always act on the deploy
  checkouts** where they exist. Run by hand from a working copy or a
  worktree, they say so and run the deploy checkout's copy of themselves with
  the same arguments: what gets deployed is what is merged to main (and
  fast-forwarded), never the branch or the uncommitted changes in the
  checkout they were typed in. A `TINYTRADER_SRC` or `TINYTRADER_SITE`
  naming another checkout is refused. Chosen over refusing outright because
  a deploy by hand from a working copy keeps working, and the message says
  where it ran from. A machine without deploy checkouts runs from the
  checkout the script is in, on the site `scripts/lib/site.sh` finds.
- **The working copies are ordinary:** the operator's checkouts of
  tinytrader, this stack and the site can be on any branch, dirty or
  behind; nothing live reads them. The console's state reaches them with
  `git pull`.

## Consequences

- To deploy a change, merge it: there is no deploying a branch by hand on a
  host with deploy checkouts (the gateways included). `scripts/deploy` by
  hand deploys the deploy checkouts' commits, which are main as of the last
  auto-deploy run (it fetches nothing itself).
- The console's state is committed by a machine, as the operator, every
  run that finds a change (outside market hours, when auto-deploy runs), so
  the site's main gets small "Console state:" commits, and each push runs
  the site's CI. The journal is in git (0009).
- A container keeps the bind mounts it was created with: the paths move only
  when it is recreated. A service that is never auto-deployed keeps reading
  from the checkout it was started from until it is next deployed by hand;
  until then that folder must stay as main has it.
- The nightly backup copies the deploy checkouts, not the working copies:
  unpushed work there is not in the snapshots.
