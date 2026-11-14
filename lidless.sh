#!/bin/bash
# lidless: close the lid, Claude keeps working.
# https://github.com/Sak3ham/lidless
#
# Claude Code hooks call `lidless.sh hook <event>`. While any session is busy,
# or within the grace period after it finishes, the Mac is kept awake even with
# the lid shut, so the Remote Control session stays reachable from your phone.
# A background watcher lets the Mac sleep again when the time runs out or the
# battery runs low.

DIR="${LIDLESS_HOME:-$HOME/.lidless}"
CONF="$DIR/config"
SESSIONS="$DIR/sessions"
PIDFILE="$DIR/watcher.pid"
LOG="$DIR/log"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
SELF="$DIR/lidless.sh"
# Tests point this at a fake. Real runs use the system pmset through sudo.
PMSET="${LIDLESS_PMSET:-sudo -n /usr/bin/pmset}"

# Defaults, overridden by the config file.
GRACE_MIN=30      # stay awake this long after Claude finishes, so you can reply
MAX_HOURS=4       # longest a single busy turn can hold the Mac awake
MIN_BATTERY=20    # on battery, let the Mac sleep below this percentage
CHECK_SEC=30      # how often the watcher looks
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

mkdir -p "$SESSIONS"

now() { date +%s; }
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

save_config() {
  cat > "$CONF" <<EOF
GRACE_MIN=$GRACE_MIN
MAX_HOURS=$MAX_HOURS
MIN_BATTERY=$MIN_BATTERY
EOF
}

# ---- machine state -----------------------------------------------------------

# Percentage when running on battery, empty when plugged in.
battery_pct() {
  local out
  out=$(pmset -g batt 2>/dev/null)
  case "$out" in *"Battery Power"*) ;; *) return 0 ;; esac
  echo "$out" | grep -oE '[0-9]+%' | head -1 | tr -d '%'
}

battery_low() {
  local pct
  pct=$(battery_pct)
  [ -n "$pct" ] && [ "$pct" -lt "$MIN_BATTERY" ]
}

too_hot() {
  pmset -g therm 2>/dev/null | grep -qi "warning level set"
}

lid_closed() {
  ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes'
}

sleep_disabled() {
  pmset -g 2>/dev/null | grep -qE 'SleepDisabled[[:space:]]+1'
}

can_hold_lid() {
  # True when the sudo rule from the installer lets us run pmset without a password.
  [ -n "${LIDLESS_PMSET:-}" ] && return 0
  sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1
}

# ---- awake on / off ------------------------------------------------------------

engage() {
  if $PMSET -a disablesleep 1 >/dev/null 2>&1; then
    return 0
  fi
  # No sudo rule: keep the Mac awake while the lid is open, at least.
  log "sudo rule missing, lid-open only"
  return 1
}

release() {
  $PMSET -a disablesleep 0 >/dev/null 2>&1
  pkill -f "caffeinate -i -w $$" 2>/dev/null
}

