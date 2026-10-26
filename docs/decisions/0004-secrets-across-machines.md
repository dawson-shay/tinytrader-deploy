# 0004: Secrets across machines

- **Status:** Accepted; amended by [0005](0005-placement-map.md): a Mac you
  sit at that runs services may decrypt with the operator key
  (`secrets.operatorKeyHosts`); and by
  [0013](0013-databento-key-held-by-its-services.md): the Databento key
  (`databento.yaml`) is its hosts' and the recovery key's alone, not the
  operator key's (`secrets.hostOnly`)
- **Date:** 2026-10-14

## Context

The simple start is every secret under the site's `secrets/` encrypted to one
age key, kept on the machine that runs everything, and copied by hand to any
machine that needs it. With services on a NAS and a Mac for research and
training, that means the same all-powerful key on every machine. Losing it
loses every secret; one compromised machine gives up all of them; and
nothing says which machine needs which secret.

## Decision

Secrets stay as sops-encrypted files in the site. Who can decrypt each file
is decided per file, from the inventory, and each machine has an identity of
its own.

### Identities

| Identity | What it is | Can decrypt |
|---|---|---|
| **Operator** | Your age key, on the machines you work at. Never on a server. | Everything: you edit secrets. |
| **Recovery** | A second age key, generated once and kept offline (printed, and in your password manager), never on a machine. | Everything: restoring if the operator key is lost. |
| **Host** | A machine's own SSH host key (`/etc/ssh/ssh_host_ed25519_key`), turned into an age recipient with `ssh-to-age`. Nothing to copy: the key is made on the machine and never leaves it. | Only the files for the services that machine runs. |

### Who gets what

The site's `inventory.nix` lists each machine's age recipient (public, so
committed) and, for each secrets file, the machines that run its services.
`scripts/secrets-recipients` writes the site's `.sops.yaml` from that and
re-encrypts every file to its recipients (`sops updatekeys`). The operator
and recovery keys are recipients of every file (but the `hostOnly` ones,
0013); a host is a recipient only of what it was granted. For example:

| File | Used by | Machines |
|---|---|---|
| `accounts/*.env` | accounts, alpaca-data, alpaca-news, relays, order gateways, alpaca-history | the services' host |
| `gateway.env` | order gateways and their clients | the services' host |
| `databento.yaml` | databento-jobs, OPRA relays | their host only; **not the operator key** ([0013](0013-databento-key-held-by-its-services.md)) |
| `econ.env` | econ-calendar | the services' host |
| `research.env` | notebooks, Kaggle downloads | the services' host, and you on a Mac you sit at (operator key) |

### On the machine

- **NixOS (a NAS):** sops-nix decrypts at activation into `/run/secrets`
  (memory, not disk), each file owned by the service that reads it. Services
  read `*_FILE` variables, which tinytrader's services already support
  (`tinytrader_observe::secret`). Nothing decrypted is written to disk or
  passed on a command line.
- **macOS, a Mac you sit at:** it needs no host identity: you decrypt with
  the operator key when you need to: `sops exec-env secrets/research.env '…'`.
  A Mac you sit at that also runs containers decrypts their secrets the same
  way, with the operator key, when `scripts/deploy` or `scripts/local-up.sh`
  starts them ([0005](0005-placement-map.md): `secrets.operatorKeyHosts`).
- **macOS with native secrets:** a Mac whose native services need a file
  that is `hostOnly` gets it from sops-nix with its own host key, as a NAS
  does ([0013](0013-databento-key-held-by-its-services.md)).

### Changes

- **Moving a service** to another machine: change its line in the inventory,
  run `scripts/secrets-recipients`, and commit. Only the machines listed can
  decrypt.
- **Retiring a machine:** remove its recipient, re-run, and replace (rotate)
  every secret it could read. It had them in memory.
- **Replacing a secret:** a new value is encrypted to the same recipients.
- **Losing the operator key:** decrypt with the recovery key, make a new
  operator key, re-run, and store the new one.

## Consequences

- No private key is ever copied between machines except the operator key, to
  the machines you sit at.
- A compromised NAS gives up the secrets of the services it runs, not your
  operator key; a compromised Mac you sit at gives up nothing it didn't
  already have through you.
- Creating keys stays with you: the recovery key and any new account or token.
  Agents never generate or print secrets.
- Alpaca's market data limit is per key, so services that fetch heavily use
  their own account's key (alpaca-history uses a paper account's).
