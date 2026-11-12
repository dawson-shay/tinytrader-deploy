# A NAS's role (a NixOS host that holds the store's disks): the services it
# runs, as hardened systemd units from tinytrader's NixOS module, and the
# secrets they need (docs/decisions/0004). The machine's own configuration
# (disks, ZFS, users, networking) lives with your machines; it imports the
# role a deployment makes for it (lib.mkDeployment's nixosModules.<host>):
#
#   imports = [ inputs.my-site.nixosModules.nas ];
#   tinytrader-deploy.nas = {
#     enable = true;
#     # The store's drives: name → { path; id; }, a mounted filesystem each
#     # (a ZFS dataset, say), whose id file holds `id`.
#     volumes.tank = { path = "/tank/market"; id = "tank-2026-01-01-1a2b3c4d"; };
#   };
#
# Each service runs here when the placement map puts it here (inventory.nix
# `services`). While the host is still `planned`, everything is enabled, so
# the module is evaluated and checked ahead of the hardware.
#
# The store (tinytrader decision 0039, "Where it runs"): the only writer of
# its volumes, as a system user of its own (not a transient one: the files it
# writes outlive the unit); it needs every volume's filesystem mounted
# (RequiresMountsFor) and refuses to start unless each volume's id file
# (`idFile`, at its root) holds the id given here. A missing or swapped disk
# leaves the store stopped, never writing to the empty directory under a
# mount point or to the wrong disk.
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
# the queue. A recorder placeholder (tinytrader decision 0040), off, where the
# site places `recorders`; the store's maintenance timers
# (modules/nas-maintenance.nix); auto-deploy (modules/auto-deploy-nixos.nix).
{
  tinytrader,
  sops-nix,
  site,
  host,
}:
{
  config,
  options,
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
  # Whether the placement map runs a service here. A planned host runs
  # everything its role declares (written ahead, as checks/placement.nix
  # allows); once it exists, only what is placed on it.
  planned = (inventory.hosts.${host}.status or "") == "planned";
  placedHere =
    name:
    let
      s = inventory.services.${name} or { };
    in
    (s.host or null) == host || (s.perHost or { }) ? ${host};
  here = name: planned || placedHere name;
  volumePaths = lib.mapAttrsToList (_: v: v.path) cfg.volumes;
  storeUser = "tinytrader-store";
  # tinytrader's services module names a static user itself (`user`) from
  # the revision that has it; with an older tinytrader the store's unit is
  # given one below.
  hasUserOption = (options.tinytrader.services.type.getSubOptions [ ]) ? user;
  # Before the store starts: each volume's path is a mount point and its id
  # file holds the id the machine's configuration expects (decision 0039).
  volumeCheck = pkgs.writeShellScript "tinytrader-store-volumes" ''
    set -u
    bad=0
    check() {
      name="$1" path="$2" want="$3"
      if ! ${pkgs.util-linux}/bin/mountpoint -q "$path"; then
        echo "store: volume $name: $path is not a mounted filesystem; refusing to start" >&2
        bad=1
        return
      fi
      if [ ! -r "$path/${cfg.idFile}" ]; then
        echo "store: volume $name: no readable $path/${cfg.idFile}; refusing to start" >&2
        bad=1
        return
      fi
      got="$(${pkgs.coreutils}/bin/head -c 256 "$path/${cfg.idFile}" | ${pkgs.coreutils}/bin/tr -d '[:space:]')"
      if [ "$got" != "$want" ]; then
        echo "store: volume $name: $path/${cfg.idFile} says '$got', expected '$want' (the wrong disk?); refusing to start" >&2
        bad=1
        return
      fi
      echo "store: volume $name: $path is $want"
    }
    ${lib.concatStrings (
      lib.mapAttrsToList (
        name: v:
        "check ${
          lib.escapeShellArgs [
            name
            v.path
            v.id
          ]
        }
"
      ) cfg.volumes
    )}
    exit "$bad"
  '';
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
    extraDisks = volumePaths;
  };
  # Notices only once secrets/notify.env exists (and holds HC_PING_NAS):
  # until then the monitor logs what it would send.
  notify = watch.notifyFile != null;
  # Where this host's services reach the others (deploy/local/endpoints.nix,
  # docs/decisions/0008): wherever inventory.nix places them.
  urlOf =
    to: port:
    "http://${
      site.endpoints.address {
        from = host;
        runtime = "systemd";
        inherit to port;
      }
    }";
  url = to: urlOf to null;
  # Background work yields to live capture (tinytrader decisions 0011,
  # 0033): the relays a service `uses` by their observe port, wherever they
  # run (the services' host, over the tailnet), and capture's hours.
  captureHours = inventory.deployment.captureHours or "09:25-16:20";
  relaysUsedBy =
    name:
    lib.filter (r: lib.hasPrefix "relay-" r) (
      map (u: lib.head (lib.splitString ":" u)) ((inventory.services.${name} or { }).uses or [ ])
    );
  yieldTo = relays: lib.concatMapStringsSep ";" (r: "${r}=${urlOf r "observe"}") relays;
  uses =
    name: other:
    lib.any (u: lib.head (lib.splitString ":" u) == other) (
      (inventory.services.${name} or { }).uses or [ ]
    );
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
    # The store's scheduled maintenance (tt-fsck, the integrity sweep, the
    # cold copies, backfills): systemd timers, off until their binaries exist.
    ./nas-maintenance.nix
    # Deploying what merges to main (docs/decisions/0011), off unless asked.
    ./auto-deploy-nixos.nix
    # No switch during market hours that changes a live-path unit.
    (import ./switch-guard-nixos.nix { inherit site; })
  ];

  options.tinytrader-deploy.nas = {
    enable = mkEnableOption "this deployment's services on the NAS";
    volumes = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            path = mkOption {
              type = types.str;
              description = "Where the volume is mounted (a ZFS dataset's mountpoint, say).";
            };
            id = mkOption {
              type = types.strMatching "[A-Za-z0-9._-]+";
              description = ''
                The volume's identity: what its id file (`idFile`, at the
                volume's root) must hold, or the store refuses to start
                (tinytrader decision 0039). Written once, when the volume is
                made; never reused for another disk.
              '';
            };
          };
        }
      );
      example = {
        tank = {
          path = "/tank/market";
          id = "tank-2026-01-01-1a2b3c4d";
        };
      };
      description = ''
        The store's volumes, name → { path, id }. The store is the only
        service that writes them (tinytrader decisions 0005, 0039: one writer
        per volume).
      '';
    };
    idFile = mkOption {
      type = types.str;
      default = ".tinytrader-volume-id";
      description = ''
        The id file at each volume's root, checked before the store starts.
        Until the store keeps one itself (decision 0039), it is written by
        hand when the volume is made.
      '';
    };
    backupReceive = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep other hosts' off-host backup copies here (the inventory's
          backup.offHost naming this host): accept their backup keys
          (backup.keys) for `user`, restricted to rrsync, write-only, into
          `<user's home>/Backups/tinytrader-from-<host>` (mode 700), from the
          tailnet only, as a receiving Mac does
          (tinytrader-deploy.backup.receive).
        '';
      };
      user = mkOption {
        type = types.nullOr types.str;
        default = (site.inventory.backup.accounts or { }).${host} or null;
        defaultText = lib.literalMD "the inventory's `backup.accounts.<host>`";
        description = "The account the senders log in as (backup.accounts.<host> in the inventory).";
      };
    };
    historyTopoff = mkOption {
      type = types.listOf types.str;
      # The site's (inventory.nix deployment.native.alpaca-history.topoff),
      # as on a Mac.
      default = (inventory.deployment.native.alpaca-history or { }).topoff or [ ];
      example = [ "SPY" ];
      description = "Symbols alpaca-history tops off nightly from SIP (none: runs only when asked).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.tinytrader.services.store.enable || cfg.volumes != { };
        message = "tinytrader-deploy.nas: the store runs here, but nas.volumes is empty";
      }
      {
        assertion =
          let
            ids = lib.mapAttrsToList (_: v: v.id) cfg.volumes;
          in
          lib.length ids == lib.length (lib.unique ids);
        message = "tinytrader-deploy.nas.volumes: two volumes have the same id";
      }
      {
        assertion =
          !cfg.backupReceive.enable
          || (cfg.backupReceive.user != null && config.users.users ? ${cfg.backupReceive.user});
        message = "tinytrader-deploy.nas.backupReceive: its user (the inventory's backup.accounts.${host}) must be an account of this machine";
      }
    ];

    # The deploy checkouts are named as on a Mac: <deployRoot>/<deployment>.
    tinytrader-deploy.checkouts.site = lib.mkDefault "${config.tinytrader-deploy.deployRoot}/${site.name}";

    # The store's own system user: it owns what it writes on the volumes,
    # across restarts and rebuilds (a DynamicUser's uid may change). With a
    # tinytrader that has `user`, it is tinytrader.services.store.user (set
    # below) and tinytrader's module makes the unit's User=; these
    # definitions agree with it. Either way the unit runs as storeUser.
    users.users.${storeUser} = mkIf config.tinytrader.services.store.enable {
      isSystemUser = true;
      group = storeUser;
      description = "tinytrader store (the only writer of the store's volumes)";
    };
    users.groups.${storeUser} = mkIf config.tinytrader.services.store.enable { };

    systemd.services.tinytrader-store = mkIf config.tinytrader.services.store.enable {
      # Each volume mounted first; if one isn't (a pool not imported, a disk
      # gone), the store doesn't start.
      unitConfig.RequiresMountsFor = volumePaths;
      # A switch never restarts it: the recorders and the jobs write
      # through it, so a new store starts when the operator restarts it
      # (systemctl restart tinytrader-store), outside market hours. The
      # switch guard (modules/switch-guard.nix) refuses a switch that
      # changes it during them.
      restartIfChanged = false;
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = storeUser;
        Group = storeUser;
        ExecStartPre = [ "${volumeCheck}" ];
      };
    };

    # A client of the batch scheduler (deploy/nomad/node.nix). Research
    # jobs mount research/ from a checkout of the site here:
    # deployment.hosts.<host>.siteCheckout (default /srv/<deployment.name>).
    tinytrader-deploy.nomad = mkIf (((inventory.services.nomad or { }).perHost or { }) ? ${host}) (
      import ../deploy/nomad/node.nix {
        inherit site host;
        runtime = "systemd";
        siteCheckout =
          ((inventory.deployment.hosts or { }).${host} or { }).siteCheckout or "/srv/${site.name}";
      }
    );

    # The nightly backup (inventory.nix `backup`; scripts/backup-state): the
    # services' state directories, as root, into /var/backup/tinytrader, at
    # backup.at local time (a missed run is made at boot: Persistent).
    # Written ahead, like the rest of this role: the placement map runs
    # `backup` on the services' host, which isn't the NAS yet. Its off-host
    # copy starts once inventory.nix backup.offHost and keys name the NAS.
    systemd.services.tinytrader-backup = mkIf (here "backup") {
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
    systemd.timers.tinytrader-backup = mkIf (here "backup") {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${lib.fixedWidthNumber 2 inventory.backup.at.hour}:${lib.fixedWidthNumber 2 inventory.backup.at.minute}:00";
        Persistent = true;
      };
    };
    # Recording live streams: never restarted by a switch, as the store.
    systemd.services.tinytrader-recorders =
      mkIf (config.tinytrader.services.recorders.enable or false)
        {
          restartIfChanged = false;
        };

    systemd.tmpfiles.rules =
      lib.optional (here "backup") "d /var/backup/tinytrader 0700 root root -"
      ++ lib.optionals cfg.backupReceive.enable (
        let
          home = config.users.users.${cfg.backupReceive.user}.home;
          u = cfg.backupReceive.user;
          g = if config.users.users.${u}.group == "" then "users" else config.users.users.${u}.group;
        in
        [ "d ${home}/Backups 0700 ${u} ${g} -" ]
        ++ map (from: "d ${backup.inbox home from} 0700 ${u} ${g} -") (backup.forHost host).senders
      );

    # Other hosts' off-host backup copies (the receiving side of
    # inventory.nix backup.offHost; modules/backup.nix authorizedKeys).
    # (Under mkIf: with the receiver off, its user may be unset.)
    users.users.${if cfg.backupReceive.user == null then "root" else cfg.backupReceive.user} =
      mkIf cfg.backupReceive.enable
        {
          openssh.authorizedKeys.keys =
            (backup.forHost host).authorizedKeys
              config.users.users.${cfg.backupReceive.user}.home;
        };

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
        enable = here "store";
        package = packages.store;
        observe.port = 9120;
        environment = {
          STORE_VOLUMES = lib.concatStringsSep ";" (
            lib.mapAttrsToList (name: v: "${name}=${v.path}") cfg.volumes
          );
          # Its record of every volume it has used (the default is a Mac's).
          STORE_STATE = "${state "store"}/store-state.json";
        };
        writablePaths = volumePaths;
        secrets = withStoreToken "STORE_WRITE_TOKEN";
      }
      // lib.optionalAttrs hasUserOption { user = storeUser; };

      # The console, reading the services this host declares.
      console = {
        enable = here "console";
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
        enable = here "databento-jobs";
        package = packages.databento-jobs;
        observe.port = 9121;
        environment = {
          JOBS_STORE = url "store";
          JOBS_LEDGER = "${state "databento-jobs"}/ledger.jsonl";
          JOBS_YIELD_TO = yieldTo (relaysUsedBy "databento-jobs");
          JOBS_CAPTURE_HOURS = captureHours;
        }
        // lib.optionalAttrs (uses "databento-jobs" "accounts") {
          # The market calendar (holidays, early closes).
          JOBS_CALENDAR = "${urlOf "accounts" "http"}/calendar";
        };
        secrets = {
          DATABENTO_API_KEY = secret "databento-api-key";
          # tinytrader decision 0019 (PR #44); ignored by a databento-jobs without it.
          JOBS_APPROVE_TOKEN = secret "jobs-approve-token";
        }
        // withStoreToken "JOBS_STORE_TOKEN";
      };

      alpaca-history = {
        enable = here "alpaca-history";
        package = packages.alpaca-history;
        observe.port = 9124;
        environment = {
          HISTORY_STORE = url "store";
          HISTORY_STATE = state "alpaca-history";
          HISTORY_TOPOFF = lib.concatStringsSep "," cfg.historyTopoff;
          HISTORY_YIELD_TO = yieldTo ((inventory.deployment.native.alpaca-history or { }).yieldTo or [ ]);
          HISTORY_CAPTURE_HOURS = captureHours;
        };
        secrets = {
          ALPACA_HISTORY_KEY_ID = secret "history-key-id";
          ALPACA_HISTORY_SECRET_KEY = secret "history-secret-key";
        }
        // withStoreToken "HISTORY_STORE_TOKEN";
      };

    }
    # Live capture recorders (tinytrader decision 0040): a placeholder, off,
    # until tinytrader has the recorder binary (0040's steps, after 0035's
    # core). Declared where the site places `recorders`, so the placement map
    # and this role agree; it reads the streams it `uses` (the relays, over
    # the tailnet) and will seal its chunks into the store. Enabling it means
    # setting a real package here, not just enable = true.
    // lib.optionalAttrs (inventory.services ? recorders) {
      recorders = {
        enable = false;
        package = pkgs.writeShellScriptBin "recorders" ''
          echo "recorders: not built yet (tinytrader decision 0040)" >&2
          exit 1
        '';
        environment = {
          RECORDER_STORE = url "store";
          RECORDER_SOURCES = lib.concatMapStringsSep ";" (r: "${r}=${urlOf r "stream"}") (
            relaysUsedBy "recorders"
          );
        };
        secrets = withStoreToken "RECORDER_STORE_TOKEN";
      };
    }
    // {
      # The host's monitor (tinytrader's watch): the services above, the
      # console's and the store's health, the disks, and the backup's age.
      # No Docker here.
      watch = {
        enable = here "watch";
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
