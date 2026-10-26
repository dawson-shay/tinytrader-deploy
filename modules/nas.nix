# A NAS's role (a NixOS host that holds the store's disks): the services it
# runs, as hardened systemd units from tinytrader's NixOS module, and the
# secrets they need (docs/decisions/0004). The machine's own configuration
# (disks, ZFS, users, networking) lives with your machines; it imports the
# role a deployment makes for it (lib.mkDeployment's nixosModules.<host>):
#
#   imports = [ inputs.my-site.nixosModules.nas ];
#   tinytrader-deploy.nas = {
#     enable = true;
#     volumes = { tank = "/tank/market"; };   # the store's drives: name → path
#   };
#
# Secrets are decrypted at boot by sops-nix with the host's SSH host key (add
# its age recipient to the inventory and run scripts/secrets-recipients
# first), into /run/secrets, and handed to each service as a systemd
# credential: readable by that service alone, never on disk in plain text.
#
# Here so far: the store, the console, Databento jobs, Alpaca history (its
# key: the inventory's deployment.native.alpaca-history.keys) and the host's
# monitor (`watch`, docs/decisions/0006; node_exporter comes with
# tinytrader's module, tinytrader.topology.nodeExporter). Written ahead of
# the placement map: still in compose.yaml, to move next, are the relays,
# accounts, alpaca-data, alpaca-news, econ-calendar, the order gateways and
# the queue.
{
  tinytrader,
  sops-nix,
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
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.tinytrader-deploy.nas;
  inherit (site) inventory;
  historyKeys =
    inventory.deployment.native.alpaca-history.keys
      or (throw "modules/nas.nix: the inventory's deployment.native.alpaca-history.keys (its Alpaca account's secrets file) is unset");
  packages = tinytrader.packages.${pkgs.stdenv.hostPlatform.system};
  secret = name: config.sops.secrets.${name}.path;
  state = name: "/var/lib/tinytrader/${name}";
  # The monitor's settings (modules/watch.nix): every native service enabled
  # here but itself, and the store's volumes among the disks.
  watch = import ./watch.nix { inherit lib site; } host {
    native = lib.attrNames (
      lib.filterAttrs (name: s: name != "watch" && s.enable) config.tinytrader.services
    );
    extraDisks = lib.attrValues cfg.volumes;
  };
  # Notices only once secrets/notify.env exists (and holds HC_PING_NAS):
  # until then the monitor logs what it would send.
  notify = watch.notifyFile != null;
  # Where this host's services reach the others (deploy/local/endpoints.nix,
  # docs/decisions/0008): wherever inventory.nix places them.
  url = to: "http://${site.endpoints.address {
    from = host;
    runtime = "systemd";
    inherit to;
  }}";
  # The store's write token, once secrets/store.env exists (decision 0008):
  # the store requires it, and its writers send it.
  # The nightly backup (modules/backup.nix): its package and settings.
  backup = import ./backup.nix { inherit lib pkgs site; };
  backupHere = backup.forHost host;
  backupState = "/var/lib/tinytrader-backup";
  storeToken = builtins.pathExists (site.secret "store.env");
  withStoreToken = name: lib.optionalAttrs storeToken { ${name} = secret "store-write-token"; };
