# AGENTS.md

Follow [CONTRIBUTING.md](CONTRIBUTING.md): this repository is public and
generic; nothing about a real deployment goes in it. Operating a deployment
(deploys, incidents, agent hygiene) is [docs/operations.md](docs/operations.md);
a site's structure is [docs/site.md](docs/site.md).

- Work in a worktree on a branch, never in a deploy checkout.
- No builds or heavy batch work 09:25-16:20 New York time on trading days.
- Never decrypt a site's secrets or print their values.
