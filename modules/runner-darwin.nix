# CI on this Mac: a GitHub Actions self-hosted runner for the site's own
# repository only (docs/ci.md), from nix-darwin's services.github-runners and
# nixpkgs' github-runner. Imported by the darwin role (roles/darwin.nix)
# where the placement map runs `runner`, with the inventory's
# deployment.native.runner:
#   url   the repository it serves (required; never a public one: anyone's
#         pull request would run on this Mac)
#   name  its name on GitHub, and its extra label (default: the host)
#   attr  its services.github-runners name (default: the deployment's name)
#
# - It runs as `_github-runner` (uid 533), an unprivileged user nix-darwin
#   creates for it: no admin, no sudo, no age key, so the workflow can't
#   decrypt secrets/ and must not need to.
# - Labels: self-hosted, macOS, ARM64 (the runner's own) and its name.
# - The work directory is emptied after every job (a job-completed hook) and
#   on every start (the module); caches are kept under it, capped in size.
# - Registration needs a token (the site's secrets/runner.env, GITHUB_RUNNER_TOKEN; how
#   to make it is in docs/ci.md). Until that file is committed the runner is
#   off. Activation decrypts it with the operator key only while the runner
#   isn't registered yet, into a file only the runner user can read, which
#   is deleted as soon as registration succeeds: after that the runner
#   authenticates with its own credentials, not the token.
{ site, host }:
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  settings = site.inventory.deployment.native.runner or { };
  attr = settings.attr or site.name;
  name = settings.name or host; # the runner's name on GitHub
  user = "_github-runner";
  repo = settings.url or (throw "tinytrader-deploy modules/runner-darwin.nix: the inventory's deployment.native.runner.url (the repository the runner serves) is unset");
  secret = site.secret "runner.env";
  tokenKey = "GITHUB_RUNNER_TOKEN";
  operatorKey = "/Users/${config.system.primaryUser}/Library/Application Support/sops/age/keys.txt";

  stateDir = "/var/lib/github-runners/${name}"; # its registration (the module's)
  workDir = "/private/var/lib/github-runners/_work/${name}"; # the module's default
  tokenFile = "${stateDir}/.registration-token";
  cacheDir = "${workDir}/_cache";
  cacheMaxMiB = 2048;

  # nix-darwin's module asserts nix.enable and puts config.nix.package on the
  # runner's PATH; this Mac's Nix is Determinate's (nix.enable = false in the
  # machines repo), so use the module with those two lines changed to take
  # Nix from the default profile instead (launchd's `path` takes a string as
  # the directory itself). Fails loudly if upstream changes.
  upstream = "${modulesPath}/services/github-runner";
  patch =
    src:
    lib.foldl' (
      s:
      { from, to }:
      if lib.length (lib.splitString from s) == 2 then
        lib.replaceStrings [ from ] [ to ] s
      else
        throw "tinytrader-deploy modules/runner-darwin.nix: nix-darwin's github-runner/service.nix changed (`${from}`); update the patch"
    ) src
  ;
  service = builtins.toFile "github-runner-service.nix" (
    patch (builtins.readFile "${upstream}/service.nix") [
      {
        from = "assertion = config.nix.enable;";
        to = "assertion = true; # nix.enable or Determinate Nix (tinytrader-deploy modules/runner-darwin.nix)";
      }
      {
        from = "config.nix.package\n";
        to = ''(if config.nix.enable then config.nix.package else "/nix/var/nix/profiles/default/bin")'' + "\n";
      }
    ]
  );

  # After each job: empty the work directory but the runner's own (_temp,
  # _actions) and the caches, cap the caches, and prune the runner's
  # diagnostic logs.
  # The runner only runs hooks whose names end in .sh (.ps1, .js).
  jobCompleted = pkgs.writeShellScript "github-runner-${name}-job-completed.sh" ''
    set -u
    work=${lib.escapeShellArg workDir}
    for d in "$work"/* "$work"/.[!.]*; do
      [ -e "$d" ] || continue
      case "''${d##*/}" in _temp | _actions | _cache) continue ;; esac
      chmod -R u+w "$d" 2>/dev/null
      rm -rf "$d"
    done
    used=$(du -sm ${lib.escapeShellArg cacheDir} 2>/dev/null | cut -f1)
    if [ "''${used:-0}" -gt ${toString cacheMaxMiB} ]; then
      echo "caches at ''${used} MiB (over ${toString cacheMaxMiB}): emptied"
      chmod -R u+w ${lib.escapeShellArg cacheDir} 2>/dev/null
      rm -rf ${lib.escapeShellArg cacheDir}
    fi
    find ${lib.escapeShellArg stateDir}/_diag -type f -mtime +7 -delete 2>/dev/null
    exit 0
  '';
  jobStarted = pkgs.writeShellScript "github-runner-${name}-job-started.sh" ''
    mkdir -p ${lib.escapeShellArg cacheDir}/{xdg,cargo}
  '';
