# Working in tinytrader-deploy

This is the **generic** deployment stack for tinytrader. It is public.

- **Nothing deployment-specific, ever.** No host names, user names, home
  paths, drive names, addresses, tailnet names, account identifiers,
  strategy or client names, keys or secrets. Those belong in a site
  ([docs/site.md](docs/site.md)). Examples use the made-up site in
  `example/` (hosts `desk`, `vault`, `nas`). `checks.generic`
  ([checks/generic.nix](checks/generic.nix)) fails on the obvious patterns;
  it is a backstop, not a replacement for care.
- **Platform work goes to tinytrader.** Services, the console, libraries and
  formats belong there; this repository says how a deployment runs them.
- **Anything a site might want different is the inventory's**, not a
  constant here: add a field (under `deployment` if it is a role's setting),
  document it in docs/site.md and the example inventory, and give it a
  default that works for the example.
- **Keep the example working.** `nix flake check` evaluates every role and
  check against `example/`; a change that a real site needs should show up
  there too.
- **Records of why the stack is shaped the way it is** go in
  `docs/decisions/`.

Before a push: `nix flake check` and `scripts/ci-lint` (the pre-push hook
runs both: `scripts/install-hooks`). CI runs them on GitHub-hosted runners.
