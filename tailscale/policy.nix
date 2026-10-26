# The tailnet policy (docs/decisions/0008), from the site's inventory: the hosts
# that run services carry `tailnet.tag`, and reach each other only on the
# ports services may be reached on across hosts (endpoints.nix's aclPorts:
# every service port but the localOnly ones: the order gateways', the Docker
# proxies' and the console's raw port; each host forwards all of them for
# its services, docs/decisions/0010), and 443 where a service is published
# over HTTPS (endpoints.nix httpsPorts: the console, for research). Plain
# Nix, no inputs (`inventory`: the inventory, or the path of its file). A
# deployment's `tailscale-policy` package; written to the site's
# tailscale/policy.hujson by scripts/tailscale-policy, and `nix flake check`
# fails while that file differs. Nothing here applies it.
{ inventory, ... }:
let
  inventory' = if builtins.isAttrs inventory then inventory else import inventory;
in
let
  inventory = inventory';
  endpoints = import ../deploy/local/endpoints.nix { inherit inventory; };
  inherit (builtins) concatStringsSep toJSON;
  tag = inventory.tailnet.tag;
  list = xs: "[${concatStringsSep ", " (map toJSON xs)}]";
  tcp = map (p: "tcp:${toString p}");
  # What the services' hosts may reach on each other.
  tagPorts = endpoints.aclPorts ++ endpoints.httpsPorts;
  # Ports that must never be reachable across hosts, for the policy's tests.
  never =
    endpoints.gatewayPorts
    ++ builtins.concatMap (n: builtins.attrValues (inventory.services.${n}.ports or { })) endpoints.localOnly;
  uniqueSorted = xs: builtins.sort builtins.lessThan (builtins.foldl' (a: x: if builtins.elem x a then a else a ++ [ x ]) [ ] xs);
  at = ports: map (p: "${tag}:${toString p}") ports;
  tagged = map (
    h:
    let
      v = inventory.hosts.${h};
    in
    "${v.tailnetName} (${h}${if (v.status or "") == "planned" then ", once it exists" else ""})"
  ) (builtins.sort builtins.lessThan endpoints.serviceHosts);
in
''
  // The tailnet policy for tinytrader (docs/decisions/0008).
  //
  // GENERATED from inventory.nix by tailscale/policy.nix: edit that, then run
  // scripts/tailscale-policy. `nix flake check` fails while this file differs.
  // Nothing applies it automatically: paste it into the admin console's
  // Access controls, or later apply it with the tailscale/gitops-acl-action.
  //
  // ${tag} goes on the hosts that run services:
  //   ${concatStringsSep "\n//   " tagged}
  // (the admin console's Machines page: the host's menu, Edit ACL tags).
  // Other devices stay yours, untagged.
  {
    "tagOwners": {
      "${tag}": ["autogroup:admin"],
    },

    "grants": [
      // Your own devices reach each other, as they did before any policy.
      {
        "src": ["autogroup:member"],
        "dst": ["autogroup:self"],
        "ip":  ["*"],
      },
      // The services' hosts reach each other's service ports, and nothing
      // else. A port is open only where `tailscale serve` forwards it
      // (scripts/tailnet-serve): services listen on loopback, and each host
      // forwards every port of its services (decision 0010). The order
      // gateways (${concatStringsSep ", " (map toString endpoints.gatewayPorts)}), the Docker proxies and
      // the console's raw port are never listed: they are reached on their
      // own host only.${
        if endpoints.httpsPorts == [ ] then
          ""
        else
          "\n    // 443: the console's HTTPS (`tailscale serve`), for research's reads.\n    // A tagged host sends no Tailscale login, so the console refuses its writes."
      }
      {
        "src": ["${tag}"],
        "dst": ["${tag}"],
        "ip":  ${list (tcp tagPorts)},
      },
      // SSH between your devices and the services' hosts, either way.
      {
        "src": ["autogroup:member", "${tag}"],
        "dst": ["autogroup:member", "${tag}"],
        "ip":  ["tcp:22"],
      },
      // The console from your devices: `tailscale serve` publishes it over
      // HTTPS on its host's tailnet name.
      {
        "src": ["autogroup:member"],
        "dst": ["${tag}"],
        "ip":  ["tcp:443"],
      },
    ],

    // Tailscale SSH, where a host runs it (the open-source tailscaled; the
    // App Store app can't serve SSH, so a Mac running it takes plain SSH on port 22).
    "ssh": [
      {
        "action": "check",
        "src":    ["autogroup:member"],
        "dst":    ["autogroup:self"],
        "users":  ["autogroup:nonroot", "root"],
      },
      {
        "action": "check",
        "src":    ["autogroup:member"],
        "dst":    ["${tag}"],
        "users":  ["autogroup:nonroot"],
      },
    ],

    // Checked by Tailscale whenever the policy is saved.
    "tests": [
      {
        "src":    "${tag}",
        "accept": ${list (at tagPorts ++ [ "${tag}:22" ])},
        "deny":   ${list (at (uniqueSorted never))},
      },
    ],
  }
''