in
{
  disabledModules = [ "services/github-runner" ];
  imports = [
    "${upstream}/options.nix"
    service
  ];

  services.github-runners.${attr} = {
    # Off until the token's encrypted file is committed (docs/ci.md).
    enable = builtins.pathExists secret;
    url = repo;
    inherit name tokenFile;
    extraLabels = [ name ];
    replace = true; # re-registering under the same name replaces the old one
    # One job at a time, the work directory emptied after each. Not the
    # module's `ephemeral` (re-registers after every job), which would keep
    # the token on disk for good.
    ephemeral = false;
    # user and group null: nix-darwin's own `_github-runner`.
    extraPackages = with pkgs; [
      gnused
      findutils
      gnugrep
    ];
    # The module means to keep a non-ephemeral runner alive, but its KeepAlive
    # comes out empty (`{ ... } // mkIf false ...`): restart it whenever it exits.
    serviceOverrides.KeepAlive = lib.mkDefault true;
    extraEnvironment = {
      ACTIONS_RUNNER_HOOK_JOB_STARTED = "${jobStarted}";
      ACTIONS_RUNNER_HOOK_JOB_COMPLETED = "${jobCompleted}";
      # Caches under the work directory: capped after each job, gone on restart.
      XDG_CACHE_HOME = "${cacheDir}/xdg";
      CARGO_HOME = "${cacheDir}/cargo";
    };
  };

  # Before nix-darwin loads the daemon (the module's own setup runs first,
  # mkBefore): while unregistered, put the token where the runner reads it;
  # once registered, make sure no token is left.
  system.activationScripts.launchd.text = lib.mkIf config.services.github-runners.${attr}.enable (
    lib.mkOrder 750 ''
      if [ -f ${lib.escapeShellArg stateDir}/.runner ]; then
        rm -f ${lib.escapeShellArg tokenFile}
      elif env="$(SOPS_AGE_KEY_FILE=${lib.escapeShellArg operatorKey} ${lib.getExe pkgs.sops} decrypt --input-type dotenv --output-type dotenv ${secret} 2>/dev/null)" \
        && token="$(printf '%s\n' "$env" | ${lib.getExe pkgs.gnused} -n 's/^${tokenKey}=//p' | ${pkgs.coreutils}/bin/head -n1)" \
        && [ -n "$token" ]; then
        (umask 077 && printf '%s' "$token" > ${lib.escapeShellArg tokenFile})
        /usr/sbin/chown ${user}:${user} ${lib.escapeShellArg tokenFile}
        echo >&2 "GitHub runner ${name}: registering with the token from secrets/runner.env"
      else
        echo >&2 "GitHub runner ${name}: not registered, and secrets/runner.env has no ${tokenKey} this Mac can decrypt (operator key?); it waits (tinytrader-deploy docs/ci.md)"
      fi
      unset env token
    ''
  );

  # The daemon's script, before the module's: once registered, the token goes;
  # unregistered and without a token, wait quietly for one rather than fail
  # and restart every 30 seconds. While registering, delete the token as soon
  # as the registration is written.
  launchd.daemons."github-runner-${attr}" = lib.mkIf config.services.github-runners.${attr}.enable {
    script = lib.mkBefore ''
      state=${lib.escapeShellArg stateDir}
      token=${lib.escapeShellArg tokenFile}
      if [ -f "$state/.runner" ]; then
        rm -f "$token"
      else
        if [ ! -s "$token" ]; then
          echo "not registered and no token (tinytrader-deploy docs/ci.md): waiting for one"
          while [ ! -s "$token" ] && [ ! -f "$state/.runner" ]; do sleep 60; done
        fi
        (while [ ! -f "$state/.runner" ]; do sleep 2; done; rm -f "$token") &
      fi
    '';
  };
}