# Latest deadline across all sessions, after dropping the expired ones.
deadline() {
  local t=0 f until n
  n=$(now)
  for f in "$SESSIONS"/*; do
    [ -f "$f" ] || continue
    until=$(cat "$f" 2>/dev/null)
    case "$until" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
    if [ "$until" -le "$n" ]; then rm -f "$f"; continue; fi
    [ "$until" -gt "$t" ] && t="$until"
  done
  echo "$t"
}

watcher_alive() {
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Runs in the background while any session holds the Mac awake.
cmd_watch() {
  echo $$ > "$PIDFILE"
  trap 'release; rm -f "$PIDFILE"; log "released"; exit 0' EXIT
  trap 'exit 0' INT TERM HUP

  if engage; then
    log "awake, lid can close"
  else
    caffeinate -i -w $$ &
  fi

  local was_closed="" t
  while :; do
    t=$(deadline)
    if [ "$t" -le "$(now)" ]; then log "time up"; exit 0; fi
    if battery_low; then log "battery below $MIN_BATTERY%, letting the Mac sleep"; rm -f "$SESSIONS"/*; exit 0; fi
    if too_hot; then log "Mac is running hot, letting it sleep"; rm -f "$SESSIONS"/*; exit 0; fi
    if lid_closed; then
      [ -z "$was_closed" ] && log "lid closed, still awake" && was_closed=1
    else
      was_closed=""
    fi
    sleep "$CHECK_SEC"
  done
}

# Hold a session awake until <seconds> from now, and make sure the watcher runs.
hold() { # hold <session-id> <seconds>
  local id="$1" secs="$2"
  if battery_low; then log "battery low, not holding $id"; return 0; fi
  echo $(( $(now) + secs )) > "$SESSIONS/$id"

  # One watcher at a time, even when several hooks fire together.
  local lock="$DIR/.lock"
  if mkdir "$lock" 2>/dev/null; then
    if ! watcher_alive; then
      nohup "$SELF" watch >/dev/null 2>&1 &
      sleep 0.2
    fi
    rmdir "$lock"
  elif [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null
  fi
}

# ---- hooks -----------------------------------------------------------------------

session_id() {
  # Claude Code sends the hook input as JSON on stdin. Pull out session_id
  # without needing jq, and keep only safe file-name characters.
  local input id
  input=$(cat 2>/dev/null)
  id=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  id=$(printf '%s' "$id" | tr -cd 'A-Za-z0-9_-')
  echo "${id:-unknown}"
}

cmd_hook() {
  local id
  id=$(session_id)
  case "$1" in
    # A new session, or Claude just finished: stay reachable for the grace period.
    start|done) hold "$id" $(( GRACE_MIN * 60 )) ;;
    # Claude is working (including while it waits on a question or permission).
    busy) hold "$id" $(( MAX_HOURS * 3600 )) ;;
    # The session closed. Let the Mac sleep if nothing else needs it.
    end) rm -f "$SESSIONS/$id" ;;
    *) echo "Unknown hook: $1" >&2; exit 1 ;;
  esac
}

# ---- commands ----------------------------------------------------------------------

mins_left() {
  local t
  t=$(deadline)
  [ "$t" -gt 0 ] && echo $(( (t - $(now) + 59) / 60 )) || echo 0
}

cmd_status() {
  local left pct
  left=$(mins_left)
  if watcher_alive && [ "$left" -gt 0 ]; then
    echo "Awake      yes, for up to $left more min"
  else
    echo "Awake      no, the Mac sleeps normally"
  fi
  if can_hold_lid; then
    echo "Lid        can close, the Mac stays awake while Claude works"
  else
    echo "Lid        sudo rule missing: the Mac will still sleep when you close it."
    echo "           Run the installer again to fix it."
  fi
  pct=$(battery_pct)
  [ -n "$pct" ] && echo "Battery    $pct% (sleeps below $MIN_BATTERY%)" || echo "Battery    plugged in"
  echo "Grace      $GRACE_MIN min after Claude finishes"
  echo "Max turn   $MAX_HOURS h"
  echo
  osascript -l JavaScript "$DIR/settings.js" status "$SETTINGS" "$SELF"
}

cmd_set_number() { # cmd_set_number <name> <value> <min> <max> <unit>
  case "$2" in ''|*[!0-9]*) echo "Usage: lidless $1 <number>" >&2; exit 1 ;; esac
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then echo "$1 must be between $3 and $4 $5" >&2; exit 1; fi
}

usage() {
  cat <<EOF
lidless: close the lid, Claude keeps working.

  lidless status             Is the Mac being kept awake, and why
  lidless hold [minutes]     Keep it awake now, lid closed or not (default 60)
  lidless release            Let the Mac sleep again right now
  lidless grace <minutes>    How long to stay awake after Claude finishes
  lidless max <hours>        Longest one Claude turn can keep the Mac awake
  lidless battery <percent>  On battery, let the Mac sleep below this level
  lidless log                What lidless did recently
  lidless uninstall          Remove everything

The Mac stays awake only while Claude Code is working, plus the grace
period, so your Remote Control session stays online on your phone.
EOF
}

cmd_uninstall() {
  release
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  osascript -l JavaScript "$DIR/settings.js" remove "$SETTINGS" "$SELF"
  launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/sh.lidless.reset.plist" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/sh.lidless.reset.plist"
  rm -f "$HOME/.local/bin/lidless"
  if [ -f /etc/sudoers.d/lidless ]; then
    echo "Removing the sleep rule needs your Mac password once."
    sudo rm -f /etc/sudoers.d/lidless
  fi
  rm -rf "$DIR"
  echo "lidless removed. Your Mac sleeps normally."
}

case "${1:-}" in
  hook) cmd_hook "${2:-}" ;;
  watch) cmd_watch ;;
  status) cmd_status ;;
  hold)
    m="${2:-60}"; cmd_set_number hold "$m" 1 1440 minutes
    hold manual $(( m * 60 ))
    echo "Awake for $m min. Close the lid whenever you like."
    ;;
  release|off)
    rm -f "$SESSIONS"/*
    pid=$(cat "$PIDFILE" 2>/dev/null); [ -n "$pid" ] && kill "$pid" 2>/dev/null
    release
    echo "Released. The Mac sleeps normally."
    ;;
  # Runs at login, in case the Mac lost power while being held awake.
  reset) rm -f "$SESSIONS"/* "$PIDFILE"; release ;;
  grace) cmd_set_number grace "${2:-}" 0 480 minutes; GRACE_MIN="$2"; save_config; echo "Stays awake $2 min after Claude finishes." ;;
  max) cmd_set_number max "${2:-}" 1 24 hours; MAX_HOURS="$2"; save_config; echo "One Claude turn can keep the Mac awake up to $2 h." ;;
  battery) cmd_set_number battery "${2:-}" 0 100 percent; MIN_BATTERY="$2"; save_config; echo "On battery, the Mac sleeps below $2%." ;;
  log) tail -n "${2:-20}" "$LOG" 2>/dev/null || echo "Nothing yet." ;;
  uninstall) cmd_uninstall ;;
  ''|help|-h|--help) usage ;;
  *) echo "Unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
