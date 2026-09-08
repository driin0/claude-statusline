#!/bin/sh
# Wire this repo's statusline.sh into Claude Code.
#
# The script is *symlinked* into ~/.claude rather than copied, so a pull in
# this repo takes effect on the next render with nothing else to run, and an
# accidental edit of ~/.claude/statusline-command.sh lands in git instead of
# quietly diverging. settings.json keeps pointing at the ~/.claude path, which
# is what Claude Code writes there itself. Git Bash without developer mode has
# no symlinks and silently copies instead; that is handled below.
#
# Re-running this must be a no-op when nothing changed -- Windows needs a
# re-run after every pull, and an install script that leaves a trail of .bak
# files behind each time is one nobody re-runs.
#
# POSIX sh on purpose (no bashisms): same rule as the deploy scripts.
set -eu

REPO=$(cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$REPO/statusline.sh"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STAMP=$(date +%Y%m%d-%H%M%S)

[ -f "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }
[ -d "$CLAUDE_DIR" ] || { echo "no Claude config dir at $CLAUDE_DIR" >&2; exit 1; }
# Resolved before anything is derived from it. A relative or unnormalised
# CLAUDE_CONFIG_DIR works fine for creating the symlink -- and then goes into
# settings.json as a path Claude Code resolves against a working directory
# nobody chose, which is a broken status line and no error to say why.
CLAUDE_DIR=$(cd -- "$CLAUDE_DIR" && pwd)
chmod +x "$SOURCE"

TARGET="$CLAUDE_DIR/statusline-command.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

# The command is derived from CLAUDE_DIR rather than written out, because this
# script honours CLAUDE_CONFIG_DIR everywhere else: it used to link the script
# into that directory and then tell settings.json to run "$HOME/.claude/..."
# -- a path it had not created. On a machine that only ever used
# CLAUDE_CONFIG_DIR that file does not exist, and a status line that cannot be
# executed renders nothing, with no error anywhere to say why.
#
# $HOME stays UNexpanded when the target is under it: Claude Code expands the
# command itself, and baking in this machine's home directory would make the
# file wrong the moment the account changes. Outside the home there is nothing
# to abbreviate against, so the absolute path goes in as it is.
HOME_FORM=$TARGET
# shellcheck disable=SC2016  # the literal $HOME is the point, see above
case "$TARGET" in
  "$HOME"/*) HOME_FORM='$HOME/'"${TARGET#"$HOME"/}" ;;
esac
COMMAND="bash \"$HOME_FORM\""

# --- 1. the script ---------------------------------------------------------
# Two "already installed" shapes, because `ln -s` under Git Bash produces a
# copy without saying so: the symlink pointing here, and a copy whose bytes
# still match.
if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$SOURCE" ]; then
  echo "==> symlink already in place: $TARGET"
elif [ -f "$TARGET" ] && [ ! -L "$TARGET" ] && cmp -s "$SOURCE" "$TARGET"; then
  echo "==> copy already up to date: $TARGET"
else
  if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
    cp "$TARGET" "$TARGET.bak-$STAMP"
    echo "==> backed up the previous script to $TARGET.bak-$STAMP"
  fi
  ln -sfn "$SOURCE" "$TARGET"
  if [ -L "$TARGET" ]; then
    echo "==> linked $TARGET -> $SOURCE"
  else
    echo "==> copied $SOURCE -> $TARGET"
    echo "    (no symlink support here -- re-run this after every git pull)"
  fi
fi

# --- 2. settings.json ------------------------------------------------------
# Only the statusLine key is touched; everything else in the file is kept.
#
# Finding an interpreter that can edit JSON is the awkward part on Windows.
# `command -v python3` is not evidence that python3 runs: Windows ships an App
# Execution Alias of that exact name which is on PATH, resolves, and then
# exits non-zero after advertising the Microsoft Store. So probe by running.
PY=
for candidate in python3 python "py -3"; do
  # shellcheck disable=SC2086  # deliberate split: "py -3" is command + flag
  if $candidate -c "import json" >/dev/null 2>&1; then
    PY=$candidate
    break
  fi
done

# One tool does both the read and the write, so the "already installed" check
# is never the thing that is missing.
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif [ -n "$PY" ]; then
  JSON_TOOL=$PY
elif command -v node >/dev/null 2>&1; then
  # Often the only one standing on Windows: a machine running Claude Code
  # usually has Node, while jq and a real Python both had to be installed.
  JSON_TOOL=node
else
  JSON_TOOL=
fi

current_command() {
  case "$JSON_TOOL" in
    '') ;;
    jq) jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null ;;
    node)
      node - "$SETTINGS" 2>/dev/null <<'NODEEOF'
const fs = require("fs");
try {
  const data = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  console.log((data.statusLine && data.statusLine.command) || "");
} catch (e) { /* unreadable or not JSON: treat as "not installed" */ }
NODEEOF
      ;;
    *)
      # shellcheck disable=SC2086  # deliberate split, see the probe above
      $JSON_TOOL - "$SETTINGS" 2>/dev/null <<'PYEOF'
