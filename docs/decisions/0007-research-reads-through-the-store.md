# 0007: Research reads market data through the store

- **Status:** Accepted
- **Date:** 2026-10-15

## Context

A `research` service (JupyterLab, the site's `research/tt.py`) that mounts
folders of the external drives read-only, with notebooks reading DBN files
by their mount path, ties notebooks to where each drive is plugged in, which
changes whenever the drives move to another machine (another Mac, a NAS).
It also sidesteps the principle of the inventory that services name logical
data roots, never physical paths. tinytrader's decision 0005 already makes
the store the one process that touches the disks.

## Decision

Notebooks ask the store for data by default. `tt.tapes(pattern)` lists the
DBN files the store holds by logical name (`<volume>/<path>`, such as
`market/Databento/OPRA.PILLAR/SPY.OPT/cmbp-1/2026-09-01.dbn.zst`) through
the store's `GET /files`, and `tt.read_dbn(name)` fetches one whole through
`GET /files/{volume}/{path}`. The store's address is `TT_STORE`; the research
container mounts no drive.

## Consequences

- Moving the drives changes only the store's address, not notebooks.
- Each read moves a whole file over HTTP: fine for a day or a few, slow for
  scans over months. **Bulk reads, and colocating chosen processes with the
  data where that is best** (as the NFS routes in the architecture describe
  for a NAS), **come later**, as deliberate exceptions to this default.
- The store sees only the volumes it is given: anything on a drive outside
  the store's volumes, and files other than finished DBN (CSV or JSON
  downloads, provider manifests, `.partial` files being written) can't be
  read from notebooks.
- When the store and research are on different hosts, the store has to be
  reachable from research's host, which it isn't while it binds to loopback.
  ([0008](0008-addresses-from-the-placement-map.md): its address comes from
  the map, `tailscale serve` forwards it, and its writes need a token.)
