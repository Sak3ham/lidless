#!/bin/bash
# lidless installer: close the lid, Claude keeps working.
#
#   curl -fsSL https://lidless-mac.vercel.app/install | bash
#
# Skip the questions with flags:
#   ... | bash -s -- --grace 45 --battery 25
#   ... | bash -s -- --no-remote      (leave Remote Control settings alone)
#   ... | bash -s -- --yes            (defaults)
set -e

REPO="${LIDLESS_REPO:-Sak3ham/lidless}"
DIR="${LIDLESS_HOME:-$HOME/.lidless}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
AGENT="$HOME/Library/LaunchAgents/sh.lidless.reset.plist"
RULE=/etc/sudoers.d/lidless

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }
fail() { printf 'lidless: %s\n' "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "lidless is for macOS. Linux laptops have their own lid settings."

# ---- flags -------------------------------------------------------------------
GRACE="" BATTERY="" REMOTE="" YES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --grace) GRACE="$2"; shift 2 ;;
    --battery) BATTERY="$2"; shift 2 ;;
    --no-remote) REMOTE=no; shift ;;
    --yes|-y) YES=yes; shift ;;
    *) fail "Unknown option: $1" ;;
  esac
done

INTERACTIVE=""
if [ -z "$YES$GRACE$BATTERY$REMOTE" ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
  INTERACTIVE=yes
fi
ask() { printf '%s' "$1" > /dev/tty; IFS= read -r REPLY < /dev/tty || REPLY=""; }
number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

# ---- copy files ----------------------------------------------------------------
SRC=""
case "${BASH_SOURCE[0]:-}" in
  ''|bash|-) ;;
  *) here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
     [ -f "$here/lidless.sh" ] && [ -f "$here/settings.js" ] && SRC="$here" ;;
esac
if [ -z "$SRC" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP" \
    || fail "Download failed. Check your connection and try again."
  SRC=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$SRC/lidless.sh" ] || fail "Download looked wrong. Try again."
fi

mkdir -p "$DIR/sessions"
cp "$SRC/lidless.sh" "$SRC/settings.js" "$DIR/"
chmod +x "$DIR/lidless.sh"
SELF="$DIR/lidless.sh"

# Current choices, so running the installer again keeps them.
GRACE_MIN=30 MAX_HOURS=4 MIN_BATTERY=20
# shellcheck disable=SC1090
[ -f "$DIR/config" ] && . "$DIR/config"

# ---- questions -------------------------------------------------------------------
if [ -n "$INTERACTIVE" ]; then
  echo > /dev/tty
  bold "lidless" > /dev/tty
  dim "Close the lid, Claude keeps working. Pick it up on your phone." > /dev/tty

  echo > /dev/tty
  bold "How long should the Mac stay awake after Claude finishes?" > /dev/tty
  dim "Time for you to read the result on your phone and send the next prompt." > /dev/tty
  ask "Minutes [$GRACE_MIN]: "
  [ -n "$REPLY" ] && GRACE="$REPLY"

  echo > /dev/tty
  bold "On battery, let the Mac sleep below what level?" > /dev/tty
  ask "Percent [$MIN_BATTERY]: "
  [ -n "$REPLY" ] && BATTERY="$REPLY"

  echo > /dev/tty
  bold "Put every Claude Code session on your phone automatically?" > /dev/tty
  dim "Turns on Remote Control for every terminal session, so you never" > /dev/tty
  dim "need to copy a link. Sessions show up in the Claude app under Code." > /dev/tty
  ask "Turn it on? [Y/n]: "
  case "$REPLY" in n|N|no|No) REMOTE=no ;; esac
fi

if [ -n "$GRACE" ]; then
  number "$GRACE" && [ "$GRACE" -le 480 ] || fail "Grace must be 0 to 480 minutes"
  GRACE_MIN="$GRACE"
fi
if [ -n "$BATTERY" ]; then
  number "$BATTERY" && [ "$BATTERY" -le 100 ] || fail "Battery must be 0 to 100"
  MIN_BATTERY="$BATTERY"
fi

