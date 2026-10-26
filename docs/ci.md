# CI: GitHub's runners, the pre-push hook, and a site's own runner

The same checks run in two places for this stack:

- **On every push and pull request**, on GitHub-hosted runners:
  `.github/workflows/ci.yml`, on `ubuntu-latest` and `macos-latest`, with Nix
  installed by an action.
- **Before every push**, on the machine you push from: `scripts/hooks/pre-push`.

The checks: `nix flake check` (the example site's placement map and
addresses, the role modules evaluate on a minimal machine, the backup and
data-root checks, and `checks/generic.nix`, which fails on anything that
looks deployment-specific), and `scripts/ci-lint` (every script under
`scripts/` parses, and every tracked compose file parses). None of them needs
a secret.

A site runs the same checks on its own repository: its pre-push hook runs
this stack's, and it can run CI on a self-hosted runner of its own
([below](#a-sites-own-runner)).

## The pre-push hook

Once per clone:

```sh
scripts/install-hooks   # git config core.hooksPath scripts/hooks
```

(A machines repository can set `core.hooksPath = scripts/hooks` for your
clones instead, for example in Home Manager's Git settings. The relative path
resolves from the root of the worktree the hook runs in, so each worktree
runs its own copy.)

Then `git push` runs the checks on each commit being pushed, in a temporary
worktree (so uncommitted changes don't count), and refuses the push if one
fails. To push anyway, once: `git push --no-verify`.

### In a site

A site's `scripts/hooks/pre-push` runs this stack's hook, found through
`TINYTRADER_DEPLOY` or as the `tinytrader-deploy` checkout beside the site:

```sh
#!/usr/bin/env bash
# the site's scripts/hooks/pre-push
stack="${TINYTRADER_DEPLOY:-$(cd "$(dirname "$0")/../../.." && pwd)/tinytrader-deploy}"
exec "$stack/scripts/hooks/pre-push" "$@"
```

The stack's hook runs `nix flake check` in the site's pushed commit and
`scripts/ci-lint DIR`, which lints the site (its `scripts/` and compose
files) with the stack's tools. Install it the same way (`git config
core.hooksPath scripts/hooks` in the site).

auto-deploy's console-state commits and pushes skip the hook
(`--no-verify`): they touch only `state/console`, and CI still runs on them.

## A site's own runner

A site's repository is private, and its CI may not have hosted minutes. The
stack can run a GitHub Actions self-hosted runner on one of the site's Macs:
`modules/runner-darwin.nix`, imported by `roles/darwin.nix` where the
placement map places the `runner` service, with nix-darwin's
`services.github-runners` and nixpkgs' `github-runner`.

**Never register it to a public repository.** On a public repository anyone
can open a pull request, and a self-hosted runner would run that pull
request's workflow on your Mac, with your network, your tailnet and whatever
the runner user can reach. This stack's own CI therefore uses GitHub's
runners only; the self-hosted runner is for the site's private repository.

### Configure it

In the site's `inventory.nix`:

```nix
services.runner.perHost.desk = "launchd";   # a host agent: on the Macs listed
deployment.native.runner = {
  url = "https://github.com/<owner>/<site-repo>";  # required: the private repository it serves
  name = "desk";    # its name on GitHub and its extra label (default: the host)
  attr = "my-site"; # its services.github-runners name (default: deployment.name)
};
```

What the module sets up:

- the labels `self-hosted`, `macOS`, `ARM64` and its name; the site's
  workflow asks for them (`runs-on: [self-hosted, macOS, ARM64, desk]`);
- it runs as `_github-runner` (uid 533), a hidden, unprivileged user
  nix-darwin creates: not an admin, no sudo, and no access to the operator
  age key, so the workflow can't decrypt `secrets/` and must not need to;
- one job at a time; after each job its work directory is emptied (a
  job-completed hook), and again whenever the service starts;
- Nix is the host's (it works with Determinate Nix, where the machine sets
  `nix.enable = false`): builds go through the Nix daemon into the shared
  store, and Nix's own caches (`XDG_CACHE_HOME`) and `CARGO_HOME` live under
  the work directory, emptied when they pass 2 GiB.

The service stays off until the site's `secrets/runner.env` exists.
nix-darwin's module expects `nix.enable`; the runner module uses it with that
check and the Nix on its `PATH` changed (see the comment there).

### Disk

With the runner named `<name>`:

| Path | Holds | Size |
|---|---|---|
| `/private/var/lib/github-runners/_work/<name>` | One job's checkout, the runner's `_actions` and `_temp`, and the caches | A few MB during a job; the caches stay under 2 GiB |
| `/var/lib/github-runners/<name>` | The registration, and the runner's `_diag` logs (pruned after 7 days) | A few MB |
| `/var/log/github-runners/<name>` | The service's stdout and stderr | A line or two per job |
| `/nix/store` | `github-runner` (a few hundred MB) and whatever the checks build | Builds are not GC roots: `nix store gc` reclaims them |

### Register it (once)

The runner needs a token to register. After registering it authenticates with
its own credentials, and the token file on the Mac is deleted; the token is
needed again only to re-register.

1. **Make a fine-grained personal access token.** On GitHub: your avatar →
   **Settings** → **Developer settings** → **Personal access tokens** →
   **Fine-grained tokens** → **Generate new token**.
   - **Token name:** for example `<site> runner (<name>)`.
   - **Resource owner:** the account or organisation that owns the site's
     repository.
   - **Expiration:** short is fine, such as 30 days: it is used only to
     register (and re-register).
   - **Repository access:** **Only select repositories** → the site's
     repository. Nothing public.
   - **Permissions** → **Repository permissions** → **Administration:
     Read and write**. (**Metadata: Read-only** is added with it.) Creating a
     runner registration token
     (`POST /repos/{owner}/{repo}/actions/runners/registration-token`), which
     the runner does with the PAT, needs exactly this. Nothing else.
   - **Generate token** and copy it (`github_pat_…`).

2. **Encrypt it into the site's `secrets/runner.env`**, in your own terminal
   in the site's checkout (read without echoing, never written in plain
   text):

   ```sh
   read -rs TOKEN && printf 'GITHUB_RUNNER_TOKEN=%s\n' "$TOKEN" \
     | sops encrypt --input-type dotenv --output-type dotenv \
         --filename-override secrets/runner.env /dev/stdin > secrets/runner.env
   unset TOKEN
   git add secrets/runner.env && git commit -m "The CI runner's registration token" && git push
   ```

   Only files Git tracks are in the flake's source, so it must be committed.

3. **Apply the role on the Mac:** in your machines repository, take the new
   revision of the site and switch (or `scripts/darwin-switch`, if the site
   configures that Mac itself):

   ```sh
   nix flake update <site>
   darwin-rebuild switch --flake .   # or your machines repository's own switch
   ```

   Activation decrypts the token with the operator key into a file only
   `_github-runner` can read, and starts the runner, which registers and
   deletes the file.

4. **Check it's online:**

   ```sh
   gh api repos/<owner>/<site-repo>/actions/runners \
     --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
   ```

   Its name, `"status": "online"`, with the four labels. Then push a branch,
   or run the workflow by hand (`gh workflow run ci --ref <branch>`), and
   watch it with `gh run list` / `gh run watch`.

If it isn't online: `sudo launchctl print system/org.nixos.github-runner-<attr>`
and `sudo tail -n 50 /var/log/github-runners/<name>/launchd-std{out,err}.log`.

**A registration token instead of a PAT.** The file may hold a runner
registration token instead:
`gh api -X POST repos/<owner>/<site-repo>/actions/runners/registration-token --jq .token`,
encrypted the same way. It needs no PAT at all (it is made with your `gh`
login) and is useless after an hour, so no standing credential with admin
rights exists anywhere. But it must be used within that hour: commit, update
the machines repository's lock and switch promptly, and make a new one each
time the runner re-registers. The PAT is the easier one to re-register with;
revoke it on GitHub whenever you like, and the runner keeps working.

### Re-register

Changing the runner's name, labels or repository, or GitHub removing it
(after 14 days offline), needs a new registration:

```sh
sudo rm /var/lib/github-runners/<name>/.runner   # forget the old registration
# a token that's still valid in secrets/runner.env (step 2 again if not), then switch again
```

### Private flake inputs

The site's workflow fetches public inputs (tinytrader, tinytrader-deploy)
anonymously. If an input is private, the runner's Nix needs read access to
it: a fine-grained PAT with read-only **Contents** on that repository, given
to Nix as `access-tokens = github.com=<token>` in the runner user's
`nix.conf`.
