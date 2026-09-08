#!/bin/bash
# Regression suite for install.sh. Separate from run-tests.sh on purpose: that
# file asserts on rendered text and needs nothing but a payload, while these
# cases need a filesystem -- a fake HOME, a config directory, a settings.json
# to clobber or to leave alone.
#
# Every case here corresponds to a defect that shipped:
#   * CLAUDE_CONFIG_DIR honoured for where the symlink goes but not for the
#     command written into settings.json, which kept saying $HOME/.claude --
#     a path the installer had not created
#   * any customised statusLine.command silently rewritten on the next run,
#     because "installed" was defined as "matches my string byte for byte"
# Run:  ./tests/install-tests.sh    (exit 0 = green)
#
# shellcheck disable=SC2016  # the literal $HOME is the subject of this file:
# the command in settings.json must contain those five characters, not this
# machine's home directory, so every single-quoted "$HOME" below is deliberate.
set -u
here=$(cd -- "$(dirname -- "$0")" && pwd)
installer="$here/../install.sh"
# Resolved the way install.sh resolves it, so the symlink assertions compare
# the same spelling of the same path rather than "..' against its expansion.
source_script="$(cd -- "$here/.." && pwd)/statusline.sh"
pass=0; fail=0
sandboxes=""

check() { # $1 = label, $2 = haystack, $3 = needle
  if case "$2" in *"$3"*) true ;; *) false ;; esac; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$3" "$2"
  fi
}

refute() { # $1 = label, $2 = haystack, $3 = needle that must NOT appear
  if case "$2" in *"$3"*) true ;; *) false ;; esac; then
    fail=$((fail + 1)); printf '  FAIL %s\n     unwanted: %s\n     got:      %s\n' "$1" "$3" "$2"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  fi
}

home_dir() { # a fresh fake HOME, remembered so it can be removed at the end
  local d; d=$(mktemp -d)
  sandboxes="$sandboxes $d"
  printf '%s' "$d"
}

install_in() { # $1 = HOME, $2 = CLAUDE_CONFIG_DIR ("" = let the script default)
  if [ -n "$2" ]; then
    ( cd "$here/.." && env HOME="$1" CLAUDE_CONFIG_DIR="$2" sh "$installer" 2>&1 )
  else
    ( cd "$here/.." && env -u CLAUDE_CONFIG_DIR HOME="$1" sh "$installer" 2>&1 )
  fi
}

