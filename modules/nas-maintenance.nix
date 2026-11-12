# The store's scheduled maintenance on a NAS (imported by modules/nas.nix):
# systemd timers, not Nomad jobs and not tinytrader services, beside the
# store and its volumes.
#
#   fsck        tt-fsck over every volume: the storage contract, checked from
#               the disk alone (tinytrader decision 0039). With the store
#               stopped (tt-fsck refuses while the store holds a volume's
#               lock), then started again; paced, in a window with no capture.
#   sweep       the integrity sweep: every object re-hashed against its name
#               (decision 0035, section 7), paced, through the store.
#   export      the cold copies: `tt store export --class irreplaceable --to
#               <volume>` (decision 0039, section 3), when that drive is
#               mounted.
#   backfill    scheduled backfills (decision 0033): requests to
#               alpaca-history's POST /runs, each with origin=scheduled, so
#               they yield to capture.
#
# fsck, sweep and export have no binary yet: each is declared, its timer off,
# and its service runs a stub that says which decision it waits for. Turning
# one on is setting its `package` (and `enable`); an assertion refuses
# `enable` without one. backfill needs nothing new: it is on as soon as it
# has requests.
#
# Every timer fires outside capture's hours (New York time, as the
# inventory's deployment.captureHours), and a run missed while the machine
# was off is made at boot (Persistent).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  nas = config.tinytrader-deploy.nas;
  cfg = nas.maintenance;
  volumePaths = lib.mapAttrsToList (_: v: v.path) nas.volumes;
  storeHere = config.tinytrader.services.store.enable or false;
  historyHere = config.tinytrader.services.alpaca-history.enable or false;
  # Where a service here listens (tinytrader's module: TINYTRADER_LISTEN).
  listen =
    name:
    let
      o = config.tinytrader.services.${name}.observe;
    in
    "${o.bind}:${toString o.port}";

  stub =
    name: decision:
    pkgs.writeShellScript "tinytrader-${name}-not-built" ''
      echo "tinytrader-${name}: no binary yet (tinytrader decision ${decision}); set tinytrader-deploy.nas.maintenance.${name}.package" >&2
      exit 1
    '';

  jobOptions =
    {
      name,
      decision,
      onCalendar,
      what,
    }:
    {
      enable = lib.mkEnableOption "the ${what} timer (tinytrader decision ${decision})";
      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "The package whose main program runs the ${what}. None yet: decision ${decision} is not built.";
      };
      onCalendar = mkOption {
        type = types.str;
        default = onCalendar;
        description = "When the ${what} runs (systemd.time(7); a time zone may follow).";
      };
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Arguments after the volumes or the store's address (the binary's own flags, such as its pace).";
      };
    };

  # A oneshot service and its timer. The timer is installed only when
  # enabled; the service always exists, so `systemctl start` shows what is
  # missing.
  job =
    {
      name,
      enable,
      onCalendar,
      description,
      exec,
      extra ? { },
    }:
    {
      services."tinytrader-${name}" = lib.recursiveUpdate {
        inherit description;
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = exec;
          Nice = 10;
          IOSchedulingClass = "idle";
          DynamicUser = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      } extra;
      timers."tinytrader-${name}" = lib.mkIf enable {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = onCalendar;
          Persistent = true;
          RandomizedDelaySec = "10m";
        };
      };
    };
  main =
    name: decision:
    if cfg.${name}.package == null then stub name decision else lib.getExe cfg.${name}.package;