in
{
  imports = [
    tinytrader.nixosModules.services
    sops-nix.nixosModules.sops
    # The batch scheduler (docs/batch-jobs.md), where the inventory places
    # `nomad` on this host. The machine must allow the unfree nomad package
    # by name.
    ./nomad-nixos.nix
  ];

  options.tinytrader-deploy.nas = {
    enable = mkEnableOption "this deployment's services on the NAS";
    volumes = mkOption {
      type = types.attrsOf types.str;
      example = {
        tank = "/tank/market";
      };
      description = ''
        The store's volumes, name → path (a ZFS dataset's mountpoint). The
        store is the only service that writes them (tinytrader decision 0005).
      '';
    };
    historyTopoff = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "SPY" ];
      description = "Symbols alpaca-history tops off nightly from SIP (none: runs only when asked).";
    };
  };

  config = mkIf cfg.enable {
    # A client of the batch scheduler (deploy/nomad/node.nix). Research
    # jobs mount research/ from a checkout of the site here:
    # deployment.hosts.<host>.siteCheckout (default /srv/<deployment.name>).
    tinytrader-deploy.nomad = mkIf (((inventory.services.nomad or { }).perHost or { }) ? ${host}) (
      import ../deploy/nomad/node.nix {
        inherit site host;
        runtime = "systemd";
        siteCheckout = ((inventory.deployment.hosts or { }).${host} or { }).siteCheckout or "/srv/${site.name}";
      }
    );

    # The nightly backup (inventory.nix `backup`; scripts/backup-state): the
    # services' state directories, as root, into /var/backup/tinytrader, at
    # backup.at local time (a missed run is made at boot: Persistent).
    # Written ahead, like the rest of this role: the placement map runs
    # `backup` on the services' host, which isn't the NAS yet. Its off-host
    # copy starts once inventory.nix backup.offHost and keys name the NAS.
    systemd.services.tinytrader-backup = {
      description = "tinytrader state backup (scripts/backup-state)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = backupHere.environment // {
        HOME = "/root";
        BACKUP_DOCKER = "0";
        BACKUP_ROOT = "/var/backup/tinytrader";
        BACKUP_STATE = backupState;
        BACKUP_SSH_KEY = "/root/.ssh/tinytrader-backup";
        # DynamicUser services keep their state here.
        BACKUP_EXTRA_PATHS = "/var/lib/private/tinytrader";
        BACKUP_GATEWAY_STATE = "/var/lib/private/tinytrader/order-gateway";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe backup.package} --scheduled";
        # The monitor (another user) reads the stamps' age only.
        StateDirectory = "tinytrader-backup";
        StateDirectoryMode = "0711";
        Nice = 10;
        IOSchedulingClass = "idle";
        ProtectSystem = "strict";
        ReadWritePaths = [
          "/var/backup/tinytrader"
          backupState
        ];
        PrivateTmp = true;
      };
    };
    systemd.timers.tinytrader-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${
          lib.fixedWidthNumber 2 inventory.backup.at.hour
        }:${lib.fixedWidthNumber 2 inventory.backup.at.minute}:00";
        Persistent = true;
      };
    };
    systemd.tmpfiles.rules = [ "d /var/backup/tinytrader 0700 root root -" ];

    # Decrypted with the NAS's own SSH host key; nothing to copy onto it.
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    sops.secrets =
      let
        from = file: key: {
          sopsFile = site.secret file;
          format = "dotenv";
          inherit key;
        };
      in
      lib.optionalAttrs notify {
        watch-notify = {
          sopsFile = watch.notifyFile;
          format = "dotenv";
          key = watch.notifyKey;
        };
        watch-heartbeat = {
          sopsFile = watch.notifyFile;
          format = "dotenv";
          key = watch.heartbeatKey;
        };
      }
      // lib.optionalAttrs storeToken {
        store-write-token = from "store.env" "STORE_WRITE_TOKEN";
      }
      // {
        # The Databento key and the purchase approval token: YAML, so each
        # key is its own file (sops-nix writes a dotenv file whole). Root's,
        # mode 0400, handed to databento-jobs alone as a systemd credential
        # (decision 0013: only databento-jobs and the OPRA relays read it).
        databento-api-key = {
          sopsFile = site.secret "databento.yaml";
          format = "yaml";
          key = "DATABENTO_API_KEY";
        };
        jobs-approve-token = {
          sopsFile = site.secret "databento.yaml";
          format = "yaml";
          key = "JOBS_APPROVE_TOKEN";
        };
        # alpaca-history has its own account's key: Alpaca's data limit is per key.
        history-key-id = from historyKeys "APCA_API_KEY_ID";
        history-secret-key = from historyKeys "APCA_API_SECRET_KEY";
      };

    tinytrader.services = {
      # The data store: the only process that touches the data disks.
      store = {
        enable = true;
        package = packages.store;
        observe.port = 9120;
        environment.STORE_VOLUMES = lib.concatStringsSep ";" (
          lib.mapAttrsToList (name: path: "${name}=${path}") cfg.volumes
        );
        writablePaths = lib.attrValues cfg.volumes;
        secrets = withStoreToken "STORE_WRITE_TOKEN";
      };

      # The console, reading the services this host declares.
      console = {
        enable = true;
        package = packages.console;
        observe.port = 8080;
        environment = {
          CONSOLE_TOPOLOGY = config.tinytrader.topology.file;
          # The curated views, from the site (read only here).
          CONSOLE_PREFS_DEFAULTS = "${site.state + "/console/layouts.json"}";
          # Reminders are kept in git (state/console), but this flake's copy
          # is read only: until the NAS has a checkout of its own to write
          # back to, its console keeps them here, uncommitted.
          CONSOLE_REMINDERS = "${state "console"}/reminders.json";
        };
        # Its own push notices, to the same ntfy topic as the monitor's.
        secrets = lib.optionalAttrs notify { CONSOLE_NOTIFY = secret "watch-notify"; };
      };

      databento-jobs = {
        enable = true;
        package = packages.databento-jobs;
        observe.port = 9121;
        environment = {
          JOBS_STORE = url "store";
          JOBS_LEDGER = "${state "databento-jobs"}/ledger.jsonl";
        };
        secrets = {
          DATABENTO_API_KEY = secret "databento-api-key";
          # tinytrader decision 0019 (PR #44); ignored by a databento-jobs without it.
          JOBS_APPROVE_TOKEN = secret "jobs-approve-token";
        }
        // withStoreToken "JOBS_STORE_TOKEN";
      };

      alpaca-history = {
        enable = true;
        package = packages.alpaca-history;
        observe.port = 9124;
        environment = {
          HISTORY_STORE = url "store";
          HISTORY_STATE = state "alpaca-history";
          HISTORY_TOPOFF = lib.concatStringsSep "," cfg.historyTopoff;
        };
        secrets = {
          ALPACA_HISTORY_KEY_ID = secret "history-key-id";
          ALPACA_HISTORY_SECRET_KEY = secret "history-secret-key";
        }
        // withStoreToken "HISTORY_STORE_TOKEN";
      };

      # The host's monitor (tinytrader's watch): the services above, the
      # console's and the store's health, the disks, and the backup's age.
      # No Docker here.
      watch = {
        enable = true;
        package = packages.watch;
        environment = watch.environment // {
          WATCH_FRESH = backupHere.fresh backupState;
        };
        secrets = lib.optionalAttrs notify {
          WATCH_NOTIFY = secret "watch-notify";
          WATCH_HEARTBEAT = secret "watch-heartbeat";
        };
      };
    };
  };
}