# The value is read back out of the raw file rather than with jq, so that the
# suite does not depend on a different JSON tool than the one install.sh found.
# The leading .* is greedy, which is what makes it skip "type": "command" and
# land on the real key even when both sit on one line.
command_in() { # $1 = settings.json -> statusLine.command, unescaped
  sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$1" \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}

settings_with() { # $1 = path, $2 = the command to put there (raw, unescaped)
  local esc; esc=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{\n  "statusLine": { "type": "command", "command": "%s" },\n  "theme": "dark"\n}\n' \
    "$esc" > "$1"
}

baks() { # $1 = directory -> how many settings.json backups it holds
  find "$1" -maxdepth 1 -name 'settings.json.bak-*' | wc -l | tr -d ' '
}

echo "== a fresh install, with the config dir where it is expected =="
h=$(home_dir); mkdir -p "$h/.claude"
out=$(install_in "$h" "")
check "the symlink lands in the config dir" "$(readlink "$h/.claude/statusline-command.sh")" "$source_script"
# $HOME stays a literal: Claude Code expands it, and this file gets copied
# between accounts more often than anyone expects.
check "the command keeps \$HOME unexpanded" "$(command_in "$h/.claude/settings.json")" \
  'bash "$HOME/.claude/statusline-command.sh"'
refute "and does not bake in this home" "$(command_in "$h/.claude/settings.json")" "$h"

echo "== CLAUDE_CONFIG_DIR, the case that was wrong =="
# The installer linked the script into the config dir and then told
# settings.json to run $HOME/.claude/statusline-command.sh, which on a machine
# that only ever used CLAUDE_CONFIG_DIR does not exist. Nothing reports that:
# the status line simply renders nothing.
h=$(home_dir); cfg="$h/.config/claude"; mkdir -p "$cfg"
out=$(install_in "$h" "$cfg")
check "the symlink follows the config dir" "$(readlink "$cfg/statusline-command.sh")" "$source_script"
check "and so does the command" "$(command_in "$cfg/settings.json")" \
  'bash "$HOME/.config/claude/statusline-command.sh"'
refute "no phantom ~/.claude path" "$(command_in "$cfg/settings.json")" '.claude/statusline-command.sh'

echo "== a config dir outside the home =="
# Nothing to abbreviate against, so the absolute path goes in as it is rather
# than a $HOME-relative one that would resolve somewhere else entirely.
h=$(home_dir); cfg=$(home_dir)
out=$(install_in "$h" "$cfg")
check "absolute path in the command" "$(command_in "$cfg/settings.json")" "bash \"$cfg/statusline-command.sh\""
refute "no \$HOME in it" "$(command_in "$cfg/settings.json")" '$HOME'

echo "== an unnormalised config dir is resolved before it is written down =="
# A path with a ".." in it symlinks perfectly well and then goes into
# settings.json as-is, where Claude Code resolves it against a working
# directory nobody chose. Same failure as above, arrived at differently.
h=$(home_dir); mkdir -p "$h/.config/claude"
out=$(install_in "$h" "$h/.config/../.config/claude")
check "the command carries the clean path" "$(command_in "$h/.config/claude/settings.json")" \
  'bash "$HOME/.config/claude/statusline-command.sh"'
refute "no .. left in it" "$(command_in "$h/.config/claude/settings.json")" '..'

echo "== re-running when nothing changed =="
# The header of install.sh promises this, and Windows needs a re-run after
# every pull: an installer that leaves a trail of .bak files behind each time
# is one nobody re-runs.
h=$(home_dir); mkdir -p "$h/.claude"
install_in "$h" "" > /dev/null
out=$(install_in "$h" "")
check "says so"                "$out" "already points at the status line"
check "no backup was created"  "$(baks "$h/.claude")" "0"
check "the symlink is left alone" "$out" "symlink already in place"

echo "== a customised command survives =="
# The whole point: a prefix, a wrapper or another interpreter is somebody's
# deliberate choice, and re-running an installer is not a request to undo it.
# This used to be rewritten back, leaving only a .bak to say it had happened.
h=$(home_dir); mkdir -p "$h/.claude"
install_in "$h" "" > /dev/null
custom='CLAUDE_STATUSLINE_PLAIN=1 bash "$HOME/.claude/statusline-command.sh"'
settings_with "$h/.claude/settings.json" "$custom"
out=$(install_in "$h" "")
check "the command is kept"   "$(command_in "$h/.claude/settings.json")" "$custom"
check "and said out loud"     "$out" "custom command kept"
check "no backup was created" "$(baks "$h/.claude")" "0"
check "other keys are untouched" "$(cat "$h/.claude/settings.json")" '"theme": "dark"'

echo "== the same script named absolutely also counts as installed =="
h=$(home_dir); mkdir -p "$h/.claude"
install_in "$h" "" > /dev/null
settings_with "$h/.claude/settings.json" "bash \"$h/.claude/statusline-command.sh\""
out=$(install_in "$h" "")
check "left alone"            "$out" "custom command kept"
check "no backup was created" "$(baks "$h/.claude")" "0"

echo "== a command pointing somewhere else is replaced =="
# The other half: leaving a command that does NOT run this script would make
# the installer a no-op that claims to have installed something.
h=$(home_dir); mkdir -p "$h/.claude"
settings_with "$h/.claude/settings.json" 'bash "/opt/somebody-elses/line.sh"'
out=$(install_in "$h" "")
check "rewritten"                "$(command_in "$h/.claude/settings.json")" 'bash "$HOME/.claude/statusline-command.sh"'
check "with a backup"            "$(baks "$h/.claude")" "1"
check "and the rest of the file" "$(cat "$h/.claude/settings.json")" '"theme": "dark"'

echo "== a missing config dir is an error, not a guess =="
h=$(home_dir)
out=$(install_in "$h" "$h/nowhere"); rc=$?
check "non-zero exit" "$rc" "1"
check "and says which directory" "$out" "no Claude config dir"

for d in $sandboxes; do rm -rf "$d"; done
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
