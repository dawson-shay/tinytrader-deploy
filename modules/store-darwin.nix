# The data store and alpaca-history on a Mac, natively (launchd), from
# tinytrader's service definitions, so the same definitions give systemd
# units on Linux (modules/nas.nix). Imported by the darwin role
# (roles/darwin.nix) where the placement map runs either with runtime
# launchd:
#
#   imports = [ (import ./store-darwin.nix { inherit tinytrader site; host = "my-mac"; }) ];
#
# The inventory's deployment.native settings:
#   store = {
#     volumes = [ { name = "data"; root = "my-data-root"; } ];  # the store's volumes, in order:
#                                     # each a data root on this host (dataRoots), by the name the store gives it
#     discover = "/Volumes";          # where drives with an approval marker are taken as they appear (optional)
#     args = [ "--critical" "95" ];   # more arguments for the store (optional)
#   };
#   alpaca-history = {
#     keys = "accounts/my-account.env";   # the Alpaca account whose data limit it uses (APCA_API_KEY_ID, APCA_API_SECRET_KEY)
#     yieldTo = [ "relay-a" ];            # the relays it waits for while they are live (their observe ports)
#     topoff = [ "SPY" ];                 # symbols topped off from SIP every evening (optional; none: runs only when asked)
#   };
#   captureHours = "09:25-16:20";         # the hours it starts no day within 15 minutes of
#
# Secrets are decrypted with the operator key, by a wrapper, into the
# service's own environment only (nix-darwin's launchd services take no
# secrets).
{
  tinytrader,
  site,
  host,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (site) inventory endpoints;
  deployment = inventory.deployment or { };
  native = deployment.native or { };
  home = "/Users/${config.system.primaryUser}";
  packages = tinytrader.packages.${pkgs.stdenv.hostPlatform.system};
  placed =
    name:
    (inventory.services.${name}.host or null) == host
    && (inventory.services.${name}.runtime or null) == "launchd";
  port = name: inventory.services.${name}.ports.http;
  # Where this Mac's native services reach the others (deploy/local/endpoints.nix,
  # docs/decisions/0008).
  # `port`: the port's name, for a service with several (null: its first).
  urlOf =
    to: port:
    "http://${
      endpoints.address {
        from = host;
        runtime = "launchd";
        inherit to port;
      }
    }";
  url = to: urlOf to null;

  # The store, started with its write token (secrets/store.env, decision
  # 0008) decrypted with the operator key into its own environment only, as
  # the monitor's wrapper does (modules/watch-darwin.nix). Without the file
  # in this build, writes stay open as before; with it, a token that can't be
  # decrypted stops the store rather than opening its writes.
  storeEnv = site.secret "store.env";
  storeSettings = native.store or { };
  store = pkgs.writeShellApplication {
    name = "store-${host}";
    runtimeInputs = [
      pkgs.sops
      pkgs.gnused
    ];
    text = ''
      store_env=${if builtins.pathExists storeEnv then lib.escapeShellArg "${storeEnv}" else ""}
      if [ -z "$store_env" ]; then
        echo "store: secrets/store.env isn't in this build: writes are open (tinytrader-deploy docs/decisions/0008)" >&2
      else
        if ! env="$(sops decrypt --input-type dotenv --output-type dotenv "$store_env" 2>/dev/null)"; then
          echo "store: could not decrypt secrets/store.env (the operator key?): not starting with writes open" >&2
          exit 1
        fi
        STORE_WRITE_TOKEN="$(sed -n 's/^STORE_WRITE_TOKEN=//p' <<<"$env" | head -n1)"
        unset env
        [ -n "$STORE_WRITE_TOKEN" ] || { echo "store: secrets/store.env has no STORE_WRITE_TOKEN" >&2; exit 1; }
        export STORE_WRITE_TOKEN
      fi
      exec ${lib.getExe packages.store}${
        lib.concatMapStrings (a: " " + lib.escapeShellArg a) (storeSettings.args or [ ])
      } "$@"
    '';
  };
  # Each volume's data root must be on this host, and granted to the store.
  volume =
    v:
    let
      root = inventory.dataRoots.${v.root} or (throw "store-darwin: deployment.native.store.volumes: no data root ${v.root}");
    in
    assert lib.assertMsg (root.host == host) "store-darwin: data root ${v.root} is on ${root.host}, not ${host}";
    "${v.name}=${root.path}";

  # alpaca-history, started the same way: its Alpaca key (the inventory's
  # deployment.native.alpaca-history.keys: Alpaca's data limit is per key),
  # and the store's write token from secrets/store.env, decrypted with the
  # operator key into its own environment only. A file that can't be
  # decrypted stops it.
  historySettings = native.alpaca-history or { };
  historyKeysName =
    historySettings.keys
      or (throw "store-darwin: the inventory's deployment.native.alpaca-history.keys (its Alpaca account's secrets file) is unset");
  historyKeys = site.secret historyKeysName;
  history = pkgs.writeShellApplication {
    name = "alpaca-history-${host}";
    runtimeInputs = [
      pkgs.sops
      pkgs.gnused
    ];
    text = ''
      keys=${lib.escapeShellArg "${historyKeys}"}
      if ! env="$(sops decrypt --input-type dotenv --output-type dotenv "$keys" 2>/dev/null)"; then
        echo "alpaca-history: could not decrypt secrets/${historyKeysName} (the operator key?)" >&2
        exit 1
      fi
      ALPACA_HISTORY_KEY_ID="$(sed -n 's/^APCA_API_KEY_ID=//p' <<<"$env" | head -n1)"
      ALPACA_HISTORY_SECRET_KEY="$(sed -n 's/^APCA_API_SECRET_KEY=//p' <<<"$env" | head -n1)"
      unset env
      if [ -z "$ALPACA_HISTORY_KEY_ID" ] || [ -z "$ALPACA_HISTORY_SECRET_KEY" ]; then
        echo "alpaca-history: secrets/${historyKeysName} has no APCA_API_KEY_ID or APCA_API_SECRET_KEY" >&2
        exit 1
      fi
      export ALPACA_HISTORY_KEY_ID ALPACA_HISTORY_SECRET_KEY
      store_env=${if builtins.pathExists storeEnv then lib.escapeShellArg "${storeEnv}" else ""}
      if [ -n "$store_env" ]; then
        if ! env="$(sops decrypt --input-type dotenv --output-type dotenv "$store_env" 2>/dev/null)"; then
          echo "alpaca-history: could not decrypt secrets/store.env (the operator key?)" >&2
          exit 1
        fi
        HISTORY_STORE_TOKEN="$(sed -n 's/^STORE_WRITE_TOKEN=//p' <<<"$env" | head -n1)"
        unset env
        [ -n "$HISTORY_STORE_TOKEN" ] || { echo "alpaca-history: secrets/store.env has no STORE_WRITE_TOKEN" >&2; exit 1; }
        export HISTORY_STORE_TOKEN
      fi
      exec ${lib.getExe packages.alpaca-history} "$@"
    '';
  };
