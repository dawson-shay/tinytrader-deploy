# The backup's checks (inventory.nix `backup`, scripts/backup-state):
#   backup-coverage   every writable mount in compose.yaml is in the backup:
#                     a named volume (all of compose.yaml's `volumes:` are
#                     copied), the gateways' state under ~/.local/state/
#                     order-gateway, or a repository; anything else fails, so
#                     a new stateful mount can't be missed
#   backup-placement  the backup runs on every host whose containers hold state
#   backup-script     scripts/backup-state's retention, journal copy and
#                     volume list, on made-up data (no Docker)
{
  pkgs,
  inventory,
  compose,
  backupState,
}:
let
  inherit (pkgs) lib;
  services = inventory.services;
  backupHosts = lib.attrNames (services.backup.perHost or { });
  # Where the backup copies binds from (scripts/backup-state): the gateways'
  # state, and the repositories (the site, this stack, tinytrader).
  coveredBinds = [
    "$HOME/.local/state/order-gateway/"
    "$TINYTRADER_SITE/"
    "$TINYTRADER_DEPLOY/"
    "$TINYTRADER_SRC/"
  ];
in
{
  backup-coverage =
    pkgs.runCommand "backup-coverage"
      {
        nativeBuildInputs = [
          pkgs.yq-go
          pkgs.jq
        ];
      }
      ''
        yq -o=json 'explode(.)' ${compose} > compose.json
        problems=$(jq -r --argjson covered '${builtins.toJSON coveredBinds}' '
          (.volumes // {} | keys) as $named
          | .services | to_entries[] | .key as $s
          | (.value.volumes // [])[]
          # Short syntax "source:target[:mode]", with each ''${VAR...} cut to $VAR
          # first (its default may hold a colon); or the long syntax.
          | (if type == "string" then
               (gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)[^}]*\\}"; "$\(.v)") | split(":"))
               | {source: .[0], ro: ((.[2] // "") | split(",") | any(. == "ro"))}
             else {source: ((.source // "") | gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)[^}]*\\}"; "$\(.v)")), ro: (.read_only // false)} end) as $m
          | select($m.ro | not)
          | select($m.source != "/var/run/docker.sock")
          | if ($m.source | test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) then
              (if ($named | index($m.source)) then empty
               else "\($s): volume \($m.source) is not in compose.yaml volumes:" end)
            elif any($covered[]; . as $c | ($m.source + "/") | startswith($c)) then empty
            else "\($s): writable bind mount \($m.source) is not in the backup (scripts/backup-state copies volumes, ~/.local/state/order-gateway and the repositories): add it there, or mount it :ro" end
        ' compose.json)
        if [ -n "$problems" ]; then
          sed 's/^/backup-coverage: /' <<<"$problems" >&2
          exit 1
        fi
        touch $out
      '';

  backup-placement =
    let
      offHost = inventory.backup.offHost;
      problems = lib.concatMap (
        h:
        lib.optional (!(offHost ? ${h})) "${h}: no backup.offHost (where its copy goes)"
        ++ lib.optional ((offHost.${h} or h) == h) "${h}: backup.offHost must be another host"
        ++ lib.optional (
          !(inventory.backup.accounts ? ${offHost.${h} or "-"})
        ) "${h}: no backup.accounts entry for its off-host target"
      ) backupHosts;
      # Each compose service's host, in the default profile.
      placed = pkgs.writeText "placed.json" (
        builtins.toJSON (
          lib.mapAttrs (_: s: s.host) (
            lib.filterAttrs (_: s: (s.runtime or null) == "compose" && !(s ? profile)) services
          )
        )
      );
    in
    pkgs.runCommand "backup-placement"
      {
        nativeBuildInputs = [
          pkgs.yq-go
          pkgs.jq
        ];
      }
      ''
        status=0
        ${lib.concatMapStrings (p: "echo ${lib.escapeShellArg "backup-placement: ${p}"} >&2; status=1
") problems}
        # Hosts whose containers hold state (a named volume, or a gateway's
        # journal) must run the backup.
        yq -o=json 'explode(.)' ${compose} > compose.json
        missing=$(jq -r --slurpfile placed ${placed} --argjson backup '${builtins.toJSON backupHosts}' '
          $placed[0] as $p
          | [ .services | to_entries[] | select($p[.key])
              | select(any((.value.volumes // [])[];
                  (if type == "string" then split(":")[0] else (.source // "") end)
                  | test("^[A-Za-z0-9][A-Za-z0-9_.-]*$") or test("/\\.local/state/order-gateway")))
              | $p[.key] ] | unique[]
          | select(. as $h | $backup | index($h) | not)
          | "backup-placement: \(.) runs containers with state but no backup: add it to services.backup.perHost"
        ' compose.json)
        if [ -n "$missing" ]; then echo "$missing" >&2; status=1; fi
        [ "$status" -eq 0 ] && touch $out
      '';

  backup-script = pkgs.runCommand "backup-script" {
    nativeBuildInputs = [
      backupState
      pkgs.python3
      pkgs.jq
      pkgs.yq-go
    ];
  } "bash ${./backup-test.sh} ${compose} && touch $out";
}
