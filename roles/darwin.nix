# A Mac's part in a deployment, as a role its machine configuration imports
# (a machines repository's darwinConfigurations.<mac>): what of tinytrader
# runs on it natively, from the site's inventory. lib.mkDeployment makes one
# for each Mac something is placed on, as darwinModules.<host>:
#
#   darwinConfigurations.my-mac = nix-darwin.lib.darwinSystem {
#     modules = [ sops-nix.darwinModules.sops ./my-mac.nix my-site.darwinModules.my-mac ];
#   };
#
# The machine's own configuration owns the machine (users, shells, Tailscale,
# the Docker engine); this says what runs on it, following the placement map
# (docs/decisions/0005):
#   watch, node-exporter   the monitor and node_exporter (modules/watch-darwin.nix), where `watch` runs
#   runner                 a CI runner for the site (modules/runner-darwin.nix), where `runner` runs
#   backup                 the nightly backup (modules/backup-darwin.nix): sending where `backup`
#                          runs, receiving when the machine sets tinytrader-deploy.backup.receive
#   auto-deploy            off until the machine sets tinytrader-deploy.autoDeploy.enable
#                          (modules/auto-deploy-darwin.nix)
#   databento-jobs, relay-*  the Databento key's holders, where placed with runtime launchd
#                          (modules/databento-darwin.nix; needs sops-nix's darwin module)
#   store, alpaca-history  where placed with runtime launchd (modules/store-darwin.nix)
#   queue-host-runner      where placed (off unless deployment.native.queue-host-runner.enable)
#   nomad                  the batch scheduler's agent, where placed (modules/nomad-darwin.nix;
#                          the policy is deployment.nomad, deploy/nomad/node.nix). The machine
#                          must allow the unfree nomad package by name
# Containers come from the site's compose.yaml (scripts/deploy, scripts/local-up.sh).
#
# The Docker engine's socket is the inventory's deployment.hosts.<host>.dockerSocket
# (relative to the primary user's home, or absolute; default Colima's), or
# the dockerSocket argument (a function of the home).
{
  tinytrader,
  site,
  host,
  dockerSocket ? null,
}:
{ config, lib, ... }:
let
  inherit (site) inventory;
  deployment = inventory.deployment or { };
  native = deployment.native or { };
  settings = (deployment.hosts or { }).${host} or { };
  socket =
    if dockerSocket != null then
      dockerSocket
    else
      let
        s = settings.dockerSocket or ".colima/default/docker.sock";
      in
      home: if lib.hasPrefix "/" s then s else "${home}/${s}";
  services = inventory.services;
  # A host agent (perHost) with an instance here.
  agentHere = name: ((services.${name} or { }).perHost or { }) ? ${host};
  # A service placed here natively.
  nativeHere =
    name: ((services.${name} or { }).host or null) == host && (services.${name}.runtime or null) == "launchd";
  keyHolders = lib.any (n: nativeHere n && (n == "databento-jobs" || lib.hasPrefix "relay-" n)) (
    lib.attrNames services
  );
  home = "/Users/${config.system.primaryUser}";
  # Where this Mac's native services reach the others (deploy/local/endpoints.nix,
  # docs/decisions/0008).
  url =
    to:
    "http://${
      site.endpoints.address {
        from = host;
        runtime = "launchd";
        inherit to;
      }
    }";
  queueRunner = native.queue-host-runner or { };
  # A path from the inventory: relative to the primary user's home, or absolute.
  fromHome = p: if lib.hasPrefix "/" p then p else "${home}/${p}";
in
{
  imports = [
    tinytrader.darwinModules.services
  ]
  # This Mac's monitor and node_exporter (docs/decisions/0006).
  ++ lib.optional (agentHere "watch") (
    import ../modules/watch-darwin.nix {
      inherit tinytrader site host;
      dockerSocket = socket;
    }
  )
  # CI for the site: a GitHub Actions runner (docs/ci.md).
  ++ lib.optional (agentHere "runner") (import ../modules/runner-darwin.nix { inherit site host; })
  ++ [
    # The nightly backup where the placement map runs it, and receiving
    # other hosts' off-host copies when the machine's config sets
    # tinytrader-deploy.backup.receive (docs/operations.md "Backups").
    (import ../modules/backup-darwin.nix {
      inherit site host;
      dockerSocket = socket;
    })
    # Deploying what is merged to main, every 5 minutes, once the machine's
    # config sets tinytrader-deploy.autoDeploy.enable (docs/decisions/0011).
    (import ../modules/auto-deploy-darwin.nix { dockerSocket = socket; })
  ]
  # databento-jobs and the OPRA relays, the only readers of the Databento
  # key (docs/decisions/0013).
  ++ lib.optional keyHolders (import ../modules/databento-darwin.nix { inherit tinytrader site host; })
  # The store and alpaca-history beside it.
  ++ lib.optional (nativeHere "store" || nativeHere "alpaca-history") (
    import ../modules/store-darwin.nix { inherit tinytrader site host; }
  )
  # The batch scheduler (docs/batch-jobs.md): a client, and the server where
  # deployment.nomad.server names this host.
  ++ lib.optional (agentHere "nomad") ../modules/nomad-darwin.nix;

  config = lib.mkMerge [
    {
      # The site's deploy checkout is named after the deployment (docs/decisions/0012).
      tinytrader-deploy.checkouts.site = lib.mkDefault "${config.tinytrader-deploy.deployRoot}/${site.name}";
    }

    # The batch scheduler's settings here. Research jobs mount research/
    # from the site checkout: the deploy checkout, or
    # deployment.hosts.<host>.siteCheckout where there is none (relative to
    # the home, or absolute).
    (lib.mkIf (agentHere "nomad") {
      tinytrader-deploy.nomad = import ../deploy/nomad/node.nix {
        inherit site host;
        runtime = "launchd";
        siteCheckout =
          if settings ? siteCheckout then fromHome settings.siteCheckout else config.tinytrader-deploy.checkouts.site;
        srcCheckout = config.tinytrader-deploy.checkouts.tinytrader;
        dockerSocket = socket home;
      };
    })

    # The job queue's host runner (tinytrader decision 0012): runs the
    # queue's host jobs (builds, tests; the site's queue-templates.yaml) on
    # this Mac, one at a time, under taskpolicy -b. Off unless
    # deployment.native.queue-host-runner.enable (the tinytrader input must
    # have the queue package).
    (lib.mkIf (nativeHere "queue-host-runner") {
      tinytrader.services.queue-host-runner = {
        enable = queueRunner.enable or false;
        package = tinytrader.packages.aarch64-darwin.queue;
        args = [ "host-runner" ];
        environment = {
          QUEUE_URL = url "queue";
          # launchd's PATH is minimal: the Nix-managed tools and the system's.
          PATH =
            queueRunner.path
              or "${home}/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          HOME = home;
        };
      };
    })
  ];
}
