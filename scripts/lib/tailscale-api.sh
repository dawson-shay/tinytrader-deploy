# shellcheck shell=bash disable=SC2154  # sourced; the script sets $site
# The Tailscale API with the site's OAuth client (its secrets/tailscale.env:
# TS_OAUTH_CLIENT_ID, TS_OAUTH_CLIENT_SECRET; scripts/tailscale-credential).
# Sourced by scripts/tailscale-pin and scripts/tailscale-join. The client's
# secret and the access token it buys never reach a command line (ps) or the
# terminal: curl reads them from its standard input as configuration.
#
#   ts_login                 decrypt the client and get an access token (an hour)
#   ts_api METHOD PATH [JSON]
#                            call https://api.tailscale.com/api/v2/PATH; the
#                            response on stdout; on an HTTP error, the status
#                            and Tailscale's message on stderr, and status 1
ts_base=https://api.tailscale.com/api/v2
ts_token=""

ts_login() {
  local env id secret
  env="$(sops decrypt --input-type dotenv --output-type dotenv "$site/secrets/tailscale.env")" ||
    { echo "could not decrypt secrets/tailscale.env (the operator key?)" >&2; return 1; }
  id="$(sed -n 's/^TS_OAUTH_CLIENT_ID=//p' <<<"$env" | head -n1)"
  secret="$(sed -n 's/^TS_OAUTH_CLIENT_SECRET=//p' <<<"$env" | head -n1)"
  unset env
  [ -n "$id" ] && [ -n "$secret" ] || { echo "secrets/tailscale.env lacks TS_OAUTH_CLIENT_ID or TS_OAUTH_CLIENT_SECRET" >&2; return 1; }
  ts_token="$(printf 'url = "%s/oauth/token"\ndata-urlencode = "client_id=%s"\ndata-urlencode = "client_secret=%s"\n' "$ts_base" "$id" "$secret" |
    curl -sS --fail -K - | jq -r '.access_token // empty')" || true
  unset id secret
  [ -n "$ts_token" ] || { echo "the OAuth client was refused a token (revoked? see scripts/tailscale-credential)" >&2; return 1; }
}

ts_api() {
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  code="$(
    {
      printf 'header = "Authorization: Bearer %s"\n' "$ts_token"
      if [ -n "$body" ]; then printf 'header = "Content-Type: application/json"\n'; fi
    } | curl -sS -X "$method" -o "$out" -w '%{http_code}' -K - ${body:+--data-binary "$body"} "$ts_base/$path"
  )" || { rm -f "$out"; echo "$method /$path: no answer from the API" >&2; return 1; }
  if [ "${code:0:1}" != 2 ]; then
    echo "$method /$path: HTTP $code: $(jq -r '.message // empty' "$out" 2>/dev/null || true)" >&2
    case "$code" in 403 | 404) echo "  (a scope the OAuth client lacks? scripts/tailscale-credential stores a new one)" >&2 ;; esac
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}
