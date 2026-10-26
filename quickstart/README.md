# Quick start: one machine

Run a small tinytrader deployment on your own machine: a toy collector that
streams live Coinbase prices to disk, and the tinytrader console showing the
deployment graph and live state of every service.

You need Docker with Compose. No Nix, accounts or API keys.

```sh
cd quickstart
docker compose up -d             # pulls the images; nothing to build
open http://localhost:8080       # or visit it in any browser
```

The first start downloads the images (about 15 MB each); later starts take
seconds. To build the images yourself instead, see [Images](#images).

## What runs

| Service | Does |
|---|---|
| `ticker` | Subscribes to Coinbase's public ticker feed for BTC-USD and ETH-USD and appends every message to `/data/<product>/<YYYY-MM-DD>.jsonl`. Serves `/health`, `/metrics` and `/recent` on the Compose network. |
| `console` | Serves the console at `http://localhost:8080`, reachable from this machine only. Polls every service and Docker every two seconds. Its sidebar shows this repository's [docs](../docs/). |
| `docker-proxy` | Read-only Docker API. The console reads container state, uptime, restarts, CPU and memory through it, and cannot start, stop or change anything. |

The graph is drawn from [`topology.json`](topology.json). Edit it and the
console picks up the change within 30 seconds.

## Look at it from the command line

Everything the page shows comes from the console's API:

```sh
curl -s http://localhost:8080/api/topology    # the deployment as drawn
curl -s http://localhost:8080/api/state       # every service's health and metrics
```

From a tinytrader checkout, the terminal view reads the same:

```sh
cargo run -p tinytrader-tui -- --console http://localhost:8080
```

The images have no shell, so read the recorded data through a throwaway
container:

```sh
docker run --rm -v tinytrader-quickstart_ticker-data:/d alpine sh -c 'ls -lR /d; tail -n 2 /d/BTC-USD/*.jsonl'
```

## Images

`docker compose up` pulls the published images,
`ghcr.io/dawson-shay/tinytrader-<service>:main`, built from tinytrader's
`main` for linux/amd64 and linux/arm64. Two variables choose others:

| Variable | Default | Meaning |
|---|---|---|
| `TINYTRADER_IMAGE_PREFIX` | `ghcr.io/dawson-shay/tinytrader-` | Image name before the service name |
| `TINYTRADER_TAG` | `main` | Image tag: `main`, `sha-<short commit>`, or a release, `X.Y.Z` |

**Build from a tinytrader checkout** with its `Dockerfile` (needs only
Docker; the first build compiles the workspace and takes a few minutes).
`TINYTRADER_SRC` is the checkout, by default `../tinytrader` beside this
repository:

```sh
docker compose -f compose.yaml -f compose.build.yaml up -d --build
```

`CONSOLE_PORT` moves the console from port 8080, for example when another
console already uses it.

## Things to try

- **Watch a failure.** `docker compose stop ticker` turns it red in the graph
  within a few seconds; `docker compose start ticker` brings it back.
- **Change products.** Set `TICKER_PRODUCTS` in [`compose.yaml`](compose.yaml),
  for example `BTC-USD,ETH-USD,SOL-USD`, then `docker compose up -d`.

## Stop

```sh
docker compose down          # stop, keep the recorded data
docker compose down -v       # stop and delete the recorded data
```

## Notes

- `ticker` is a toy for exercising the platform. It is not a recorder: files
  are plain appends without commits, recovery or gap accounting beyond its
  metrics.
- The console binds to `127.0.0.1` only. Exposing it further, for example
  over Tailscale, belongs to a real deployment's configuration: see
  [A network](../README.md#a-network) and [Your own site](../README.md#your-own-site).
- Access to the Docker socket is equivalent to root on this machine, which is
  why the console only reaches it through the read-only proxy.
