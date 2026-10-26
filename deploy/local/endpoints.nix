# Where each service is reached from each host, from the site's inventory
# (its placement map, docs/decisions/0008). Plain Nix, no inputs, so scripts
# can evaluate it fast:
#   import ./deploy/local/endpoints.nix { inventory = ./my-site/inventory.nix; }
# (scripts: stack_eval, scripts/lib/site.sh). `inventory` is the inventory
# itself, or the path of the file holding it.
# It is also a deployment's `endpoints` package (endpoints.json, and one
# <host>.env per host).
#
# An address depends on where the client runs and where the service is:
#
#   client         service on the same host           on another host
#   a container    <name>:<port> (a container),       <tailnetName>.<domain>:<port>
#                  host.docker.internal:<port> (native,
#                  or a container marked viaHost)
#   native         127.0.0.1:<port>                   <tailnetName>.<domain>:<port>
#   a browser      localhost:<port>                   <tailnetName>.<domain>:<port>
#
# A service on another host is reached through `tailscale serve` there, which
# forwards the port from the tailnet to its loopback listener (`serve`
# below; scripts/tailnet-serve applies it). Nothing listens beyond loopback.
# Every port of every service is forwarded on its host, whether or not a
# client on another host uses it, except the localOnly ones: the order
# gateways' and the console's raw port, and the Docker proxies'
# (docs/decisions/0010).
#
#   compose.<host>   the variables compose.yaml is interpolated with on that
#                    host: TT_ADDR_<SERVICE>[_<PORT>] (host:port) and
#                    TT_URL_<SERVICE>[_<PORT>] (http://host:port), the port's
#                    name appended when the service has more than one;
#                    and, for a service marked `https` (published by
#                    `tailscale serve` on 443), TT_HTTPS_NAME_<SERVICE> (its
#                    host's tailnet name) and TT_HTTPS_URL_<SERVICE>
#                    (https://name), the same on every host
#   native.<host>    the same names, for native services (role modules)
#   address          { from, runtime, to, port, on } -> host:port, for Nix
#   serve.<host>     [{ service, port, name }]: what that host forwards from
#                    the tailnet: each port of each service placed on it (a
#                    host agent's on each of its hosts) but the localOnly
#                    ones, by port
#   remote           every use that crosses hosts, for the checks
#   aclPorts         every port a service may be reached on across hosts
#                    (tailscale/policy.nix): every port any serve.<host> has
#   localOnly        the services never reached from another host
#   localOnlyPorts   their ports, which `tailscale serve` never forwards
#   httpsPorts       [ 443 ] when some service is published over HTTPS
#                    (tailscale/policy.nix lets the services' hosts reach it)
#   varIndex, usesOf for checks/placement.nix
{ inventory, ... }:
let
  inventory' = inventory;
