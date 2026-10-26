# Secrets

Files here are encrypted with [sops](https://github.com/getsops/sops) for the
age keys `../.sops.yaml` lists, which tinytrader-deploy's
`scripts/secrets-recipients` writes from `inventory.nix` `secrets`
(docs/decisions/0004). Never commit a plaintext secret: the site's
`checks.secrets-encrypted` fails on one. Only the `*.example` files (shapes,
placeholders only) and this README are plain.

| File | Holds | Read by |
|---|---|---|
| `accounts/<name>.env` | One Alpaca account's `APCA_API_KEY_ID`, `APCA_API_SECRET_KEY`. Each becomes `ACCOUNT_<NAME>_KEY_ID` and `ACCOUNT_<NAME>_SECRET_KEY` for compose.yaml's secrets. | accounts, the relays, alpaca-data, its order gateway; alpaca-history (the inventory's `deployment.native.alpaca-history.keys`) |
| `gateway.env` | The order gateways' client tokens: `GATEWAY_OPS_TOKEN` (the operator, admin), `GATEWAY_CONSOLE_TOKEN` (the console, trade), and one per strategy client. Random; `scripts/gateway-token NAME...` adds them. | the gateways, the console, strategies |
| `databento.yaml` | `DATABENTO_API_KEY` and `JOBS_APPROVE_TOKEN`. **hostOnly** (docs/decisions/0013): encrypted to its host's SSH host key and the recovery key only, decrypted there by sops-nix for databento-jobs and the relays alone. `scripts/databento-key` reads or changes it, on that host. | databento-jobs, the OPRA relays |
| `store.env` | `STORE_WRITE_TOKEN`: the store's write token (docs/decisions/0008). `store.env.example` shows its shape. | the store, its writers |
| `console.env` | `CONSOLE_ORDER_TOKEN`, `CONSOLE_ORDER_LOGINS` (the Tailscale logins allowed to make changes), `CONSOLE_JOBS_APPROVE_TOKEN`. | the console |
| `notify.env` | `NTFY_URL` and each host's healthchecks.io ping URL (the inventory's `monitoring.heartbeat` names the keys). `notify.env.example` shows its shape. | each host's monitor, the console, auto-deploy |
| `research.env` | `JUPYTER_TOKEN`, the notebook server's token. | research |
| `runner.env` | `GITHUB_RUNNER_TOKEN`, the site's CI runner's registration token (docs/ci.md). | the runner's activation |
| `tailscale.env` | `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET` (`scripts/tailscale-credential`). | scripts/tailscale-pin, scripts/tailscale-join |

Secrets are decrypted only into the environment of the command that needs
them (scripts/deploy, scripts/local-up.sh, the native services' wrappers),
never written to disk in plain text.