in
{
  # (tinytrader.darwinModules.services is the role's import.)
  config = lib.mkMerge [
    # The data store, run natively so it sees drives as they are attached
    # (tinytrader decisions 0005, 0007).
    (lib.mkIf (placed "store") {
      tinytrader.services.store = {
        enable = true;
        package = store;
        # On loopback (the default bind): containers reach it as
        # host.docker.internal, other hosts through `tailscale serve`
        # (scripts/tailnet-serve), never on another address.
        observe.port = port "store";
        environment = {
          # sops finds the operator key under HOME.
          HOME = home;
          # Its volumes, writable by the store alone, which never replaces
          # data.
          STORE_VOLUMES = lib.concatMapStringsSep ";" volume (storeSettings.volumes or [ ]);
        }
        // lib.optionalAttrs (storeSettings ? discover) {
          # Drives here that carry an approval marker are used as they appear;
          # others are offered in the console's Storage widget.
          STORE_DISCOVER = storeSettings.discover;
        };
      };
    })

    # Alpaca's past trades and quotes, a day at a time, into the store
    # (tinytrader decision 0014). A launchd agent, like the store it writes
    # to. Runs only when asked (POST /runs): no nightly top-off. On loopback;
    # other hosts reach it through `tailscale serve`.
    (lib.mkIf (placed "alpaca-history") {
      tinytrader.services.alpaca-history = {
        enable = true;
        package = history;
        observe.port = port "alpaca-history";
        environment = {
          # sops finds the operator key under HOME.
          HOME = home;
          HISTORY_STORE = url "store";
          HISTORY_STATE = "${home}/.local/state/tinytrader/alpaca-history";
          # Background work (tinytrader decision 0011): it waits while the
          # relays it yields to are live, and starts no day within 15
          # minutes of their hours.
          HISTORY_YIELD_TO = lib.concatMapStringsSep ";" (r: "${r}=${urlOf r "observe"}") (
            historySettings.yieldTo or [ ]
          );
          HISTORY_CAPTURE_HOURS = deployment.captureHours or "09:25-16:20";
        }
        // lib.optionalAttrs ((historySettings.topoff or [ ]) != [ ]) {
          # Symbols it tops off from SIP every evening, as on a NAS
          # (modules/nas.nix historyTopoff).
          HISTORY_TOPOFF = lib.concatStringsSep "," historySettings.topoff;
        };
      };
    })
  ];
}
