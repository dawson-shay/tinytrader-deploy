# The placement map's checks (docs/decisions/0005): the site's inventory.nix
# `services` against compose.yaml, the role modules, the data roots and the
# secrets recipients. Each check is a derivation that fails with the reasons.
{
  pkgs,
  inventory,
  # Each role module's declared services, by inventory host:
  #   { my-mac = config.tinytrader.services; ... }
  roles,
  compose,
  # deploy/local/endpoints.nix, evaluated: each service's address from each
  # host (docs/decisions/0008).
  endpoints,
}:
let
  inherit (pkgs) lib;
  services = lib.mapAttrs (
    _: s:
    {
      dataRoots = [ ];
      colocateWith = [ ];
      secrets = [ ];
      ports = { };
      uses = [ ];
    }
    // s
  ) inventory.services;
  # Where each service runs: one { host, runtime }, or one per host for a
  # host agent (`perHost`).
  instances =
    s:
    if s ? perHost then
      lib.mapAttrsToList (host: runtime: { inherit host runtime; }) s.perHost
    else
      [ { inherit (s) host runtime; } ];
  hostsOf = name: if services ? ${name} then map (i: i.host) (instances services.${name}) else [ ];
  onHost = name: host: lib.elem host (hostsOf name);
  where = name: lib.concatStringsSep ", " (hostsOf name);
  # Each placed instance of each service, with the service's other fields.
  placedOn = lib.concatLists (
    lib.mapAttrsToList (name: s: map (i: s // i // { inherit name; }) (instances s)) services
  );

  # A check that passes when `problems` is empty, else prints them and fails.
  report =
    name: problems:
    pkgs.runCommand name { } (
      if problems == [ ] then
        "touch $out"
      else
        ''
          cat >&2 <<'EOF'
          ${lib.concatMapStrings (p: "${name}: ${p}\n") problems}
          EOF
          exit 1
        ''
    );

  # Each service's host and runtime exist and fit each other.
  runtimeFits = {
    compose = h: (h.runtime or null) == "docker-compose";
    launchd = h: h.os == "darwin";
    systemd = h: h.os == "nixos";
  };
  placed =
    lib.concatMap (
      s:
      let
        name = s.name;
      in
      if !(inventory.hosts ? ${s.host}) then
        [ "${name}: host ${s.host} is not in inventory.nix hosts" ]
      else if !(runtimeFits ? ${s.runtime}) then
        [ "${name}: runtime ${s.runtime} is none of compose, launchd, systemd" ]
      else if !(runtimeFits.${s.runtime} inventory.hosts.${s.host}) then
        [ "${name}: runtime ${s.runtime} doesn't run on ${s.host}" ]
      else
        [ ]
    ) placedOn
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: s:
        lib.optional (s ? perHost && s ? host) "${name}: has both host and perHost"
        ++ lib.optional (
          s ? perHost && lib.elem "compose" (lib.attrValues s.perHost)
        ) "${name}: perHost services run natively (launchd or systemd), not in compose"
      ) services
    );

  dataRoots = lib.concatMap (
    s:
    let
      name = s.name;
    in
    map (
      r:
      if !(inventory.dataRoots ? ${r}) then
        "${name}: data root ${r} is not in inventory.nix dataRoots"
      else
        "${name} (on ${s.host}): data root ${r} is on ${inventory.dataRoots.${r}.host}"
    ) (lib.filter (r: (inventory.dataRoots.${r}.host or null) != s.host) s.dataRoots)
  ) placedOn;

  colocated = lib.concatMap (
    s:
    let
      name = s.name;
    in
    map (
      o:
      if hostsOf o == [ ] then
        "${name}: colocateWith ${o}, which is not in inventory.nix services"
      else
        "${name} (on ${s.host}): colocateWith ${o}, which is on ${where o}"
    ) (lib.filter (o: !(onHost o s.host)) s.colocateWith)
  ) placedOn;

  # A host can decrypt a file if it is granted it, or decrypts with the
  # operator key (decision 0004), but a hostOnly file only if granted it,
  # with a host key of its own. A hostOnly file's services never run in
  # Compose: Docker secrets are readable by anyone with Docker access
  # (decision 0013).
  hostOnly = inventory.secrets.hostOnly or [ ];
  secrets =
    lib.concatMap (
      s:
      let
        name = s.name;
      in
      lib.concatMap (
        f:
        if !(inventory.secrets.files ? ${f}) then
          [ "${name}: secrets ${f} is not in inventory.nix secrets.files" ]
        else if lib.elem f hostOnly then
          lib.optional (
            !(lib.elem s.host inventory.secrets.files.${f}) || (inventory.secrets.hosts.${s.host} or null) == null
          ) "${name} (on ${s.host}): ${f} is hostOnly, and ${s.host} isn't its recipient with a host key (secrets.files, secrets.hosts)"
          ++ lib.optional (
            s.runtime == "compose"
          ) "${name} (on ${s.host}): ${f} is hostOnly, so its services run natively, never in compose (decision 0013)"
        else if
          lib.elem s.host inventory.secrets.files.${f}
          || lib.elem s.host (inventory.secrets.operatorKeyHosts or [ ])
        then
          [ ]
        else
          [ "${name} (on ${s.host}): ${s.host} is not a recipient of ${f} (secrets.files)" ]
      ) s.secrets
    ) placedOn
    ++ map (f: "secrets.hostOnly: ${f} is not in secrets.files") (
      lib.filter (f: !(inventory.secrets.files ? ${f})) hostOnly
    );

  # Every service a role module declares is placed; an enabled one on that
  # host (unless the host is still planned: its module is written ahead).
  # Every native service placed on a host with a role module is declared there.
  native = lib.concatLists (
    lib.mapAttrsToList (
      host: declared:
      let
        planned = (inventory.hosts.${host}.status or "") == "planned";
      in
      lib.concatLists (
        lib.mapAttrsToList (
          name: svc:
          if hostsOf name == [ ] then
            [ "${name}: declared by ${host}'s role module but not in inventory.nix services" ]
          else if svc.enable && !planned && !(onHost name host) then
            [ "${name}: enabled in ${host}'s role module but placed on ${where name}" ]
          else
            [ ]
        ) declared
      )
      ++ map (s: "${s.name}: placed on ${host} (${s.runtime}) but not in its role module") (
        lib.filter (s: s.host == host && s.runtime != "compose" && !(declared ? ${s.name})) placedOn
      )
    ) roles
  );

  # Addresses (docs/decisions/0008): every use names a service and a port it
  # has; nothing on another host uses an order gateway (REAL MONEY for the
  # live one) or another localOnly service; a service named like a gateway
  # has a gateway port, so it can't slip out of monitoring.gatewayPorts; no
  # host forwards two services on one port; and every port a host forwards
  # is one the tailnet policy allows (aclPorts), never a localOnly one
  # (decision 0010).
  gatewayLike = lib.filter (n: lib.hasPrefix "order-gateway" n) (lib.attrNames services);
  addressing =
    lib.concatLists (
      lib.mapAttrsToList (
        name: us:
        lib.concatMap (
          u:
          if !(services ? ${u.to}) then
            [ "${name}: uses ${u.to}, which is not in inventory.nix services" ]
          else if u.port == null then
            [ "${name}: uses ${u.to}, which has no ports" ]
          else if !(services.${u.to}.ports ? ${u.port}) then
            [ "${name}: uses ${u.to}:${u.port}, but ${u.to} has no port ${u.port}" ]
          else
            [ ]
        ) us
      ) endpoints.usesOf
    )
    ++ map (
      u:
      "${u.client} (on ${u.host}) uses ${u.to}, which is on ${lib.concatStringsSep ", " u.serviceHosts}: "
      + "${u.to} is reached on its own host only (localOnly, or an order gateway); move them together"
    ) (lib.filter (u: lib.elem u.to endpoints.localOnly) endpoints.remote)
    # usesHttps (the console from research): each names a service published
    # over HTTPS, and never the client itself.
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: hs:
        map (
          h:
          if !(services ? ${h}) then
            "${name}: usesHttps ${h}, which is not in inventory.nix services"
          else if !(lib.elem h endpoints.httpsServices) then
            "${name}: usesHttps ${h}, which is not published over HTTPS (https = true)"
          else
            "${name}: usesHttps itself"
        ) (lib.filter (h: h == name || !(lib.elem h endpoints.httpsServices)) hs)
      ) endpoints.usesHttpsOf
    )
    ++ map (n: "${n}: an order gateway with no port in monitoring.gatewayPorts") (
      lib.filter (
        n:
        !(lib.any (p: lib.elem p inventory.monitoring.gatewayPorts) (lib.attrValues services.${n}.ports))
      ) gatewayLike
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        host: served:
        let
          ports = map (x: x.port) served;
        in
        map (p: "${host}: forwards port ${toString p} for several services (${
          lib.concatMapStringsSep ", " (x: x.service) (lib.filter (x: x.port == p) served)
        }); give one another port") (lib.unique (lib.filter (p: lib.count (q: q == p) ports > 1) ports))
      ) endpoints.serve
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        host: served:
        lib.concatMap (
          x:
          lib.optional (!(lib.elem x.port endpoints.aclPorts)) "${host}: forwards ${x.service}'s port ${toString x.port}, which the tailnet policy doesn't allow (aclPorts)"
          ++ lib.optional (lib.elem x.port endpoints.localOnlyPorts) "${host}: forwards ${x.service}'s port ${toString x.port}, a localOnly port (an order gateway's, a Docker proxy's or the console's)"
        ) served
      ) endpoints.serve
    );

  # A native service's port, as its role module declares it (observe.port),
  # is its inventory port.
  nativePorts = lib.concatLists (
    lib.mapAttrsToList (
      host: declared:
      lib.concatLists (
        lib.mapAttrsToList (
          name: svc:
          let
            want = lib.attrValues (services.${name}.ports or { });
          in
          lib.optional (
            svc.enable && services ? ${name} && (svc.observe.port or null) != null && !(lib.elem svc.observe.port want)
          ) "${name}: ${host}'s role module serves port ${toString svc.observe.port}, inventory.nix ports ${builtins.toJSON (services.${name}.ports)}"
        ) declared
      )
    ) roles
  );

  # The single-host services (host agents run natively, never in compose),
  # with what the compose check needs of their ports and addresses.
  placement = pkgs.writeText "placement.json" (
    builtins.toJSON (
      lib.mapAttrs (name: s: {
        inherit (s) host runtime ports;
        viaHost = s.viaHost or false;
        profile = s.profile or null;
        uses = endpoints.usesOf.${name};
        usesHttps = endpoints.usesHttpsOf.${name};
        # Its ports its host forwards from the tailnet (by name): all of
        # them unless it is localOnly (decision 0010).
        served = lib.unique (
          map (x: x.name) (lib.filter (x: x.service == name) (endpoints.serve.${s.host} or [ ]))
        );
      }) (lib.filterAttrs (_: s: !(s ? perHost)) services)
    )
  );
  vars = pkgs.writeText "vars.json" (builtins.toJSON endpoints.varIndex);
