# The console's state kept in git

Three files the console reads from this folder (the site's
`deploy/local/compose.yaml` mounts it at `/srv/state/console`, writable), all
three committed (tinytrader-deploy docs/decisions/0009):

| File | What it is | Written by |
|---|---|---|
| `reminders.json` | The roadmap as reminders (`CONSOLE_REMINDERS`). This file is the source of truth. | The console, on every edit. |
| `journal.json` | The trading journal (`CONSOLE_JOURNAL`, beside the reminders by default). This file is the only copy. | The console, on every edit. |
| `layouts.json` | Curated views: the defaults for any setting the console hasn't saved itself (`CONSOLE_PREFS_DEFAULTS`). | You, with tinytrader-deploy's `scripts/console-promote`. |

On a services host with deploy checkouts, the console mounts the deploy
checkout's folder, and scripts/auto-deploy commits what changed in these
files there and pushes it to main. Nothing in them may be a secret, a token
or an account identifier.
