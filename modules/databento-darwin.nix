# The Databento key's holders on a Mac (docs/decisions/0013): databento-jobs
# and the OPRA relays, as launchd daemons run as `_ttdata`, a hidden system
# user of their own, so that nothing else on the machine can read the key:
# not your shell, not an agent's, not a container. Imported by the darwin
# role (roles/darwin.nix) where the placement map runs them natively:
#
#   imports = [ (import ./databento-darwin.nix { inherit tinytrader site; host = "my-mac"; }) ];
#
# Which of them run here is the placement map's: databento-jobs, and each
# relay-* service, placed on this host with runtime launchd. A relay's
# symbols, and whether it starts, are the inventory's
# deployment.native.<relay> (symbols, enable); the hours they capture,
# deployment.captureHours.
#
# - The key: the site's secrets/databento.yaml, encrypted to this Mac's SSH
#   host key and the recovery key only, never the operator key (the
#   inventory's secrets.hostOnly). sops-nix decrypts it as root, at activation and at
#   boot, into /run/secrets (a RAM disk): DATABENTO_API_KEY to
#   /run/secrets/databento_api_key and JOBS_APPROVE_TOKEN to
#   /run/secrets/jobs_approve_token, each owned by _ttdata, mode 0400. The
#   services read them through DATABENTO_API_KEY_FILE and
#   JOBS_APPROVE_TOKEN_FILE. Changing them: scripts/databento-key.
# - databento-jobs' store write token: the site's secrets/store.env (also the host's),
#   decrypted the same way into /run/secrets/tinytrader-store.env (0400,
#   _ttdata) and passed as JOBS_STORE_TOKEN to its process only.
# - Ports and addresses are the inventory's: each listens on 127.0.0.1 at its inventory
#   ports; containers reach it as host.docker.internal, other hosts through
#   `tailscale serve`.
# - Logs: /Library/Logs/tinytrader-data/<name>.log (readable by you; the
#   directory is root's, so nobody but root can swap a file in it).
# - databento-jobs' ledger: /var/lib/tinytrader/databento-jobs/submissions.jsonl
#   (copied from wherever it ran before: docs/operations.md, The Databento key).
#   It won't start without one, so no purchase is ever made without the
#   ledger of the earlier ones. The nightly backup copies the directory.
# - Never two Databento sessions on one stream: each refuses to start while
#   something already listens on its ports (the container it replaces), and
#   tries again a minute later.
#
# tinytrader's darwin module runs a daemon as the primary user; the user, the
# group and the log paths are overridden here (a `user` option there would
# replace that).
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
  packages = tinytrader.packages.${pkgs.stdenv.hostPlatform.system};
  user = "_ttdata";
  id = 534; # beside nix-darwin's _github-runner (533)
  logs = "/Library/Logs/tinytrader-data";
  stateRoot = "/var/lib/tinytrader";
  jobsState = "${stateRoot}/databento-jobs";
  ledger = "${jobsState}/submissions.jsonl";
  q = lib.escapeShellArg;
  secret = name: config.sops.secrets.${name}.path;
  storeEnv = site.secret "store.env";
  storeToken = builtins.pathExists storeEnv;

  ports = name: inventory.services.${name}.ports;
  url =
    to: port:
    "http://${
      endpoints.address {
        from = host;
        runtime = "launchd";
        inherit to port;
      }
    }";
  # The capture bundle's hours (compose.yaml x-hours.options).
  optionsHours = deployment.captureHours or "09:25-16:20";

  # What every daemon here does before it runs: wait for its secrets
  # (sops-nix writes /run/secrets after launchd loads the daemons at
  # activation, and from its own daemon at boot), and refuse to start while
  # its ports are taken.
  preamble =
    {
      name,
      files,
      listen,
    }:
    ''
      umask 022
      files=(${lib.escapeShellArgs files})
      for f in "''${files[@]}"; do
        for _ in $(seq 120); do [ -r "$f" ] && break; sleep 1; done
        if [ ! -r "$f" ]; then
          echo "${name}: $f is missing or unreadable (sops-nix, as ${user}; tinytrader-deploy docs/decisions/0013)" >&2
          exit 1
        fi
      done
      ports=(${lib.concatMapStringsSep " " toString listen})
      for port in "''${ports[@]}"; do
        if (: <>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
          echo "${name}: 127.0.0.1:$port is taken (its old container? scripts/deploy --remove ${name}): not starting, so its Databento session never runs twice; again in a minute" >&2
          sleep 50
          exit 1
        fi
      done
    '';

  # The services placed here natively.
  placedHere = lib.filterAttrs (
    _: s: (s.host or null) == host && (s.runtime or null) == "launchd"
  ) inventory.services;
  # The relays: one Databento session each, with the inventory's settings.
  relays = lib.mapAttrs (
    name: _:
    {
      enable = true;
    }
    // (deployment.native.${name} or { })
  ) (lib.filterAttrs (name: _: lib.hasPrefix "relay-" name) placedHere);
  hasJobs = placedHere ? databento-jobs;
  relay =
    name: r:
    let
      p = ports name;
    in
    {
      inherit (r) enable;
      launchd = "daemon";
      package = pkgs.writeShellApplication {
        name = "${name}-${host}";
        text = ''
          ${preamble {
            inherit name;
            files = [ (secret "databento_api_key") ];
            listen = [
              p.stream
              p.observe
            ];
          }}
          exec ${lib.getExe packages.relay} "$@"
        '';
      };
      observe.port = p.observe;
      environment = {
        HOME = "/var/empty";
        USER = user;
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
        DATABENTO_API_KEY_FILE = secret "databento_api_key";
        RELAY_SYMBOLS = r.symbols;
        RELAY_LISTEN = "127.0.0.1:${toString p.stream}";
        RELAY_OBSERVE_LISTEN = "127.0.0.1:${toString p.observe}";
        RELAY_HOURS = optionsHours;
        RELAY_CALENDAR = "${url "accounts" "http"}/calendar";
      };
    };

  # Databento batch jobs, as compose.yaml ran them.
  jobs = {
    enable = true;
    launchd = "daemon";
    package = pkgs.writeShellApplication {
      name = "databento-jobs-${host}";
      text = ''
        ${preamble {
          name = "databento-jobs";
          files = [
            (secret "databento_api_key")
            (secret "jobs_approve_token")
          ]
          ++ lib.optional storeToken (secret "tinytrader-store.env");
          listen = [ (ports "databento-jobs").http ];
        }}
        if [ ! -f ${q ledger} ]; then
          echo "databento-jobs: no ledger at ${ledger}: copy it from the jobs-data volume first (${site.name} docs/operations.md, The Databento key); not starting, so nothing is bought without the record of what was" >&2
          sleep 50
          exit 1
        fi
        ${lib.optionalString storeToken ''
          # The store's write token, read as data (not sourced), into this
          # process only.
          while IFS='=' read -r k v || [ -n "$k" ]; do
            [ "$k" = STORE_WRITE_TOKEN ] && export JOBS_STORE_TOKEN="$v"
          done < ${q (secret "tinytrader-store.env")}
          [ -n "''${JOBS_STORE_TOKEN:-}" ] || { echo "databento-jobs: secrets/store.env has no STORE_WRITE_TOKEN" >&2; exit 1; }
        ''}
        exec ${lib.getExe packages.databento-jobs} "$@"
      '';
    };
    observe.port = (ports "databento-jobs").http;
    environment = {
      HOME = "/var/empty";
      USER = user;
      PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
      DATABENTO_API_KEY_FILE = secret "databento_api_key";
      # The purchase approval token (tinytrader decision 0019, PR #44); a
      # databento-jobs without it ignores it.
      JOBS_APPROVE_TOKEN_FILE = secret "jobs_approve_token";
      JOBS_LISTEN = "127.0.0.1:${toString (ports "databento-jobs").http}";
      JOBS_STORE = url "store" "http";
      # Background work (tinytrader decision 0011): off the network while any
      # member of the OPRA capture bundle is live, and no download started
      # that couldn't finish before its hours begin.
      JOBS_YIELD_TO = lib.concatMapStringsSep ";" (r: "${r}=${url r "observe"}") (lib.attrNames relays);
      JOBS_CAPTURE_HOURS = optionsHours;
      JOBS_CALENDAR = "${url "accounts" "http"}/calendar";
      # Every submission is written here before it is sent.
      JOBS_LEDGER = ledger;
    };
  };

  services = lib.mapAttrs relay relays // lib.optionalAttrs hasJobs {
    databento-jobs = jobs;
  };
  enabled = lib.attrNames (lib.filterAttrs (_: s: s.enable) services);
  owned = {
    owner = user;
    group = user;
    mode = "0400";
  };
