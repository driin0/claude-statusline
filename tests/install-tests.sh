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
# shellcheck disable=SC2016,SC2088  # the literal $HOME is the subject of this
# file: the command in settings.json must contain those five characters, not
# this machine's home directory, so every single-quoted "$HOME" below is
# deliberate -- and so is the unexpanded "~", which is one of the spellings a
# person types by hand and the installer therefore has to recognise as text.
set -u
here=$(cd -- "$(dirname -- "$0")" && pwd)
installer="$here/../install.sh"
# Resolved the way install.sh resolves it, so the symlink assertions compare
# the same spelling of the same path rather than "..' against its expansion.
source_script="$(cd -- "$here/.." && pwd)/statusline.sh"
pass=0; fail=0
# One parent directory removed by a trap, rather than a list built inside
# home_dir: that ran in a command substitution, so every name it appended to a
# variable died with the subshell and the cleanup loop deleted nothing. Ten
# sandboxes leaked per run, and CLAUDE.md asks every contributor to run this.
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

check() { # $1 = label, $2 = haystack, $3 = needle
  if case "$2" in *"$3"*) true ;; *) false ;; esac; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$3" "$2"
  fi
}

equals() { # $1 = label, $2 = actual, $3 = expected -- exact, not substring
  # check() below matches substrings, which is right for a rendered command and
  # wrong for a count: "no backups" asserted with check() also passes on 10.
  if [ "$2" = "$3" ]; then
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

home_dir() { # a fresh fake HOME inside the one directory the trap removes
  mktemp -d "$root/h.XXXXXX"
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

tmps() { # $1 = directory -> how many half-written temporaries it holds
  find "$1" -maxdepth 1 -name 'settings.json.tmp.*' | wc -l | tr -d ' '
}

echo "== a fresh install, with the config dir where it is expected =="
h=$(home_dir); mkdir -p "$h/.claude"
install_in "$h" "" > /dev/null
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
install_in "$h" "$cfg" > /dev/null
check "the symlink follows the config dir" "$(readlink "$cfg/statusline-command.sh")" "$source_script"
check "and so does the command" "$(command_in "$cfg/settings.json")" \
  'bash "$HOME/.config/claude/statusline-command.sh"'
refute "no phantom ~/.claude path" "$(command_in "$cfg/settings.json")" '.claude/statusline-command.sh'

echo "== a config dir outside the home =="
# Nothing to abbreviate against, so the absolute path goes in as it is rather
# than a $HOME-relative one that would resolve somewhere else entirely.
h=$(home_dir); cfg=$(home_dir)
install_in "$h" "$cfg" > /dev/null
check "absolute path in the command" "$(command_in "$cfg/settings.json")" "bash \"$cfg/statusline-command.sh\""
refute "no \$HOME in it" "$(command_in "$cfg/settings.json")" '$HOME'

echo "== an unnormalised config dir is resolved before it is written down =="
# A path with a ".." in it symlinks perfectly well and then goes into
# settings.json as-is, where Claude Code resolves it against a working
# directory nobody chose. Same failure as above, arrived at differently.
h=$(home_dir); mkdir -p "$h/.config/claude"
install_in "$h" "$h/.config/../.config/claude" > /dev/null
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
equals "no backup was created"  "$(baks "$h/.claude")" "0"
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
equals "no backup was created" "$(baks "$h/.claude")" "0"
check "other keys are untouched" "$(cat "$h/.claude/settings.json")" '"theme": "dark"'

echo "== the same script named another working way is normalised once =="
# An absolute path does run the script, but it is not what this writes, so it
# is rewritten into the $HOME form -- once. The second run must then be a
# no-op, or the installer would churn a .bak on every invocation.
h=$(home_dir); mkdir -p "$h/.claude"
install_in "$h" "" > /dev/null
settings_with "$h/.claude/settings.json" "bash \"$h/.claude/statusline-command.sh\""
out=$(install_in "$h" "")
check  "rewritten into the $HOME form" "$(command_in "$h/.claude/settings.json")" \
  'bash "$HOME/.claude/statusline-command.sh"'
out=$(install_in "$h" "")
check  "and then settles"     "$out" "already points at the status line"
equals "one backup, not two"  "$(baks "$h/.claude")" "1"

echo "== a command pointing somewhere else is replaced =="
# The other half: leaving a command that does NOT run this script would make
# the installer a no-op that claims to have installed something.
h=$(home_dir); mkdir -p "$h/.claude"
settings_with "$h/.claude/settings.json" 'bash "/opt/somebody-elses/line.sh"'
out=$(install_in "$h" "")
check "rewritten"                "$(command_in "$h/.claude/settings.json")" 'bash "$HOME/.claude/statusline-command.sh"'
equals "with a backup"            "$(baks "$h/.claude")" "1"
check "and the rest of the file" "$(cat "$h/.claude/settings.json")" '"theme": "dark"'

echo "== what counts as a customisation, and what counts as broken =="
# Kept: anything that contains, verbatim, the command this writes. That is the
# documented case -- the README tells people to add a CLAUDE_STATUSLINE_PLAIN=1
# prefix -- plus wrappers and redirects, which are the same shape.
for custom in 'CLAUDE_STATUSLINE_PLAIN=1 bash "$HOME/.claude/statusline-command.sh"' \
              'bash "$HOME/.claude/statusline-command.sh" 2>/dev/null'; do
  h=$(home_dir); mkdir -p "$h/.claude"
  install_in "$h" "" > /dev/null
  settings_with "$h/.claude/settings.json" "$custom"
  out=$(install_in "$h" "")
  check  "kept: $custom"     "$(command_in "$h/.claude/settings.json")" "$custom"
  check  "and said out loud" "$out" "custom command kept"
  equals "no backup"         "$(baks "$h/.claude")" "0"
done

# Repaired: spellings that name the file but do not survive being run. Neither
# ~ nor $HOME expands inside the double quotes they sit in, so keeping these
# would report success over a status line that renders nothing -- the same lie
# the type check exists to prevent. An earlier version of this file asserted
# the opposite, which is how the rule got narrowed to "contains $COMMAND".
for broken in 'bash "~/.claude/statusline-command.sh"' \
              "bash '\$HOME/.claude/statusline-command.sh'"; do
  h=$(home_dir); mkdir -p "$h/.claude"
  install_in "$h" "" > /dev/null
  settings_with "$h/.claude/settings.json" "$broken"
  out=$(install_in "$h" "")
  check "repaired: $broken" "$(command_in "$h/.claude/settings.json")" \
    'bash "$HOME/.claude/statusline-command.sh"'
done

echo "== a sibling that merely starts the same is not this script =="
# install.sh creates statusline-command.sh.bak-<stamp> itself when it replaces
# a Git Bash copy. A substring test counts one of those as installed, and the
# user stays pinned to a frozen snapshot while every re-run reports success.
h=$(home_dir); mkdir -p "$h/.claude"
install_in "$h" "" > /dev/null
settings_with "$h/.claude/settings.json" 'bash "$HOME/.claude/statusline-command.sh.bak-20250101"'
out=$(install_in "$h" "")
check  "the stale path is replaced" "$(command_in "$h/.claude/settings.json")" \
  'bash "$HOME/.claude/statusline-command.sh"'
equals "with a backup"              "$(baks "$h/.claude")" "1"

echo "== a statusLine Claude Code will not run is repaired, not kept =="
# The keep-it branch preserves a configuration, so it has to check the whole
# key: write_command always writes type "command", and any other type is a
# status line that never runs -- reporting it as installed would be a lie.
h=$(home_dir); mkdir -p "$h/.claude"
install_in "$h" "" > /dev/null
printf '{"statusLine":{"type":"static","command":"bash \\"$HOME/.claude/statusline-command.sh\\""}}\n' \
  > "$h/.claude/settings.json"
out=$(install_in "$h" "")
check  "rewritten"   "$out" "updated"
refute "type is gone" "$(cat "$h/.claude/settings.json")" '"static"'

echo "== a backslash in the path still re-runs as a no-op =="
# jq's @tsv escapes backslashes in the values it prints, while node and python
# return them raw. With jq present, a command holding one came back doubled,
# never compared equal to what was already in the file, and every re-run
# rewrote settings.json and dropped another .bak -- the "re-running must be a
# no-op" promise in the header of install.sh, broken by the reader.
h=$(home_dir); cfg="$h/.claude\\x"; mkdir -p "$cfg"
install_in "$h" "$cfg" > /dev/null
out=$(install_in "$h" "$cfg")
check  "the second run changes nothing" "$out" "already points at the status line"
equals "and leaves no backup"           "$(baks "$cfg")" "0"

echo "== a settings.json that does not parse =="
# The read is a bare assignment from a command substitution, so its exit status
# is the assignment's: under `set -e` an unparseable file ended the script on
# that line -- no diagnostic, no smoke test, and the repair below never run.
h=$(home_dir); mkdir -p "$h/.claude"
printf '{ "theme": "dark",\n' > "$h/.claude/settings.json"
out=$(install_in "$h" ""); rc=$?
equals "exit code is 1"        "$rc" "1"
check  "and says what happened" "$out" "could not update"
check  "the file is untouched"  "$(cat "$h/.claude/settings.json")" '{ "theme": "dark",'
equals "no backup left behind"  "$(baks "$h/.claude")" "0"
equals "no temporary left behind" "$(tmps "$h/.claude")" "0"

echo "== HOME spelled unusually still collapses to \$HOME =="
# CLAUDE_DIR is canonicalised, so comparing it against a HOME with a trailing
# slash found no match and baked this machine's absolute home into the file --
# the one thing install.sh says must never happen.
h=$(home_dir); mkdir -p "$h/.claude"
out=$( cd "$here/.." && env -u CLAUDE_CONFIG_DIR HOME="$h/" sh "$installer" 2>&1 )
check  "still the \$HOME form" "$(command_in "$h/.claude/settings.json")" \
  'bash "$HOME/.claude/statusline-command.sh"'
refute "no absolute home"      "$(command_in "$h/.claude/settings.json")" "$h/.claude/statusline"

echo "== HOME unset, CLAUDE_CONFIG_DIR set =="
# A container or a service unit. Naming $HOME under `set -u` ended the script
# before it created even the symlink.
cfg=$(home_dir)
out=$( cd "$here/.." && env -u HOME CLAUDE_CONFIG_DIR="$cfg" sh "$installer" 2>&1 )
check "the symlink is created" "$(readlink "$cfg/statusline-command.sh")" "$source_script"
check "and the command is absolute" "$(command_in "$cfg/settings.json")" \
  "bash \"$cfg/statusline-command.sh\""

echo "== a missing config dir is an error, not a guess =="
h=$(home_dir)
out=$(install_in "$h" "$h/nowhere"); rc=$?
equals "exit code is 1" "$rc" "1"
check "and says which directory" "$out" "no Claude config dir"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
