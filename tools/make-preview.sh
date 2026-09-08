#!/bin/sh
# Regenerate docs/preview.svg (the image in the README) from the live script.
# Run it after any change that alters what the line looks like.
set -eu
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$REPO/docs/preview.svg"
mkdir -p "$REPO/docs"

# Pinned so the output is reproducible; see the note in preview.sh. TZ is
# pinned too: the 7d window renders an absolute weekday and clock time, so
# without this the image differs between a laptop in CEST and a CI runner in
# UTC, and the drift check in CI would fail on every run for no reason.
PREVIEW_NOW=1788606000
TZ=Europe/Rome
export PREVIEW_NOW TZ

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
} | python3 "$REPO/tools/ansi-to-svg.py" \
      --title "claude-statusline — a normal session, then the same line at rising usage" > "$OUT"

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
done | python3 "$REPO/tools/ansi-to-svg.py"          --title "dim = abbreviated, bright bold = the leaf, whole" > "$PATHS_OUT"

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
} | python3 "$REPO/tools/ansi-to-svg.py" \
      --title "the same line at 92 columns, then at 70 where the reset times go" > "$NARROW_OUT"
unset PREVIEW_CWD

echo "==> $NARROW_OUT ($(wc -c < "$NARROW_OUT" | tr -d ' ') bytes)"

rm -rf "$DEMO" "$DEMO.remote.git"
