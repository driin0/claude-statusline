#!/bin/bash
# Render the status line without running Claude Code, so the layout and the
# gauge gradient can be checked in one second instead of one session.
#
#   ./preview.sh             sample values
#   ./preview.sh 17 23 73    explicit ctx / 5h / 7d percentages
#   ./preview.sh --sweep     the same line at rising usage (gradient check)
#
# PREVIEW_COLUMNS=92 renders the two-row layout instead of the single row.
#
# PREVIEW_CWD overrides the directory shown, for checking the path shortening
# on paths you are not standing in.
#
# The payload is built here rather than read from tests/payload-example.json
# because the reset timestamps have to be in the future for the "(2h 33m)"
# countdown to show anything; the fixture's are frozen. Keep the shape in
# sync with tests/payload-example.json if the script starts reading new keys.
set -u
here=$(cd -- "$(dirname -- "$0")" && pwd)

make_payload() { # $1 ctx%, $2 5h%, $3 7d%
  local now five seven
  # BOTH windows hang off PREVIEW_NOW, which tools/make-preview.sh pins, so
  # regenerating the images produces a byte-identical file instead of a diff
  # whose only content is what time it is.
  #
  # It is tempting to exempt the 5h window, since a payload built from the
  # real clock is easier to reason about. That is safe only for a COUNTDOWN,
  # which renders the same string whenever you run it. Both windows show an
  # absolute time, which moves every minute, so an unpinned clock here makes
  # the images differ between the commit and the CI run that checks them --
  # an intermittent failure depending on which minute each landed in.
  now=${PREVIEW_NOW:-$(date +%s)}
  five=$((now + 9210))
  seven=$((now + 187200))
  cat <<EOF
{"cwd":"${PREVIEW_CWD:-$PWD}",
 "model":{"id":"claude-opus-5[1m]","display_name":"Opus 5 (1M context)"},
 "version":"2.1.263",
 "effort":{"level":"xhigh"},
 "fast_mode":false,
 "cost":{"total_cost_usd":9.6093421,"total_api_duration_ms":2031010},
 "context_window":{"context_window_size":1000000,
   "current_usage":{"input_tokens":2,"output_tokens":837},
   "used_percentage":$1,"remaining_percentage":$((100 - $1))},
 "rate_limits":{"five_hour":{"used_percentage":$2,"resets_at":$five},
                "seven_day":{"used_percentage":$3,"resets_at":$seven}}}
EOF
}

# COLUMNS is passed explicitly, and empty unless PREVIEW_COLUMNS says
# otherwise: an inherited COLUMNS would split the line into two rows and make
# this output depend on the window it was run in. Set PREVIEW_COLUMNS to see
# the narrow layout.
render() {
  make_payload "$1" "$2" "$3" | COLUMNS="${PREVIEW_COLUMNS:-}" bash "$here/statusline.sh"
  echo
}

case ${1:-} in
  --sweep)
    for p in 4 18 33 47 61 76 88 97; do render "$p" "$p" "$p"; done
    ;;
  --help|-h)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    render "${1:-17}" "${2:-23}" "${3:-73}"
    ;;
esac
