# Data roots belong to the services granted them (inventory.nix `dataRoots`,
# a service's `dataRoots`):
#   data-roots-mounts  no container mounts a path inside a data root on its
#                      host that it isn't granted, so state (a gateway's
#                      journal, a volume) can't land on the market-data drives
#                      the store owns. The rule lives with the roots, for
#                      every service (not hard-coded in any one of them).
{
  pkgs,
  inventory,
  compose,
}:
let
  inherit (pkgs) lib;
  # Per compose service: its host, and the paths of the roots on that host
  # it isn't granted.
  forbidden = lib.mapAttrs (
    name: svc:
    let
      host = svc.host or null;
      granted = svc.dataRoots or [ ];
    in
    lib.mapAttrsToList (_: r: r.path) (
      lib.filterAttrs (root: r: r.host == host && !(lib.elem root granted)) inventory.dataRoots
    )
  ) (lib.filterAttrs (_: s: (s.runtime or null) == "compose") inventory.services);
in
{
  data-roots-mounts =
    pkgs.runCommand "data-roots-mounts"
      {
        nativeBuildInputs = [
          pkgs.yq-go
          pkgs.jq
        ];
      }
      ''
        yq -o=json 'explode(.)' ${compose} > compose.json
        problems=$(jq -r --argjson forbidden '${builtins.toJSON forbidden}' '
          .services // {} | to_entries[] | .key as $s
          | (.value.volumes // [])[]
          | (if type == "string" then split(":")[0] else (.source // "") end) as $src
          | ($forbidden[$s] // [])[] as $root
          | select(($src + "/") | startswith($root + "/"))
          | "\($s): mounts \($src), inside the data root at \($root), which it is not granted (inventory.nix dataRoots)"
        ' compose.json)
        if [ -n "$problems" ]; then echo "$problems" >&2; exit 1; fi
        touch $out
      '';
}
