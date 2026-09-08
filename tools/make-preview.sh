#!/bin/sh
# Regenerate docs/preview.svg (the image in the README) from the live script.
# Run it after any change that alters what the line looks like.
set -eu
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$REPO/docs/preview.svg"
mkdir -p "$REPO/docs"

# `command -v python3` is not evidence that python3 runs: Windows ships an App
# Execution Alias of that name that exits non-zero after advertising the
# Microsoft Store. install.sh probes the same way and for the same reason, but
# the stakes here are sharper. Every render below used to open its output file
# through a shell redirection, and a redirection TRUNCATES before the command
# on the left is even started -- so on a machine with no Python this script did
# not fail to regenerate the images, it emptied the committed ones. Observed on
# a stock Windows: "517 deletions" in docs/preview.svg, which looks like a
# legitimate diff and gets committed with everything else.
PY=
for candidate in python3 python "py -3"; do
  # shellcheck disable=SC2086  # deliberate split: "py -3" is command + flag
  if $candidate -c "import sys" >/dev/null 2>&1; then
    PY=$candidate
    break
  fi
done
if [ -z "$PY" ]; then
  echo "make-preview: no working Python found (tried python3, python, py -3)." >&2
  echo "  tools/ansi-to-svg.py needs one. Nothing was written; docs/ is untouched." >&2
  exit 1
fi

# ...and even with an interpreter, the destination is never the redirection
# target. Rendering goes to a temporary file that replaces the image only once
# it is complete, so no failure of any kind -- not just a missing Python --
# can leave a half-written SVG where a committed one used to be.
render() { # $1 = destination path, $2 = title; the ANSI lines arrive on stdin
  dest=$1
  title=$2
  tmp="$dest.tmp.$$"
  # shellcheck disable=SC2086  # deliberate split, see the probe above
  if ! $PY "$REPO/tools/ansi-to-svg.py" --title "$title" > "$tmp"; then
    rm -f "$tmp"
    echo "make-preview: rendering $dest failed; it was left untouched." >&2
    exit 1
  fi
  mv "$tmp" "$dest"
}

# Pinned so the output is reproducible; see the note in preview.sh. TZ is
# pinned too: the 7d window renders an absolute weekday and clock time, so
# without this the image differs between a laptop in CEST and a CI runner in
# UTC, and the drift check in CI would fail on every run for no reason.
PREVIEW_NOW=1788606000
TZ=Europe/Rome
export PREVIEW_NOW TZ
# Not a pin but the same purpose: exported, CLAUDE_STATUSLINE_PLAIN would draw
# U+258C separators into docs/, and the drift check in CI would then fail for
# everyone whose shell does not happen to have it set.
unset CLAUDE_STATUSLINE_PLAIN

# The rendered line depends on the filesystem: the directory shown is $PWD and
# the git segment reflects whatever repository that is. Both differ between a
# laptop and a CI checkout, which would make the drift check in CI fail forever
# for reasons that have nothing to do with the design.
#
# So the preview renders against a repository this script builds itself, at a
# fixed path, in a known state: one commit ahead of its remote, one untracked
# file so the segment reads dirty. Deterministic on any machine, and it
# exercises the git segment instead of hiding it.
DEMO=/tmp/claude-statusline-preview
rm -rf "$DEMO" "$DEMO.remote.git"
git init -q -b main --bare "$DEMO.remote.git"
git clone -q "$DEMO.remote.git" "$DEMO" 2>/dev/null
git -C "$DEMO" -c user.name=preview -c user.email=preview@local commit -q --allow-empty -m base
git -C "$DEMO" push -q origin main
git -C "$DEMO" -c user.name=preview -c user.email=preview@local commit -q --allow-empty -m ahead
: > "$DEMO/draft.txt"
PREVIEW_CWD="$DEMO"
export PREVIEW_CWD

# The task segment only exists while a task list does, so the images that are
# meant to show a working session ask for one. Fixed at 3 of 7 with the fourth
# in progress: a state a real session passes through, and enough of both halves
# that the count reads as a count.
PREVIEW_TASKS=3/7
export PREVIEW_TASKS

# One typical line, then the gradient sweep, in a single image.
{
  sh "$REPO/preview.sh" 17 23 73
  sh "$REPO/preview.sh" --sweep
} | render "$OUT" "claude-statusline — a normal session, then the same line at rising usage"

DEMO2=$DEMO   # kept for the narrow-layout image further down
unset PREVIEW_CWD

echo "==> $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"

# A second image for the README: the same line over paths of different shapes,
# so the brightness rule that marks the shortening is visible side by side.
PATHS_OUT="$REPO/docs/preview-paths.svg"
# Paths picked so they exist on no machine that runs this: an existing
# repository would add a git segment here on one machine and not on another,
# and the image has to be byte-identical everywhere for the CI check to mean
# anything. $HOME is included on purpose -- it is the one that renders as a
# bare "~".
unset PREVIEW_TASKS   # this image is about the paths; nothing else should move
for d in "$HOME/repos/demo-project" \
         "$HOME/work/acme/api/src/handlers" \
         "$HOME/.config/demo-editor" \
         "/var/log/demo" \
         "$HOME"; do
  PREVIEW_CWD="$d" sh "$REPO/preview.sh" 17 23 73
done | render "$PATHS_OUT" "dim = abbreviated, bright bold = the leaf, whole"

echo "==> $PATHS_OUT ($(wc -c < "$PATHS_OUT" | tr -d ' ') bytes)"

# A third image: the same reading in a narrow pane, where the line splits.
NARROW_OUT="$REPO/docs/preview-narrow.svg"
PREVIEW_TASKS=3/7
export PREVIEW_TASKS
PREVIEW_CWD="$DEMO2"
export PREVIEW_CWD
{
  PREVIEW_COLUMNS=92 sh "$REPO/preview.sh" 17 23 73
  PREVIEW_COLUMNS=70 sh "$REPO/preview.sh" 17 23 73
} | render "$NARROW_OUT" "the same line at 92 columns, then at 70 where the reset times go"
unset PREVIEW_CWD

echo "==> $NARROW_OUT ($(wc -c < "$NARROW_OUT" | tr -d ' ') bytes)"

rm -rf "$DEMO" "$DEMO.remote.git"
