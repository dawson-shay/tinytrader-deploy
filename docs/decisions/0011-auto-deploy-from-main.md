# 0011: Deploy merged code from main automatically (step 1)

- **Status:** Accepted
- **Date:** 2026-10-19
- **Builds on:** [0005](0005-placement-map.md) (the placement map: what runs
  on the services' host)

## Context

Without automation, after a PR merges someone pulls the checkouts on the
services' host and runs `scripts/deploy` for whatever changed, after hours.
That is easy to forget, and it means working out by hand which services a
change reaches (a change to tinytrader's `libs/observe` reaches nearly all
of them).

## Decision

**A scheduled job on the services' host deploys what is merged to main:**
`scripts/auto-deploy`, a launchd agent every 5 minutes
(`modules/auto-deploy-darwin.nix`, from `roles/darwin.nix`, off until the
machine's configuration sets `tinytrader-deploy.autoDeploy.enable = true`).

- **Fast-forward only.** It fetches `origin/main` for the services'
  checkouts of tinytrader, this stack and the site (the deploy checkouts,
  [0012](0012-deploy-checkouts.md)) and fast-forwards a checkout only when
  it is on `main` with no tracked changes. The console's own writes under
  the site's `state/console` ([0009](0009-console-state-in-git.md)) don't
  count: they are committed and pushed first (0012), so an incoming commit
  touching one of those files is merged with them. A checkout that is dirty,
  on another branch, ahead or diverged is skipped and notified, never
  forced.
- **Only what changed**, from the paths the new commits touch: a tinytrader
  service directory is that image; a library is every image whose crate
  depends on it (from the Cargo.toml files); `Cargo.lock`, the workspace and
  the Nix image build are every image; the site's compose.yaml is compared
  service by service; the inventory, the addresses and the secrets are every
  container. Anything it doesn't recognise means every eligible service:
  slower, never wrong. Docs, research and the console's state are
  bind-mounted, so they need no deploy.
- **Never what the site excludes**: the inventory's
  `deployment.autoDeploy.never` (patterns of service names; by default the
  order gateways and the relays), typically real-money and live-feed
  services and strategies trading on them. Changes reaching them, or the
  native services and the tailnet forwarding, are notified as needing a
  manual deploy.
- **Market hours as `scripts/deploy` has them** (09:25-16:20 New York time
  on weekdays, holidays included), with no start after 09:00 so a build is
  done before the open. Never `--force`.
- **Visible and stoppable:** one run at a time (a lock), a log
  (`~/Library/Logs/tinytrader/auto-deploy.log`), the deployed commits and
  services in `~/.local/state/<deployment>/auto-deploy.json`, ntfy notices
  (the site's notify.env) on success, failure and manual items, and a kill
  switch (`~/.config/tinytrader/auto-deploy.off`). A failed deploy isn't
  retried until new commits arrive or someone runs it by hand.

It is an agent rather than a daemon because fetching a private site uses
the operator's credentials (gh's token in the login keychain, say); it runs
only while the operator is logged in to the services' host.

## Consequences

- Merging to main is deploying, after hours: review is the gate. Changes to
  real-money or live-feed services still need a person.
- Images are still built on the services' host from the checkout, which
  takes CPU and time (why the window ends at 09:00).
- **Step 2 (future):** CI builds the images and pushes them to a registry
  tagged by commit SHA; the job pulls `<image>:<sha>` instead of building,
  so a deploy is a pull and a restart, and what runs is exactly what CI
  tested.
