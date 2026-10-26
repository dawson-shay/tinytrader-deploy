# checks.<system>.generic: fail if deployment-specific details leak into this
# stack. Everything about a real deployment (its hosts, users, paths,
# addresses, accounts and keys) belongs in its site (docs/site.md); here
# there are only made-up examples. A backstop for CONTRIBUTING.md, not a
# replacement for it.
{ pkgs }:
let
  inherit (pkgs) lib;
  # Every file of the flake's source (Git's tracked files) except this one,
  # which necessarily contains the patterns.
  files = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference ../. ./generic.nix;
  };
  patterns = [
    "/Users/[A-Za-z]" # macOS home directories
    "/home/[a-z]" # Linux home directories
    "/Volumes/[A-Z]" # a Mac's attached drives, by name
    "\\.ts\\.net" # Tailscale MagicDNS names
    "\\btail[0-9a-f]{6}\\b" # a tailnet's name
    "\\b100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]+\\.[0-9]+\\b" # Tailscale CGNAT addresses
    "\\b192\\.168\\.[0-9]+\\.[0-9]+\\b" # home LAN addresses
    "\\b10\\.[0-9]+\\.[0-9]+\\.[0-9]+\\b" # private addresses
    "\\b172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]+\\.[0-9]+\\b" # private addresses
    "BEGIN [A-Z ]*PRIVATE KEY" # key material
    "AGE-SECRET-KEY-" # an age private key
    "\\bage1[02-9ac-hj-np-z]{58}\\b" # an age public key (a real recipient)
    "ssh-(ed25519|rsa) AAAA" # an SSH public key
    "ENC\\[AES256_GCM" # a sops-encrypted value
    "tskey-(auth|client|api)-[A-Za-z0-9]" # a Tailscale key
    "\\bP[KA][A-Z0-9]{16,}\\b" # an Alpaca key ID
  ];
  # Lines that match a pattern but are generic: the tailnet's whole address
  # range (Tailscale's, the same for every tailnet).
  allowed = "100\\.64\\.0\\.0/10";
in
pkgs.runCommand "tinytrader-deploy-generic-check" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  cd ${files}
  status=0
  ${lib.concatMapStrings (p: ''
    if grep -rnIE ${lib.escapeShellArg p} . | grep -vE ${lib.escapeShellArg allowed}; then
      echo "generic check: found a deployment-specific pattern: ${lib.escapeShellArg p}" >&2
      status=1
    fi
  '') patterns}
  if [ "$status" -ne 0 ]; then
    echo "Move deployment-specific details to your site (docs/site.md, CONTRIBUTING.md)." >&2
    exit 1
  fi
  touch $out
''