in
let
  inventory = if builtins.isAttrs inventory' then inventory' else import inventory';
  inherit (builtins)
    attrNames
    concatLists
    concatMap
    elem
    filter
    head
    length
    listToAttrs
    mapAttrs
    replaceStrings
    split
    sort
    toString
    ;
  unique = builtins.foldl' (acc: x: if elem x acc then acc else acc ++ [ x ]) [ ];
  services = mapAttrs (
    _: s:
    {
      ports = { };
      uses = [ ];
      usesHttps = [ ];
      localOnly = false;
      https = false;
    }
    // s
  ) inventory.services;

  # Where a service runs: { <host> = <runtime>; }.
  places = s: if s ? perHost then s.perHost else { ${s.host} = s.runtime; };
  hostsOf = name: attrNames (places services.${name});
  # Every host that runs something.
  serviceHosts = unique (concatMap hostsOf (attrNames services));

  # The order gateways: their ports are the ones the monitor never touches.
  gatewayPorts = inventory.monitoring.gatewayPorts;
  isGateway = name: builtins.any (p: elem p gatewayPorts) (builtins.attrValues services.${name}.ports);
  localOnly = name: services.${name}.localOnly || isGateway name;

  fqdn = host: "${inventory.hosts.${host}.tailnetName}.${inventory.tailnet.domain}";

  # host:port of `to`'s `port` for a client on `from` running as `runtime`
  # (compose, launchd, systemd, or browser).
  address =
    {
      from,
      runtime,
      to,
      port ? null,
      # For a host agent (perHost): the instance on this host. By default
      # the one on the client's host, else its first.
      on ? null,
    }:
    let
      s = services.${to};
      names = attrNames s.ports;
      p = if port == null then head names else port;
      number = toString s.ports.${p};
      all = places s;
      at = if on != null then on else if all ? ${from} then from else head (attrNames all);
      there = {
        ${at} = all.${at};
      };
      local = there ? ${from};
    in
    if !local then
      "${fqdn at}:${number}"
    else if runtime == "compose" then
      (
        if there.${from} == "compose" && !(s.viaHost or false) then
          "${to}:${number}"
        else
          "host.docker.internal:${number}"
      )
    else if runtime == "browser" then
      "localhost:${number}"
    else
      "127.0.0.1:${number}";

  varName =
    name: port:
    let
      base = replaceStrings [ "-" ] [ "_" ] (upper name);
      suffix = if port != null && length (attrNames services.${name}.ports) > 1 then "_${upper port}" else "";
    in
    "${base}${suffix}";
  # Upper case (service and port names are lower case, digits and dashes).
  upper = replaceStrings (stringToList "abcdefghijklmnopqrstuvwxyz") (
    stringToList "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  );
  stringToList = s: builtins.genList (i: builtins.substring i 1 s) (builtins.stringLength s);

  # Every (service, port) with an address.
  allPorts = concatMap (name: map (port: { inherit name port; }) (attrNames services.${name}.ports)) (
    attrNames services
  );

  # The services published over HTTPS by `tailscale serve` on their host.
  httpsServices = filter (n: services.${n}.https) (attrNames services);
  httpsVars = listToAttrs (
    concatMap (
      n:
      let
        name = fqdn (head (hostsOf n));
        v = varName n null;
      in
      [
        {
          name = "TT_HTTPS_NAME_${v}";
          value = name;
        }
        {
          name = "TT_HTTPS_URL_${v}";
          value = "https://${name}";
        }
      ]
    ) httpsServices
  );

  # The variables for clients on `host` running as `runtime`.
  vars =
    host: runtime:
    httpsVars
    // listToAttrs (
      concatMap (
        { name, port }:
        let
          a = address {
            from = host;
            inherit runtime port;
            to = name;
          };
          v = varName name port;
          # A localOnly service (a gateway) on another host can't be
          # reached: a name that never resolves (RFC 6761), so compose.yaml
          # still interpolates there. The checks fail if a client uses it.
          a' =
            if localOnly name && !(elem host (hostsOf name)) then
              "${name}.not-on-this-host.invalid:${toString services.${name}.ports.${port}}"
            else
              a;
        in
        [
          {
            name = "TT_ADDR_${v}";
            value = a';
          }
          {
            name = "TT_URL_${v}";
            value = "http://${a'}";
          }
        ]
      ) allPorts
    );

  # A `uses` entry, "name" or "name:port", as [{ to, port }].
  parseUse =
    u:
    let
      parts = filter builtins.isString (split ":" u);
      to = head parts;
    in
    if length parts > 1 then
      [
        {
          inherit to;
          port = builtins.elemAt parts 1;
        }
      ]
    else if services ? ${to} then
      map (port: { inherit to port; }) (attrNames services.${to}.ports)
    else
      [
        {
          inherit to;
          port = null;
        }
      ];

  # Every use: a client instance on a host, the service and port it uses.
  uses = concatMap (
    client:
    let
      s = services.${client};
    in
    concatLists (
      builtins.attrValues (
        mapAttrs (
          host: runtime:
          concatMap (
            u:
            map (on: u // { inherit client host runtime on; }) (instancesUsed u.to)
          ) (concatMap parseUse s.uses)
        ) (places s)
      )
    )
  ) (attrNames services);

  # The hosts that run a placed (single-host) service, and exist: those the
  # console draws (topology.nix).
  drawnHosts = unique (
    concatMap (
      n:
      let
        s = services.${n};
      in
      if s ? perHost || (inventory.hosts.${s.host}.status or "") == "planned" then [ ] else [ s.host ]
    ) (attrNames services)
  );
  # The instances a use reaches: a service's host; for a host agent, its
  # instance on each drawn host (the console reads every host's
  # node_exporter).
  instancesUsed =
    to:
    if !(services ? ${to}) then
      [ null ]
    else if services.${to} ? perHost then
      filter (h: elem h drawnHosts) (hostsOf to)
    else
      hostsOf to;

  known = u: services ? ${u.to} && u.port != null && services.${u.to}.ports ? ${u.port};
  # A use crossing hosts: the instance it reaches is on another host.
  crosses = u: known u && u.on != u.host;
  remote = map (
    u:
    u
    // {
      serviceHosts = [ u.on ];
      # A client on a host that doesn't exist yet: checked, not served.
      planned = (inventory.hosts.${u.host}.status or "") == "planned";
    }
  ) (filter crosses uses);

  # What each host forwards from the tailnet: every port of every service
  # placed on it, a client on another host using it or not, but never a
  # localOnly one (decision 0010). Sorted by port.
  serve = listToAttrs (
    map (host: {
      name = host;
      value = sort (a: b: a.port < b.port) (
        concatMap (
          { name, port }:
          if elem host (hostsOf name) && !localOnly name then
            [
              {
                service = name;
                name = port;
                port = services.${name}.ports.${port};
              }
            ]
          else
            [ ]
        ) allPorts
      );
    }) serviceHosts
  );

  # Every port a service may be reached on from another host: every port
  # but the localOnly ones, which is what the hosts forward (serve), so
  # moving a service needs no new policy.
  aclPorts = sort builtins.lessThan (
    unique (
      concatMap (name: if localOnly name then [ ] else builtins.attrValues services.${name}.ports) (
        attrNames services
      )
    )
  );
  # Each variable's service and port, for the checks (an HTTPS one's port is
  # null, and `https` true).
  varIndex =
    listToAttrs (
      concatMap (
        n:
        map
          (kind: {
            name = "TT_HTTPS_${kind}_${varName n null}";
            value = {
              service = n;
              port = null;
              https = true;
            };
          })
          [
            "NAME"
            "URL"
          ]
      ) httpsServices
    )
    // listToAttrs (
    concatMap (
      { name, port }:
      map
        (kind: {
          name = "TT_${kind}_${varName name port}";
          value = {
            service = name;
            inherit port;
          };
        })
        [
          "ADDR"
          "URL"
        ]
    ) allPorts
  );
  # Each service's uses, as [{ to, port }].
  usesOf = mapAttrs (_: s: concatMap parseUse s.uses) services;
in
{
  inherit
    varIndex
    usesOf
    address
    serve
    remote
    uses
    aclPorts
    gatewayPorts
    serviceHosts
    ;
  # Hosts with services, and those with a runtime for containers.
  compose = listToAttrs (
    map (host: {
      name = host;
      value = vars host "compose";
    }) (filter (h: (inventory.hosts.${h}.runtime or null) == "docker-compose") serviceHosts)
  );
  native = listToAttrs (
    map (host: {
      name = host;
      value = vars host "native";
    }) serviceHosts
  );
  localOnly = filter localOnly (attrNames services);
  localOnlyPorts = sort builtins.lessThan (
    unique (
      concatMap (n: builtins.attrValues services.${n}.ports) (filter localOnly (attrNames services))
    )
  );
  httpsPorts = if httpsServices == [ ] then [ ] else [ 443 ];
  # Each service's usesHttps, for checks/placement.nix.
  usesHttpsOf = mapAttrs (_: s: s.usesHttps) services;
  inherit httpsServices;
  fqdn = listToAttrs (
    map (h: {
      name = h;
      value = fqdn h;
    }) serviceHosts
  );
}
