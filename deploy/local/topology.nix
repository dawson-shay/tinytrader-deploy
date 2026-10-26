# The console's topology file: the site's topology.json (written by hand:
# panels, bundles, edges, links) with the placement map layered in from its
# inventory, so the graph draws each service on its host
# (docs/decisions/0005). Plain Nix, no inputs, so scripts can build it fast:
#   import ./deploy/local/topology.nix {
#     inventory = ./my-site/inventory.nix;
#     overlay = ./my-site/deploy/local/topology.json;
#   }
# (scripts: stack_eval, scripts/lib/site.sh)
# It is also a deployment's `topology` package. `inventory` carries the
# whole inventory, services included, but its `deployment` settings (the
# role modules' own, not the console's).
#
# The addresses in it are the console's, from its host (endpoints.nix,
# docs/decisions/0008): each native service's observe URL, each host's
# node_exporter, and the notebook link (a browser's, on the console's host).
#   inventory  the inventory, or the path of the file holding it
#   overlay    the topology.json overlay, or its path (null: none)
{
  inventory,
  overlay ? null,
  ...
}:
let
  load = x: if builtins.isAttrs x then x else import x;
  inventory' = removeAttrs (load inventory) [ "deployment" ];
  overlay' =
    if overlay == null then
      { }
    else if builtins.isAttrs overlay then
      overlay
    else
      builtins.fromJSON (builtins.readFile overlay);
in
let
  inventory = inventory';
  overlay = overlay';
  endpoints = import ./endpoints.nix { inherit inventory; };
  consoleHost = inventory.services.console.host;
  # host:port of a service, as the console (or a browser beside it) reaches it.
  from =
    runtime: to:
    endpoints.address {
      from = consoleHost;
      inherit runtime to;
    };

  services = builtins.mapAttrs (
    _: s:
    {
      dataRoots = [ ];
      colocateWith = [ ];
      secrets = [ ];
    }
    // s
  ) inventory.services;
  # Hosts still planned (the NAS) aren't drawn; their services stay in
  # `inventory`. Nor are host agents (`perHost`: the monitor, node_exporter),
  # which aren't parts of the graph.
  names = builtins.filter (
    n: !(services.${n} ? perHost) && (inventory.hosts.${services.${n}.host}.status or "") != "planned"
  ) (builtins.attrNames services);
  byId =
    list:
    builtins.listToAttrs (
      map (e: {
        name = e.id;
        value = e;
      }) list
    );
  unique = builtins.foldl' (acc: x: if builtins.elem x acc then acc else acc ++ [ x ]) [ ];

  # Hosts that run something, described by what they run; topology.json's
  # entries for them (an exporter, say) are layered over.
  overlayHosts = byId (overlay.hosts or [ ]);
  hostIds = unique (map (n: services.${n}.host) names);
  hosts = map (
    h:
    let
      runtimes = unique (
        map (n: services.${n}.runtime) (builtins.filter (n: services.${n}.host == h) names)
      );
    in
    {
      id = h;
      label = h;
      sub = builtins.concatStringsSep ", " runtimes;
    }
    // (overlayHosts.${h} or { })
    # Its node_exporter, where it runs one.
    // (
      if builtins.hasAttr h (inventory.services.node-exporter.perHost or { }) then
        {
          exporter = "http://${
            endpoints.address {
              from = consoleHost;
              runtime = "compose";
              to = "node-exporter";
              on = h;
            }
          }/metrics";
        }
      else
        { }
    )
  ) hostIds;

  # Each service's host and runtime; topology.json's entries (an observe URL)
  # are kept, and services it alone lists keep theirs.
  overlayServices = byId (overlay.services or [ ]);
  placed = map (
    n:
    {
      id = n;
      inherit (services.${n}) host runtime;
    }
    # A native service's endpoints (a container's come from its labels): its
    # `http` port, or a relay's `observe` port (the OPRA relays, native:
    # decision 0013).
    // (
      let
        ports = services.${n}.ports or { };
        port =
          if ports ? http then
            "http"
          else if ports ? observe then
            "observe"
          else
            null;
      in
      if services.${n}.runtime != "compose" && port != null then
        {
          observe = "http://${
            endpoints.address {
              from = consoleHost;
              runtime = "compose";
              to = n;
              inherit port;
            }
          }";
        }
      else
        { }
    )
    // removeAttrs (overlayServices.${n} or { }) [ "host" ]
  ) names;
  extra = builtins.filter (s: !(services ? ${s.id})) (overlay.services or [ ]);
in
overlay
// {
  inherit hosts;
  # The notebook, from a browser on the console's host.
  links = (overlay.links or { }) // {
    notebook = "http://${from "browser" "research"}/lab";
  };
  services = placed ++ extra;
  inventory = inventory // {
    inherit services;
  };
}