import json, io, sys
try:
    with io.open(sys.argv[1], encoding="utf-8") as fh:
        print(json.load(fh).get("statusLine", {}).get("command", ""))
except Exception:
    pass
PYEOF
      ;;
  esac
}

write_command() {
  case "$JSON_TOOL" in
    jq)
      tmp="$SETTINGS.tmp.$$"
      jq --arg cmd "$COMMAND" \
        '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "$tmp" || return 1
      # Never move a file that failed to parse over a working settings.json.
      jq -e . "$tmp" >/dev/null || return 1
      mv "$tmp" "$SETTINGS"
      ;;
    node)
      node - "$SETTINGS" "$COMMAND" <<'NODEEOF'
const fs = require("fs");
const [path, command] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(path, "utf8"));
data.statusLine = { type: "command", command: command };
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
NODEEOF
      ;;
    *)
      # json.load/json.dump cannot produce invalid JSON the way a sed edit can.
      # shellcheck disable=SC2086  # deliberate split, see the probe above
      $JSON_TOOL - "$SETTINGS" "$COMMAND" <<'PYEOF'
import json, sys, io
path, command = sys.argv[1], sys.argv[2]
with io.open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["statusLine"] = {"type": "command", "command": command}
with io.open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PYEOF
      ;;
  esac
}

# A fresh settings.json is written without a JSON tool, so the one string that
# goes into it is escaped here. It is only ever `bash "<path>"`, but a Windows
# CLAUDE_CONFIG_DIR is a native path full of backslashes.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# "Installed" means the command runs our script, not that it matches ours byte
# for byte. Part 1 above already knows this -- it accepts the symlink *or* a
# copy with the same bytes -- and this is the same idea for the command: a
# prefix (CLAUDE_STATUSLINE_PLAIN=1), a wrapper, another interpreter are all
# somebody's deliberate choice, and re-running an installer is not a request
# to undo them. The old check compared the whole string, so any of those was
# silently rewritten back on the next run, leaving only a .bak behind.
references_target() { # $1 = the command currently in settings.json
  case "$1" in
    '') return 1 ;;
    *"$TARGET"*)    return 0 ;;   # absolute, however it was written
    *"$HOME_FORM"*) return 0 ;;   # with $HOME left for Claude Code to expand
    *) return 1 ;;
  esac
}

if [ ! -f "$SETTINGS" ]; then
  printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "%s"\n  }\n}\n' \
    "$(json_escape "$COMMAND")" > "$SETTINGS"
  echo "==> created $SETTINGS"
elif [ -z "$JSON_TOOL" ]; then
  # Hand-editing settings.json is exactly the kind of one-time step that goes
  # wrong quietly, so say the words rather than attempt a sed edit.
  echo "!! no jq, python3 or node found -- add this to $SETTINGS by hand:" >&2
  echo "   \"statusLine\": { \"type\": \"command\", \"command\": \"$(json_escape "$COMMAND")\" }" >&2
  exit 1
else
  CURRENT=$(current_command)
  if [ "$CURRENT" = "$COMMAND" ]; then
    echo "==> settings.json already points at the status line"
  elif references_target "$CURRENT"; then
    # Said out loud, because "already installed" and "installed differently
    # from how I would have done it" are worth telling apart when the line
    # then renders in a way the README did not describe.
    echo "==> settings.json already runs the status line (custom command kept):"
    echo "    $CURRENT"
  else
    cp "$SETTINGS" "$SETTINGS.bak-$STAMP"
    if write_command; then
      echo "==> updated $SETTINGS via $JSON_TOOL (backup: $SETTINGS.bak-$STAMP)"
    else
      cp "$SETTINGS.bak-$STAMP" "$SETTINGS"
      echo "!! could not update $SETTINGS -- it has been left unchanged" >&2
      exit 1
    fi
  fi
fi

# --- 3. smoke test ---------------------------------------------------------
echo "==> rendering with tests/payload-example.json:"
printf '   '
bash "$SOURCE" < "$REPO/tests/payload-example.json"
echo
echo "==> done. The new line appears at the next Claude Code render."
