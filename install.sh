#!/bin/sh
# Wire this repo's statusline.sh into Claude Code.
#
# The script is *symlinked* into ~/.claude rather than copied, so a pull in
# this repo takes effect on the next render with nothing else to run, and an
# accidental edit of ~/.claude/statusline-command.sh lands in git instead of
# quietly diverging. settings.json points at whichever config directory this
# runs against -- CLAUDE_CONFIG_DIR when it is set, ~/.claude otherwise, and
# never one while linking into the other. Git Bash without developer mode has
# no symlinks and silently copies instead; that is handled below.
#
# Re-running this must be a no-op when nothing changed -- Windows needs a
# re-run after every pull, and an install script that leaves a trail of .bak
# files behind each time is one nobody re-runs.
#
# POSIX sh on purpose (no bashisms): same rule as the deploy scripts.
set -eu

# With CDPATH exported, `cd somedir` can land somewhere else entirely AND echo
# the directory it chose to stdout -- which turns every `$(cd ... && pwd)` here
# into a two-line path. Unset once, rather than guarded at each call site.
unset CDPATH
REPO=$(cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$REPO/statusline.sh"
# HOME may legitimately be unset -- a container or a service unit that sets
# CLAUDE_CONFIG_DIR and nothing else -- and under `set -u` naming it would end
# the script before it did anything at all.
HOME_DIR="${HOME:-}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
STAMP=$(date +%Y%m%d-%H%M%S)
TAB=$(printf '\t')   # the separator current_status_line puts between its two halves

[ -f "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }
[ -d "$CLAUDE_DIR" ] || { echo "no Claude config dir at $CLAUDE_DIR" >&2; exit 1; }
# Resolved before anything is derived from it. A relative or unnormalised
# CLAUDE_CONFIG_DIR works fine for creating the symlink -- and then goes into
# settings.json as a path Claude Code resolves against a working directory
# nobody chose, which is a broken status line and no error to say why.
CLAUDE_DIR=$(cd -- "$CLAUDE_DIR" && pwd) ||
  { echo "cannot enter $CLAUDE_DIR" >&2; exit 1; }
# HOME gets the same treatment, and for a sharper reason: CLAUDE_DIR has just
# been canonicalised, so comparing it against a HOME spelled with a trailing
# slash, a "..", or (Git Bash) as C:\Users\me while pwd says /c/Users/me finds
# no match -- and this machine's absolute home is then baked into settings.json,
# which is the one thing the comment below says must never happen.
if [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ]; then
  HOME_DIR=$(cd -- "$HOME_DIR" && pwd) || { echo "cannot enter $HOME_DIR" >&2; exit 1; }
fi
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
TARGET_REL=
if [ -n "$HOME_DIR" ]; then
  case "$TARGET" in
    "$HOME_DIR"/*) TARGET_REL=${TARGET#"$HOME_DIR"/} ;;
  esac
fi
if [ -n "$TARGET_REL" ]; then
  # shellcheck disable=SC2016  # the literal $HOME is the point, see above
  HOME_FORM='$HOME/'"$TARGET_REL"
else
  HOME_FORM=$TARGET
fi
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

# Reads BOTH halves of the key, tab separated. The type matters as much as the
# command now that there is a branch which keeps what it finds: write_command
# always writes {type: "command", ...}, so a statusLine with any other type is
# one Claude Code will not run, and calling that installed would be a lie told
# to somebody whose line then renders nothing.
current_status_line() { # -> "<type><tab><command>", empty when there is neither
  case "$JSON_TOOL" in
    '') ;;
    # join, not @tsv: @tsv escapes backslashes in the values it prints, so a
    # command holding one came back doubled, never compared equal to what is
    # already in the file, and was rewritten on every single run. node and
    # python return the raw string, and all three have to agree.
    jq) jq -r '[(.statusLine.type // ""), (.statusLine.command // "")] | join("\t")' \
          "$SETTINGS" 2>/dev/null ;;
    node)
      node - "$SETTINGS" 2>/dev/null <<'NODEEOF'
const fs = require("fs");
try {
  const data = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const sl = data.statusLine || {};
  console.log([sl.type || "", sl.command || ""].join("\t"));
} catch (e) { /* unreadable or not JSON: treat as "not installed" */ }
NODEEOF
      ;;
    *)
      # shellcheck disable=SC2086  # deliberate split, see the probe above
      $JSON_TOOL - "$SETTINGS" 2>/dev/null <<'PYEOF'
