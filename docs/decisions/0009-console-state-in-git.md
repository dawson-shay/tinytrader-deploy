# 0009: The console's reminders and curated views live in git

- **Status:** Accepted
- **Date:** 2026-10-16
- **Builds on:** [0005](0005-placement-map.md) (the placement map; the
  console runs on the host the map places it on)

## Context

The console keeps its reminders (the roadmap) and every synced setting in one
Docker volume, `console-data`. Moving to a new machine means copying the
volume by hand, the roadmap's history is nowhere, and good layouts can't be
reviewed or restored.

## Decision

- **Reminders:** the site's `state/console/reminders.json` is the source of
  truth. The site checkout's `state/console` is mounted into the console
  (`${TINYTRADER_SITE}/state/console`, writable), which writes edits back to
  the file; they are committed like any change. The console follows the file
  on disk (a `git pull` is picked up), and never overwrites a file it can't
  read.
- **Views:** curated views are config, in the site's
  `state/console/layouts.json`, which the console uses as defaults
  (`CONSOLE_PREFS_DEFAULTS`). Promoting is deliberate
  (`scripts/console-promote`, then review and commit): the views, their
  folders, the Cross-asset board, the watchlists, the theme and the palette.
  Everyday changes stay runtime state in the volume (`CONSOLE_PREFS`,
  `CONSOLE_PROFILES` under `/data`), backed up by `scripts/backup-state` but
  not committed, so the history isn't churn.
- **The journal** (`state/console/journal.json`, the console's trading
  journal, `CONSOLE_JOURNAL`, which defaults to beside the reminders) is
  kept like the reminders (added with [0012](0012-deploy-checkouts.md)):
  written by the console, the only copy is this file, it is notes of the
  operator's own, a few a day, and its history is worth having. The site is
  private, so this is its place.
- **Committed by auto-deploy** since [0012](0012-deploy-checkouts.md): the
  console runs from the site's deploy checkout, and auto-deploy commits and
  pushes changes to these three files as the operator ("Console state: ...").
- **One place:** no second state folder for these. The volume keeps only
  runtime settings and profile recordings.
- **No secrets** in either file; the promote script refuses values that look
  like credentials.

## Consequences

The console's container writes into the site checkout, so uncommitted
reminder edits sit in its working tree until auto-deploy commits them (0012:
the deploy checkout, not a working copy). `scripts/backup-state` copies the
site with its uncommitted and untracked files, so they are in every
snapshot, and `checks/backup.nix` accepts the bind because it is under
`$TINYTRADER_SITE`. A NAS's console (`modules/nas.nix`) reads the curated
views from the site's flake but can't write back to it: its reminders stay
in its own state until it has a checkout of its own.