in
{
  users.users.${user} = {
    uid = id;
    gid = id;
    description = "tinytrader Databento services";
    home = "/var/empty";
    createHome = false;
    shell = "/usr/bin/false";
    isHidden = true;
  };
  users.groups.${user} = {
    gid = id;
    description = "tinytrader Databento services";
  };
  users.knownUsers = [ user ];
  users.knownGroups = [ user ];

  # Needs sops-nix's darwin module, which the machine's configuration
  # imports (the machines repository's flake, with sops.age.sshKeyPaths set to the SSH
  # host key).
  sops.secrets = {
    databento_api_key = owned // {
      sopsFile = site.secret "databento.yaml";
      format = "yaml";
      key = "DATABENTO_API_KEY";
    };
    jobs_approve_token = owned // {
      sopsFile = site.secret "databento.yaml";
      format = "yaml";
      key = "JOBS_APPROVE_TOKEN";
    };
  }
  // lib.optionalAttrs storeToken {
    "tinytrader-store.env" = owned // {
      sopsFile = storeEnv;
      format = "dotenv";
    };
  };

  tinytrader.services = services;

  launchd.daemons = lib.mkMerge [
    # As _ttdata, logging where only root can add or swap a file.
    (lib.genAttrs (map (n: "tinytrader-${n}") enabled) (label: {
      serviceConfig = {
        UserName = lib.mkForce user;
        GroupName = lib.mkForce user;
        StandardOutPath = lib.mkForce "${logs}/${lib.removePrefix "tinytrader-" label}.log";
        StandardErrorPath = lib.mkForce "${logs}/${lib.removePrefix "tinytrader-" label}.log";
      };
    }))
    # The ledger in the nightly backup.
    (lib.mkIf config.tinytrader-deploy.backup.enable {
      tinytrader-backup.serviceConfig.EnvironmentVariables.BACKUP_EXTRA_PATHS = jobsState;
    })
  ];

  assertions = map (n: {
    assertion = config.launchd.daemons."tinytrader-${n}".serviceConfig.UserName == user;
    message = "tinytrader-deploy modules/databento-darwin.nix: ${n} must run as ${user} (decision 0013)";
  }) enabled;

  # Before launchd loads the daemons (the users exist by then): the log
  # directory and files, and the ledger's directory.
  system.activationScripts.launchd.text = lib.mkOrder 750 ''
    install -d -m 755 -o root -g wheel ${q logs}
    ${lib.concatMapStrings (n: ''
      touch ${q "${logs}/${n}.log"}
      chown ${user}:${user} ${q "${logs}/${n}.log"}
      chmod 644 ${q "${logs}/${n}.log"}
    '') enabled}
    install -d -m 755 -o root -g wheel ${q stateRoot}
    install -d -m 755 -o ${user} -g ${user} ${q jobsState}
  '';

  environment.etc."newsyslog.d/tinytrader-data.conf".text = ''
    # logfile                       owner:group          mode count size(KB) when flags
    ${logs}/*.log  ${user}:${user}  644  7     10240    *    GJN
  '';
}