import json, io, sys
try:
    with io.open(sys.argv[1], encoding="utf-8") as fh:
        sl = json.load(fh).get("statusLine", {})
    print("\t".join([sl.get("type", "") or "", sl.get("command", "") or ""]))
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
      # Both failures remove the temporary file: a run that changed nothing
      # must not leave anything behind either, which is the same promise the
      # header makes about .bak files.
      jq --arg cmd "$COMMAND" \
        '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "$tmp" \
        || { rm -f "$tmp"; return 1; }
      # Never move a file that failed to parse over a working settings.json.
      jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
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
#
# The rule is deliberately narrow: keep it when it CONTAINS, verbatim, the
# command this script would write. That covers the documented case -- a
# CLAUDE_STATUSLINE_PLAIN=1 prefix, a wrapper, a redirect appended -- and
# nothing speculative.
#
# The previous attempt tried to recognise any command that "runs our script":
# a table of home spellings ($HOME, ${HOME}, ~) crossed with a table of path
# terminators. Every entry missing from either table silently destroyed
# somebody's customisation, and the tables were never going to be complete --
# "$HOME"/... closes the quote before the slash, and a command can end at a
# semicolon, a pipe or a tab. Worse, two of the spellings it accepted do not
# work at all: neither ~ nor $HOME expands inside the double quotes they sit
# in, so "already installed" was reported over a line that cannot run.
#
# Containing $COMMAND needs no tables and gets those cases right for free: the
# closing quote is part of the string, so statusline-command.sh.bak-<stamp>
# does not match, and a stale copy under /mnt/backup/... does not either. A
# command naming the script some other way that does work -- the absolute path
# instead of $HOME -- is rewritten once into this form and is then stable.
if [ ! -f "$SETTINGS" ]; then
  printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "%s"\n  }\n}\n' \
    "$(json_escape "$COMMAND")" > "$SETTINGS"
  echo "==> created $SETTINGS"
elif [ -z "$JSON_TOOL" ]; then
  # Hand-editing settings.json is exactly the kind of one-time step that goes
  # wrong quietly, so say the words rather than attempt a sed edit.
  echo "!! no jq, python3 or node found -- add this to $SETTINGS by hand:" >&2
  # printf, not echo: dash's echo interprets backslash escapes, which would
  # undo json_escape and hand the reader a snippet that does not parse.
  printf '   "statusLine": { "type": "command", "command": "%s" }\n' \
    "$(json_escape "$COMMAND")" >&2
  exit 1
else
  # `|| CURRENT_RAW=` is not decoration: a bare assignment from a command
  # substitution carries its exit status, and under `set -e` an unparseable
  # settings.json would end the script right here -- no diagnostic, no smoke
  # test, and the repair path below never reached.
  CURRENT_RAW=$(current_status_line) || CURRENT_RAW=
  case "$CURRENT_RAW" in
    *"$TAB"*) CURRENT_TYPE=${CURRENT_RAW%%"$TAB"*}; CURRENT=${CURRENT_RAW#*"$TAB"} ;;
    *)        CURRENT_TYPE=; CURRENT= ;;
  esac
  if [ "$CURRENT" = "$COMMAND" ] && [ "$CURRENT_TYPE" = command ]; then
    echo "==> settings.json already points at the status line"
  elif [ "$CURRENT_TYPE" = command ] && case "$CURRENT" in *"$COMMAND"*) true ;; *) false ;; esac; then
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
      # The backup is the file that was just put back, so keeping it would
      # leave a duplicate behind after a run that changed nothing.
      rm -f "$SETTINGS.bak-$STAMP"
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