in
{
  options.tinytrader-deploy.nas.maintenance = {
    fsck =
      jobOptions {
        name = "fsck";
        decision = "0039";
        what = "tt-fsck";
        # The first Saturday of each month, after Friday's close: nothing
        # captures, and the store is down while it runs.
        onCalendar = "Sat *-*-01..07 02:00:00 America/New_York";
      }
      // {
        stopStore = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Stop the store while tt-fsck runs and start it after (decision
            0039: it reads volumes with the store not running). Off only for
            a tt-fsck that checks a live volume read-only and paced.
          '';
        };
      };
    sweep = jobOptions {
      name = "sweep";
      decision = "0035";
      what = "integrity sweep";
      # Weekly, Sunday morning: no capture, and before fsck's Saturday.
      onCalendar = "Sun *-*-* 03:00:00 America/New_York";
    };
    export =
      jobOptions {
        name = "export";
        decision = "0039";
        what = "cold copy (tt store export)";
        onCalendar = "Sun *-*-* 06:00:00 America/New_York";
      }
      // {
        to = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/mnt/cold-1";
          description = "The cold drive's mount point. The export runs only while it is mounted.";
        };
        class = mkOption {
          type = types.str;
          default = "irreplaceable";
          description = "What it copies (`--class`; decision 0034's classes), or `all`.";
        };
      };
    backfill = {
      requests = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        example = [
          {
            feed = "sip";
            symbols = [ "SPY" ];
            start = "2016-01-04";
            through = "2016-12-30";
          }
        ];
        description = ''
          Runs to queue on alpaca-history (its POST /runs body), each sent
          with origin = "scheduled" (decision 0033) so it yields to capture.
          alpaca-history skips the days it already holds. None: no timer.
        '';
      };
      onCalendar = mkOption {
        type = types.str;
        default = "*-*-* 20:50:00 America/New_York";
        description = "When the requests are queued (after the evening top-off).";
      };
    };
  };

  config = lib.mkIf nas.enable {
    assertions =
      map
        (n: {
          assertion = !cfg.${n}.enable || cfg.${n}.package != null;
          message = "tinytrader-deploy.nas.maintenance.${n}: enabled without a package (its binary isn't built yet)";
        })
        [
          "fsck"
          "sweep"
          "export"
        ]
      ++ [
        {
          assertion = !cfg.export.enable || cfg.export.to != null;
          message = "tinytrader-deploy.nas.maintenance.export: enabled without `to`, the cold drive";
        }
        {
          assertion = cfg.backfill.requests == [ ] || historyHere;
          message = "tinytrader-deploy.nas.maintenance.backfill: requests, but alpaca-history doesn't run here";
        }
      ];

    systemd = lib.mkMerge (
      lib.optionals storeHere [
        # tt-fsck: reads every volume, writes nothing (0039). As the store's
        # user, read-only. Exit 1 is findings, 2 a volume it couldn't read:
        # both fail the unit, so the monitor and the journal show it.
        (job {
          name = "fsck";
          inherit (cfg.fsck) enable onCalendar;
          description = "tinytrader tt-fsck: the storage contract, from the disk (decision 0039)";
          exec = lib.escapeShellArgs ([ (main "fsck" "0039") ] ++ volumePaths ++ cfg.fsck.args);
          extra = {
            unitConfig.RequiresMountsFor = volumePaths;
            serviceConfig = {
              DynamicUser = false;
              User = "tinytrader-store";
              Group = "tinytrader-store";
              ReadOnlyPaths = volumePaths;
            }
            // lib.optionalAttrs cfg.fsck.stopStore {
              # Stopped before, started after, whatever tt-fsck found
              # ("+": as root, to manage the store's unit).
              ExecStartPre = [ "+${pkgs.systemd}/bin/systemctl stop tinytrader-store.service" ];
              ExecStopPost = [ "+${pkgs.systemd}/bin/systemctl start tinytrader-store.service" ];
            };
          };
        })
        # The integrity sweep (0035 section 7): the store re-hashes its
        # objects, paced, pausing on volume errors. It may become the store's
        # own schedule; then this timer goes.
        (job {
          name = "sweep";
          inherit (cfg.sweep) enable onCalendar;
          description = "tinytrader integrity sweep (decision 0035)";
          exec = lib.escapeShellArgs (
            [ (main "sweep" "0035") ]
            ++ [ "http://${listen "store"}" ]
            ++ cfg.sweep.args
          );
        })
        # Cold copies (0039 section 3): only while the cold drive is mounted.
        (job {
          name = "export";
          inherit (cfg.export) enable onCalendar;
          description = "tinytrader cold copy: tt store export (decision 0039)";
          exec = lib.escapeShellArgs (
            [ (main "export" "0039") ]
            ++ [
              "store"
              "export"
              "--class"
              cfg.export.class
            ]
            ++ lib.optionals (cfg.export.to != null) [
              "--to"
              cfg.export.to
            ]
            ++ cfg.export.args
          );
          # As the store's user: the cold drive is a volume, and what is on it
          # stays the store's.
          extra = {
            serviceConfig = {
              DynamicUser = false;
              User = "tinytrader-store";
              Group = "tinytrader-store";
            }
            // lib.optionalAttrs (cfg.export.to != null) {
              ReadWritePaths = [ cfg.export.to ];
            };
          }
          // lib.optionalAttrs (cfg.export.to != null) {
            unitConfig.ConditionPathIsMountPoint = cfg.export.to;
          };
        })
      ]
      ++ lib.optional historyHere (job {
        name = "backfill";
        enable = cfg.backfill.requests != [ ];
        inherit (cfg.backfill) onCalendar;
        description = "tinytrader scheduled backfills: alpaca-history runs, origin=scheduled (decision 0033)";
        exec = "${pkgs.writeShellScript "tinytrader-backfill" ''
          set -eu
          status=0
          ${lib.concatMapStrings (
            r:
            let
              body = builtins.toJSON (r // { origin = "scheduled"; });
            in
            ''
              if ! ${lib.getExe pkgs.curl} -fsS --max-time 30 -H 'Content-Type: application/json' \
                  -d ${lib.escapeShellArg body} http://${listen "alpaca-history"}/runs >/dev/null; then
                echo "backfill: alpaca-history refused ${lib.escapeShellArg body}" >&2
                status=1
              fi
            ''
          ) cfg.backfill.requests}
          exit "$status"
        ''}";
        extra = {
          after = [ "tinytrader-alpaca-history.service" ];
          serviceConfig.RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
        };
      })
    );
  };
}
