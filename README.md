# lidless

**Close the lid. Claude keeps working.**

You give Claude Code a big task, then you have to leave. The laptop stays home, and out of habit you shut the lid. macOS puts the Mac to sleep, Claude stops, and the Remote Control session you meant to pick up on your phone goes offline. Or you never copied the session link in the first place.

lidless fixes all three:

- **Every session is on your phone.** It turns on Claude Code's Remote Control for every session, so sessions appear in the Claude app under Code. No link to copy.
- **The lid can close.** While Claude is working, and for a grace period after it finishes, the Mac stays awake with the lid shut.
- **Then it sleeps like normal.** When there is nothing left to do, the battery runs low or the Mac runs hot, normal sleep comes back.

## Install

```bash
curl -fsSL https://lidless-mac.vercel.app/install | bash
```

The installer asks three things: how long to stay awake after Claude finishes (default 30 min), the battery level to give up at (default 20%), and whether to put every session on your phone. Then it asks for your Mac password once (see below). Restart Claude Code afterwards.

Then, once:

1. **Claude desktop app?** Turn on Settings › Code › "Connect new sessions to Remote Control". (The installer covers terminal sessions; the desktop app has its own switch.)
2. **Phone:** install the Claude app and sign in with the same account.
3. **Alerts:** run `/config` in Claude Code and turn on "Push when actions required".

macOS only. Nothing else to install: no Node, no Python, no Homebrew. Remote Control needs Claude Code signed in with a paid Claude plan.

## Why it needs your password

macOS sleeps on lid close no matter what apps ask. `caffeinate` and similar tools cannot stop it. The one switch that does is `pmset -a disablesleep 1`, and it needs admin rights.

So the installer adds `/etc/sudoers.d/lidless`, which lets your user run exactly two commands without a password:

```
pmset -a disablesleep 1   # stay awake, lid closed or not
pmset -a disablesleep 0   # back to normal sleep
```

Nothing else runs as admin. `lidless uninstall` removes the rule. If you skip the password, Claude sessions still reach your phone, but the Mac will sleep when you close it.

## How it decides

Claude Code hooks tell lidless what each session is doing:

| Hook | lidless |
|---|---|
| `SessionStart` | stay awake for the grace period |
| `UserPromptSubmit` | stay awake while Claude works (up to 4 h per turn) |
| `Stop` | Claude finished: stay awake for the grace period |
| `SessionEnd` | this session no longer needs the Mac |

A small background watcher holds the Mac awake while any session needs it, checks every 30 seconds, and puts normal sleep back when:

- every session's time has run out,
- the Mac is on battery below your level, or
- macOS reports a thermal warning.

A login agent also resets sleep at every login, so a power cut can never leave the Mac unable to sleep.

**Heat:** a Mac working with its lid shut inside a bag gets warm. Leave it on a desk.

## Commands

```bash
lidless status             # is the Mac being kept awake, and why
lidless hold 60            # keep it awake for 60 min right now
lidless release            # let it sleep right now
lidless grace 45           # minutes to stay awake after Claude finishes
lidless max 6              # longest one Claude turn can keep it awake (hours)
lidless battery 25         # on battery, sleep below this level
lidless log                # what lidless did recently
lidless uninstall          # remove everything
```

If `lidless` is not found, `~/.local/bin` is not on your PATH. Use `~/.lidless/lidless.sh` instead.

## Files

- `~/.lidless/`: the script, config, log and per-session timers
- `~/.claude/settings.json`: four hooks and `remoteControlAtStartup` (your other settings are kept, and the old file is backed up to `settings.json.lidless-backup`)
- `/etc/sudoers.d/lidless`: the two-command rule
- `~/Library/LaunchAgents/sh.lidless.reset.plist`: resets sleep at login

Not made by Anthropic. Remote Control is a Claude Code feature; lidless keeps it reachable.

MIT licence.