cat > "$DIR/config" <<EOF
GRACE_MIN=$GRACE_MIN
MAX_HOURS=$MAX_HOURS
MIN_BATTERY=$MIN_BATTERY
EOF

# ---- the one thing that needs your password ---------------------------------------
# macOS sleeps on lid close no matter what apps ask, unless sleep is disabled
# with pmset, which needs admin rights. This rule lets lidless run exactly two
# commands without a password: turn that switch on, and turn it off. Nothing else.
USER_NAME=$(id -un)
RULE_TEXT="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
if [ "$(cat "$RULE" 2>/dev/null)" != "$RULE_TEXT" ]; then
  echo
  bold "One-time Mac password"
  echo "So the Mac can stay awake with the lid shut, lidless adds a rule that lets it"
  echo "run only these two commands without asking for your password:"
  dim "  pmset -a disablesleep 1   (stay awake, lid closed or not)"
  dim "  pmset -a disablesleep 0   (back to normal sleep)"
  echo "It is written to $RULE and removed by: lidless uninstall"
  echo
  tmp_rule=$(mktemp)
  echo "$RULE_TEXT" > "$tmp_rule"
  /usr/sbin/visudo -cf "$tmp_rule" >/dev/null || { rm -f "$tmp_rule"; fail "Could not build the sleep rule."; }
  RULE_OK=""
  # Ask with the standard macOS password window (Touch ID works there too).
  # Typing into a password prompt inside some terminals does not work, so the
  # terminal prompt is only a fallback for when no window can be shown (SSH).
  echo "A macOS password window will open. Enter your Mac login password there."
  gui_out=$(osascript -e "do shell script \"/usr/bin/install -m 0440 -o root -g wheel '$tmp_rule' '$RULE'\" with prompt \"lidless needs your password once, so your Mac can stay awake with the lid closed while Claude works.\" with administrator privileges" 2>&1) && gui_status=0 || gui_status=$?
  if [ $gui_status -eq 0 ]; then
    RULE_OK=yes
  elif echo "$gui_out" | grep -q -- "-128"; then
    echo "Password window cancelled."
  else
    dim "No password window available. Type your Mac login password and press Enter (nothing shows while you type)."
    sudo -p "Mac password: " install -m 0440 -o root -g wheel "$tmp_rule" "$RULE" < /dev/tty && RULE_OK=yes
  fi
  rm -f "$tmp_rule"
else
  RULE_OK=yes
fi

# ---- hooks, login reset, command ---------------------------------------------------
osascript -l JavaScript "$DIR/settings.js" add "$SETTINGS" "$SELF" > /dev/null
[ "$REMOTE" = "no" ] || osascript -l JavaScript "$DIR/settings.js" remote "$SETTINGS" "$SELF" > /dev/null

# If the Mac ever loses power while held awake, put sleep back to normal at login.
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>sh.lidless.reset</string>
  <key>ProgramArguments</key><array><string>$SELF</string><string>reset</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
ln -sf "$SELF" "$HOME/.local/bin/lidless"

# ---- done ------------------------------------------------------------------------------
echo
bold "lidless is on."
echo "  stays awake   while Claude works, then $GRACE_MIN min more"
echo "  battery       sleeps below $MIN_BATTERY% when unplugged"
if [ -n "$RULE_OK" ]; then
  echo "  lid           can close"
else
  echo "  lid           NOT set up: the password step was skipped, so the Mac"
  echo "                still sleeps when you close it. Run the installer again."
fi
[ "$REMOTE" = "no" ] || echo "  phone         every terminal session connects to Remote Control"
echo
bold "Two things to do once"
echo "  1. Using the Claude desktop app? Turn on Settings > Code >"
echo "     \"Connect new sessions to Remote Control\"."
echo "  2. Install the Claude app on your phone and sign in with the same account."
echo "     For alerts, run /config in Claude Code and turn on \"Push when actions required\"."
echo
echo "Restart Claude Code for the hooks to take effect."
case ":$PATH:" in
  *":$HOME/.local/bin:"*) echo "Check it any time with: lidless status" ;;
  *) echo "Check it any time with: $SELF status" ;;
esac
