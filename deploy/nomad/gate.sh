#!/bin/sh
# A job's gate (docs/batch-jobs.md): the prestart task of every job in
# the site's deploy/nomad/jobs/. It checks the job's parameters, then waits until the
# job may start, and exits 0; the job's work starts after it. Generic: it
# knows a calendar of open and close times, health URLs and a start time,
# nothing of what the job does. Run natively (raw_exec), so its addresses
# are the host's (deploy/nomad/node.nix's node metadata).
#
#   GATE_CHECK       "key=regex;..."  each dispatch parameter (NOMAD_META_<key>)
#                    must match its regex (grep -E), or the job fails here
#   GATE_NOT_BEFORE  Unix seconds: not before then (empty: now)
#   GATE_WHEN        anytime | after-close | background-may-run
#     after-close         today's close in GATE_CALENDAR has passed, or today
#                         has no session (a holiday, a weekend)
#     background-may-run  no GATE_YIELD_TO service is capturing
#   GATE_CALENDAR    a URL answering {"days": [{"date", "open", "close"}]},
#                    New York dates and times (HH:MM)
#   GATE_YIELD_TO    "name=url;...": health URLs whose `state` is "idle"
#                    when they aren't capturing. One that doesn't answer in
#                    3 s counts as not capturing.
#   GATE_POLL        seconds between checks (60)
set -eu
poll="${GATE_POLL:-60}"

say() { printf '%s gate: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# The parameters, before anything waits.
IFS=';'
for rule in ${GATE_CHECK:-}; do
  [ -n "$rule" ] || continue
  key="${rule%%=*}"
  re="${rule#*=}"
  eval "value=\${NOMAD_META_${key}-}"
  # shellcheck disable=SC2154 # set by the eval
  if ! printf '%s' "$value" | grep -Eqx -- "$re" || [ "$(printf '%s' "$value" | wc -l)" -ne 0 ]; then
    say "parameter $key does not match $re: not running"
    exit 1
  fi
done
unset IFS

if [ -n "${GATE_NOT_BEFORE:-}" ]; then
  case "$GATE_NOT_BEFORE" in *[!0-9]*) say "GATE_NOT_BEFORE is not Unix seconds: $GATE_NOT_BEFORE"; exit 1 ;; esac
  while [ "$(date +%s)" -lt "$GATE_NOT_BEFORE" ]; do
    say "waiting until $(date -u -r "$GATE_NOT_BEFORE" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$GATE_NOT_BEFORE" +%Y-%m-%dT%H:%M:%SZ)"
    sleep "$poll"
  done
fi

# HH:MM on standard input, as minutes since midnight.
minutes() { awk -F: '{ print $1 * 60 + $2 }'; }

# after-close: 0 when the session is over (or there is none today).
calendar=""
calendar_at=0
closed() {
  now="$(date +%s)"
  # The calendar at most hourly.
  if [ -z "$calendar" ] || [ $((now - calendar_at)) -ge 3600 ]; then
    if fresh="$(curl -fsS -m 10 "$GATE_CALENDAR")" && printf '%s' "$fresh" | jq -e '.days | length > 0' >/dev/null; then
      calendar="$fresh"
      calendar_at="$now"
    elif [ -z "$calendar" ]; then
      say "calendar unreachable ($GATE_CALENDAR): waiting"
      return 1
    fi
  fi
  today="$(TZ=America/New_York date +%F)"
  mins="$(TZ=America/New_York date +%H:%M | minutes)"
  close="$(printf '%s' "$calendar" | jq -r --arg d "$today" '.days[] | select(.date == $d) | .close' | head -n1)"
  if [ -n "$close" ]; then
    [ "$mins" -ge "$(printf '%s' "$close" | minutes)" ]
    return
  fi
  day="$(printf '%s' "$today" | tr -d -)"
  first="$(printf '%s' "$calendar" | jq -r '[.days[].date] | min' | tr -d -)"
  last="$(printf '%s' "$calendar" | jq -r '[.days[].date] | max' | tr -d -)"
  if [ "$day" -ge "$first" ] && [ "$day" -le "$last" ]; then
    return 0 # within the calendar, no session: a holiday or a weekend
  fi
  # Beyond it: weekends, and weekdays after 16:00.
  [ "$(TZ=America/New_York date +%u)" -ge 6 ] || [ "$mins" -ge 960 ]
}

# background-may-run: 0 when nothing in GATE_YIELD_TO is capturing.
quiet() {
  busy=""
  IFS=';'
  for entry in ${GATE_YIELD_TO:-}; do
    [ -n "$entry" ] || continue
    name="${entry%%=*}"
    url="${entry#*=}"
    state="$(curl -fsS -m 3 "$url" 2>/dev/null | jq -r '.state // empty' 2>/dev/null || true)"
    if [ -n "$state" ] && [ "$state" != idle ]; then busy="$busy $name ($state)"; fi
  done
  unset IFS
  [ -z "$busy" ] || { say "waiting:$busy capturing"; return 1; }
}

case "${GATE_WHEN:-anytime}" in
  anytime) ;;
  after-close)
    [ -n "${GATE_CALENDAR:-}" ] || { say "after-close needs GATE_CALENDAR"; exit 1; }
    until closed; do say "waiting for the close"; sleep "$poll"; done
    ;;
  background-may-run)
    until quiet; do sleep "$poll"; done
    ;;
  *)
    say "when must be anytime, after-close or background-may-run, not ${GATE_WHEN}"
    exit 1
    ;;
esac
say "go"
