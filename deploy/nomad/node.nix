# A host's Nomad settings (modules/nomad.nix's options), from the site: its
# policy (inventory.nix deployment.nomad), the placement map and the
# addresses (deploy/local/endpoints.nix). The role modules use it where the
# inventory places `nomad` (perHost):
#
#   tinytrader-deploy.nomad = import ../deploy/nomad/node.nix {
#     inherit site host; runtime = "launchd";
#     siteCheckout = ...; srcCheckout = ...; dockerSocket = ...;
#   };
#
# The policy, as data (docs/batch-jobs.md):
#
#   deployment.nomad = {
#     datacenter = "dc1";       # optional
#     server = "<host>";        # the inventory host that runs the server (and is a client too)
#     yieldTo = [ "relay-a" ];  # services background work on a feed host yields to
#                               # (their observe port's /health)
#     nodes.<host> = {
#       pool = "default";       # its node pool (optional)
#       memoryMB = 4096;        # what jobs may reserve there: a budget, not its RAM
#       cpuMHz = 8000;          # cores x 1000 (Nomad can't read Apple Silicon's clock)
#       feed = false;           # it hosts the live feed: background work there yields
#       builds = false;         # host builds and tests of tinytrader may run there
#       cleanRoots = [ ];       # where disk-hygiene deletes idle Rust target/ folders
#                               # (relative to the home, or absolute; never /Volumes)
#     };
#   };
#
# The node metadata is what the site's job specs (deploy/nomad/jobs/) read:
#   site_checkout   the site checkout on this host (a job mounts research/ from it)
#   tinytrader_src  the tinytrader checkout, where builds = true
#   docker_network  the Compose project's network (<deployment.name>_default)
#   tt_console      the console's address from a container here
#   gate_calendar   the market calendar, from the host itself (the gate runs natively)
#   gate_yield_to   name=url;... of the yieldTo services' health, on a feed host
#   feed            "true" or "false"
#   disk_hygiene_roots  cleanRoots, ":"-separated (empty: none)
#   auto_deploy_lock    auto-deploy's lock, relative to the home (scripts/auto-deploy)
{
  site,
  host,
  runtime,
  # This host's site checkout.
  siteCheckout,
  # Its tinytrader checkout, for host builds (null: none here).
  srcCheckout ? null,
  dockerSocket ? null,
}:
let
  inherit (site) inventory endpoints;
  cluster = inventory.deployment.nomad;
  node = {
    pool = "default";
    feed = false;
    builds = false;
    cleanRoots = [ ];
    memoryMB = null;
    cpuMHz = null;
  }
  // cluster.nodes.${host};
  native =
    to: port:
    "http://${
      endpoints.address {
        from = host;
        inherit runtime to port;
      }
    }";
  consoleHere = (inventory.services.console.host or null) == host;
  container = endpoints.compose.${host} or { };
  # The same on every host.
  httpsConsole = (builtins.head (builtins.attrValues endpoints.compose)).TT_HTTPS_URL_CONSOLE or "";
in
{
  enable = true;
  datacenter = cluster.datacenter or "dc1";
  server.enable = host == cluster.server;
  servers = [
    (endpoints.address {
      from = host;
      inherit runtime;
      to = "nomad";
      port = "rpc";
      on = cluster.server;
    })
  ];
  ports = {
    inherit (inventory.services.nomad.ports) http rpc;
  };
  client = {
    enable = true;
    nodePool = node.pool;
    inherit (node) memoryMB cpuMHz;
    meta = {
      feed = if node.feed then "true" else "false";
      disk_hygiene_roots = builtins.concatStringsSep ":" node.cleanRoots;
      auto_deploy_lock = ".local/state/${site.name}/auto-deploy.lock";
      site_checkout = siteCheckout;
      docker_network = "${site.name}_default";
      # Research's reads of the console: by name on its host, else its
      # HTTPS address (its raw port is localOnly).
      tt_console = if consoleHere then container.TT_URL_CONSOLE or "" else httpsConsole;
    }
    // (
      if inventory.services ? accounts then { gate_calendar = "${native "accounts" null}/calendar"; } else { }
    )
    // {
      gate_yield_to =
        if node.feed then
          builtins.concatStringsSep ";" (map (r: "${r}=${native r "observe"}/health") (cluster.yieldTo or [ ]))
        else
          "";
    }
    // (if node.builds && srcCheckout != null then { tinytrader_src = srcCheckout; } else { });
  }
  # Unset: the platform module's default (NixOS's Docker; none on a Mac).
  // (if dockerSocket != null then { inherit dockerSocket; } else { });
}