in
{
  placement-hosts = report "placement-hosts" placed;
  placement-data-roots = report "placement-data-roots" dataRoots;
  placement-colocation = report "placement-colocation" colocated;
  placement-secrets = report "placement-secrets" secrets;
  # No container is given the Databento key, whatever the inventory says
  # (decision 0013): compose.yaml names neither the variable nor a secret.
  placement-no-databento-key =
    pkgs.runCommand "placement-no-databento-key" { } ''
      if grep -nE 'DATABENTO_API_KEY|databento_api_key|(^|[^A-Z_])JOBS_APPROVE_TOKEN' ${compose} >&2; then
        echo "placement-no-databento-key: compose.yaml gives a container the Databento key or databento-jobs' approval token: only the native databento-jobs and OPRA relays hold them (docs/decisions/0013)" >&2
        exit 1
      fi
      touch $out
    '';
  placement-role-modules = report "placement-role-modules" (native ++ nativePorts);
  placement-endpoints = report "placement-endpoints" addressing;

  # compose.yaml interpolates on every host that runs containers, with that
  # host's addresses (scripts/placement endpoints): every TT_* it names with
  # `:?` is made there.
  placement-compose-endpoints =
    pkgs.runCommand "placement-compose-endpoints" { nativeBuildInputs = [ pkgs.docker-compose ]; }
      (
        lib.concatStrings (
          lib.mapAttrsToList (host: vars: ''
            if ! env -i HOME="$TMPDIR" PATH="$PATH" ${
              lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") vars)
            } TINYTRADER_SITE=/site TINYTRADER_DEPLOY=/deploy TINYTRADER_SRC=/src TINYTRADER_TOPOLOGY=/topology.json \
                docker-compose -f ${compose} --profile idle-relays config --quiet; then
              echo "placement-compose-endpoints: compose.yaml doesn't interpolate on ${host}" >&2
              exit 1
            fi
          '') endpoints.compose
        )
        + "touch $out\n"
      );

  # compose.yaml's services are exactly the inventory's compose services,
  # each depends_on target shares its host, and each Compose profile is the
  # inventory's `profile` (the monitor expects only default-profile services).
  # Ports and addresses (docs/decisions/0008): each service publishes only
  # its inventory ports, on 127.0.0.1 and at the same number; each of its
  # inventory ports appears in its definition (its listen settings), as does
  # its tinytrader.observe label's; a port its host forwards from the tailnet
  # (every port of a service that isn't localOnly) is published, as
  # tailscale serve forwards to it; and each ${TT_ADDR_*} or ${TT_URL_*} it
  # names is one endpoints.nix makes, of a service and port in its `uses`
  # (a ${TT_HTTPS_*}: of itself, or a service in its `usesHttps`).
  placement-compose =
    pkgs.runCommand "placement-compose"
      {
        nativeBuildInputs = [
          pkgs.yq-go
          pkgs.jq
        ];
      }
      ''
        yq -o=json 'explode(.) | .services' ${compose} > compose.json
        problems=$(jq -r --slurpfile p ${placement} --slurpfile v ${vars} '
          ($p[0]) as $p | ($v[0]) as $v
          | ( (keys - ($p | keys))[]
              | "\(.): in compose.yaml but not in inventory.nix services" ),
            ( . as $c | $p | to_entries[]
              | .key as $k | select(.value.runtime == "compose" and ($c | has($k) | not))
              | "\(.key): placed with runtime compose but not in compose.yaml" ),
            ( to_entries[] | .key as $s
              | (.value.depends_on // [] | if type == "object" then keys else . end)[] as $d
              | select($p[$s] and $p[$d] and $p[$s].host != $p[$d].host)
              | "\($s) (on \($p[$s].host)): depends_on \($d), which is on \($p[$d].host)" ),
            ( to_entries[] | .key as $s | select($p[$s])
              | ((.value.profiles // [])[0] // null) as $cp
              | select($cp != $p[$s].profile)
              | "\($s): compose profile \($cp // "default") but inventory.nix profile \($p[$s].profile // "default")" ),
            ( to_entries[] | .key as $s | select($p[$s]) | .value as $c
              | ($p[$s].ports | [.[]]) as $ports
              | ( ($c.ports // [])[]
                  | (if type == "object" then "\(.host_ip // ""):\(.published // ""):\(.target)" else tostring end) as $spec
                  | ($spec | split(":")) as $f
                  | if ($f | length) != 3 or $f[0] != "127.0.0.1" then
                      "\($s): publishes \($spec): publish on 127.0.0.1 only (another host reaches it through tailscale serve)"
                    elif $f[1] != $f[2] then
                      "\($s): publishes \($spec): publish each port at its own number"
                    elif ($f[2] | tonumber) as $n | ($ports | any(. == $n)) | not then
                      "\($s): publishes \($f[2]), which is not in its inventory.nix ports"
                    else empty end ),
                ( ($c | tostring) as $text
                  | $ports[] | tostring as $n
                  | select($text | test("\\b" + $n + "\\b") | not)
                  | "\($s): inventory.nix port \($n) appears nowhere in its compose.yaml definition" ),
                ( ($c.labels // {})["tinytrader.observe"] // null | select(. != null)
                  | select((tonumber) as $n | $ports | any(. == $n) | not)
                  | "\($s): tinytrader.observe \(.) is not in its inventory.nix ports" ),
                ( (if $p[$s].viaHost then ($p[$s].ports | keys) else $p[$s].served end)[] as $pn
                  | ($p[$s].ports[$pn] | tostring) as $n
                  | select([($c.ports // [])[] | tostring | select(endswith(":" + $n))] | length == 0)
                  | "\($s): reached through its host (forwarded from the tailnet, or viaHost) on port \($pn) (\($n)): publish it on 127.0.0.1:\($n):\($n)" ),
                ( [$c | .. | strings | scan("\\$\\{(TT_(?:ADDR|URL|HTTPS_NAME|HTTPS_URL)_[A-Z0-9_]+)") | .[0]] | unique[]
                  | if $v[.] == null then
                      "\($s): names ''${\(.)}, which endpoints.nix does not make"
                    elif $v[.].https then
                      $v[.] as $t
                      | select($t.service != $s and ($p[$s].usesHttps | index($t.service) | not))
                      | "\($s): names ''${\(.)} (\($t.service) over HTTPS), which is not in its inventory.nix usesHttps"
                    else
                      $v[.] as $t
                      | select([$p[$s].uses[] | select(.to == $t.service and .port == $t.port)] | length == 0)
                      | "\($s): names ''${\(.)} (\($t.service):\($t.port)), which is not in its inventory.nix uses"
                    end )
            )
        ' compose.json)
        if [ -n "$problems" ]; then
          sed 's/^/placement-compose: /' <<<"$problems" >&2
          exit 1
        fi
        touch $out
      '';
}
