{
  # A site: one deployment of tinytrader, made concrete from tinytrader-deploy
  # (its docs/site.md). Start one with
  #   nix flake new -t github:dawson-shay/tinytrader-deploy my-site
  # then edit inventory.nix and deploy/local/compose.yaml, and keep the
  # repository private: it holds your hosts, accounts and (encrypted) secrets.
  description = "my-site: a deployment of tinytrader";

  inputs = {
    # The platform, pinned here; the stack follows this pin.
    tinytrader.url = "git+https://github.com/dawson-shay/tinytrader?ref=main";
    tinytrader-deploy = {
      url = "github:dawson-shay/tinytrader-deploy";
      inputs.tinytrader.follows = "tinytrader";
    };
  };

  outputs =
    { tinytrader-deploy, ... }:
    tinytrader-deploy.lib.mkDeployment {
      inventory = ./inventory.nix;
      secrets = ./secrets;
      compose = ./deploy/local/compose.yaml;
      topology = ./deploy/local/topology.json;
      state = ./state;
      policy = ./tailscale/policy.hujson;
    };
}
