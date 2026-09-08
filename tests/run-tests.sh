#!/bin/bash
# Regression suite for statusline.sh. Every case here corresponds to a bug
# that actually shipped once, or to a payload shape seen in the wild:
#   * greedy sed picking a sibling object's "used_percentage"
#   * printf "%.0f" on macOS bash 3.2 (invalid number -> every gauge at 0%)
#   * "^[^}]*" anchoring silently blanking top-level scalars (cwd, cost)
#   * a lost U+E0B0 separator byte
# Run:  ./tests/run-tests.sh    (exit 0 = green)
set -u
# Both rate-limit windows render an absolute clock time, so every assertion
# about one depends on the timezone it is asserted in. Pinned for the same
# reason tools/make-preview.sh pins it: otherwise the suite passes on a laptop
# in CEST and fails on a CI runner in UTC, for no reason anyone would enjoy
# tracking down.
export TZ=UTC
here=$(cd -- "$(dirname -- "$0")" && pwd)
script="$here/../statusline.sh"
err=$(mktemp)
pass=0; fail=0

# The task segment reads Claude Code's own on-disk task list, so it depends on
# a directory rather than on a payload key. Pointing the config dir at an empty
# temp tree does two things: it keeps every OTHER assertion in this file
# independent of whether the machine running the suite happens to have a live
# task list open, and it gives the task cases somewhere to build fixtures.
CLAUDE_CONFIG_DIR=$(mktemp -d)
export CLAUDE_CONFIG_DIR

# The task segment's icon, U+2263, written in octal for the same reason the
# script writes it that way: a multibyte glyph pasted into a file is one bad
# copy away from being silently wrong, and here that would turn every task
# assertion green against the wrong string.
printf -v TASK '\342\211\243'

# Strip ANSI/OSC escapes so assertions match on the visible text only.
plain() { LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g'; }

run() { # $1 = payload; echoes the rendered line, stderr captured in $err
  # COLUMNS is unset on purpose: with it, the layout may split into two rows,
  # and every assertion in this file would depend on the size of the window
  # the suite happened to be run in. CLAUDE_STATUSLINE_PLAIN goes for the same
  # reason and a sharper one: whoever exports it is exactly the person this
  # suite must still be green for, and with it leaking in, the two assertions
  # on the default separator fail on an unmodified checkout.
  printf '%s' "$1" | env -u COLUMNS -u CLAUDE_STATUSLINE_PLAIN bash "$script" 2>"$err" | plain
}

run_at() { # $1 = COLUMNS, $2 = payload
  printf '%s' "$2" | env -u CLAUDE_STATUSLINE_PLAIN COLUMNS="$1" bash "$script" 2>"$err" | plain
}

run_raw() { # $1 = payload -- escapes NOT stripped, for colour assertions
  printf '%s' "$1" | env -u COLUMNS -u CLAUDE_STATUSLINE_PLAIN bash "$script" 2>"$err"
}

make_tasks() { # $1 = session id, $2.. = statuses -> echoes a matching payload
  # Written the way Claude Code writes them: one JSON file per task under
  # $CLAUDE_CONFIG_DIR/tasks/<list id>/, with the list id defaulting to the
  # session id. The dot-files it keeps alongside them are created too, because
  # "the segment must not count .lock as a task" is one of the assertions.
  local sid=$1; shift
  local dir="$CLAUDE_CONFIG_DIR/tasks/$sid" i=0 s
  rm -rf "$dir"; mkdir -p "$dir"
  : > "$dir/.lock"
  printf '%s' "$#" > "$dir/.highwatermark"
  for s in "$@"; do
    i=$((i + 1))
    printf '{"id":"%s","subject":"do the thing %s","description":"","status":"%s","blocks":[],"blockedBy":[]}' \
      "$i" "$i" "$s" > "$dir/$i.json"
  done
  printf '{"session_id":"%s","cwd":"/tmp"}' "$sid"
}

run_win() { # $1 = USERPROFILE, $2 = payload -- Windows needs it pinned:
  # the variable is set for real on a Windows box and absent on the CI
  # runners, and "does the home collapse" is exactly what it decides.
  printf '%s' "$2" | env -u COLUMNS -u CLAUDE_STATUSLINE_PLAIN USERPROFILE="$1" bash "$script" 2>"$err" | plain
}

run_plain() { # $1 = payload, rendered with the no-Nerd-Font escape hatch on
  printf '%s' "$1" | env -u COLUMNS CLAUDE_STATUSLINE_PLAIN=1 bash "$script" 2>"$err" | plain
}

run_at_plain() { # $1 = COLUMNS, $2 = payload -- the narrow case, hatch on
  printf '%s' "$2" | env CLAUDE_STATUSLINE_PLAIN=1 COLUMNS="$1" bash "$script" 2>"$err" | plain
}

run_flag() { # $1 = the CLAUDE_STATUSLINE_PLAIN value under test, $2 = payload
  printf '%s' "$2" | env -u COLUMNS CLAUDE_STATUSLINE_PLAIN="$1" bash "$script" 2>"$err" | plain
}

cols() { # $1 = one plain line -> its column count, independent of the locale
  # UTF-8 continuation bytes (0x80-0xbf) are dropped, which leaves exactly one
  # byte per character whether or not wc counts characters here. The bolt is
  # the one glyph that is two columns wide, so it is counted again.
  local n bolts
  n=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' ')
  # grep -c prints a count and exits 1 when it is zero, so no "|| echo 0"
  # here: that appended a second line and the arithmetic below blew up.
  bolts=$(printf '%s' "$1" | LC_ALL=C grep -c $'\342\232\241')
  echo $((n + bolts))
}

rows() { printf '%s\n' "$1" | LC_ALL=C awk 'END{print NR}'; }

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

bar() { # $1 = number of filled cells -> the 8-cell gauge as plain text
  local i out=""
  for ((i = 1; i <= 8; i++)); do
    if [ "$i" -le "$1" ]; then out+="▰"; else out+="▱"; fi
  done
  printf '%s' "$out"
}

no_stderr() { # $1 = label
  local n; n=$(wc -c < "$err" | tr -d ' ')
  if [ "$n" = "0" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s (%s bytes)\n%s\n' "$1" "$n" "$(cat "$err")"; fi
}

echo "== syntax =="
if bash -n "$script"; then pass=$((pass + 1)); echo "  ok   bash -n"; else fail=$((fail + 1)); echo "  FAIL bash -n"; fi

echo "== real payload (tests/payload-example.json) =="
out=$(run "$(cat "$here/payload-example.json")")
check "model compacted"   "$out" "Opus 5 1M"
refute "no parenthetical" "$out" "(1M context)"
check "context gauge"     "$out" "ctx $(bar 1) 17%"
check "5h gauge"          "$out" "5h $(bar 2) 23%"
check "7d gauge"          "$out" "7d $(bar 6) 73%"
check "7d reset weekday"  "$out" "7d $(bar 6) 73% ("
check "label leads"       "$out" "  ctx "
check "gauges dot-separated" "$out" "17% · 5h"
check "parenthetical then dot" "$out" ") · 7d"
check "cost truncated"    "$out" "\$9.60"
check "separator U+E0B0"  "$out" "$(printf '\356\202\260')"
check "filled cell"       "$out" "▰"
check "empty cell"        "$out" "▱"
no_stderr "no stderr"

echo "== model name compaction =="
check "window size kept"  "$(run '{"model":{"display_name":"Opus 5 (1M context)"}}')"   "Opus 5 1M"
check "other parenthetical kept" "$(run '{"model":{"display_name":"Sonnet 5 (beta)"}}')" "Sonnet 5 beta"
check "plain name untouched"     "$(run '{"model":{"display_name":"Haiku 4.5"}}')"       "Haiku 4.5"
check "missing name falls back"  "$(run '{"cwd":"/tmp"}')"                               "Claude"

echo "== percentage field is fixed width (no jitter) =="
# The label..% field must occupy the same number of columns at 4%, 40% and
# 100%, otherwise every gauge tick shoves the segments to its right sideways.
w4=$(run   '{"cwd":"/tmp","context_window":{"used_percentage":4}}')
w40=$(run  '{"cwd":"/tmp","context_window":{"used_percentage":40}}')
w100=$(run '{"cwd":"/tmp","context_window":{"used_percentage":100}}')
n4=$(printf '%s' "$w4" | wc -m | tr -d ' ')
n40=$(printf '%s' "$w40" | wc -m | tr -d ' ')
n100=$(printf '%s' "$w100" | wc -m | tr -d ' ')
# 1 and 2 digits must be identical: that is the boundary crossed early and
# often. 100% is deliberately one column wider, to keep a gap between the
# last cell and the number when both are red -- pinned here so the exception
# stays a decision rather than becoming a regression nobody notices.
if [ "$n4" = "$n40" ]; then
  pass=$((pass + 1)); printf '  ok   same width at 4%%/40%% (%s cols)\n' "$n4"
else
  fail=$((fail + 1)); printf '  FAIL width jitters at 4%%/40%%: %s / %s\n' "$n4" "$n40"
fi
if [ "$n100" = "$((n40 + 1))" ]; then
  pass=$((pass + 1)); printf '  ok   100%% is exactly one column wider (%s)\n' "$n100"
else
  fail=$((fail + 1)); printf '  FAIL 100%% should be %s cols, is %s\n' "$((n40 + 1))" "$n100"
fi
check "single digit padded" "$w4"   "$(bar 0)  4%"
check "three digits fit"    "$w100" "$(bar 8) 100%"

echo "== each gauge reads its own object (greedy-sed regression) =="
out=$(run '{"cwd":"/tmp","spend_limit":{"used_percentage":91},"context_window":{"used_percentage":17},"rate_limits":{"five_hour":{"used_percentage":23},"seven_day":{"used_percentage":73}}}')
check "ctx not 91"        "$out" "ctx $(bar 1) 17%"
check "5h not 91"         "$out" "5h $(bar 2) 23%"
check "7d not 91"         "$out" "7d $(bar 6) 73%"
refute "no 91% anywhere"  "$out" "91%"

echo "== decimal percentages (bash 3.2 float-printf regression) =="
out=$(run '{"cwd":"/tmp","context_window":{"used_percentage":91.7},"rate_limits":{"five_hour":{"used_percentage":4.2}}}')
check "91.7 rounds to 92" "$out" "ctx $(bar 7) 92%"
check "4.2 rounds to 4"   "$out" "5h $(bar 0)  4%"
no_stderr "no stderr on decimals"

echo "== missing / null resets_at =="
out=$(run '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":23},"seven_day":{"used_percentage":73}}}')
check "5h renders"        "$out" "5h $(bar 2) 23%"
check "dot with no parenthetical" "$out" "23% · 7d"
refute "no empty parens"  "$out" "()"
out=$(run '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":23,"resets_at":null}}}')
check "null resets_at ok" "$out" "5h $(bar 2) 23%"
refute "no dangling separator" "$out" "· "
refute "no null parens"   "$out" "()"
no_stderr "no stderr on null"

echo "== a past resets_at needs no clamping =="
# The countdown had to clamp at zero so a stale timestamp did not render
# negative. An absolute time has nothing to clamp: a reset that has already
# happened reads as the time it happened, which is a fact rather than a
# countdown frozen at "0m".
out=$(run '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":23,"resets_at":1000000000}}}')
check "past reset renders" "$out" "(01:46)"

echo "== degenerate payloads =="
out=$(run '{}')
check "empty object -> model fallback" "$out" "Claude"
no_stderr "no stderr on {}"
out=$(run '')
no_stderr "no stderr on empty input"

echo "== cwd handling =="
check "parents to one char"  "$(run '{"cwd":"/Users/example/repos/deep/nested/leaf-name"}')" "/U/e/r/d/n/leaf-name"
check "hidden dir keeps dot" "$(run '{"cwd":"/Users/example/.config/nvim"}')"                "/U/e/.c/nvim"
check "leaf kept whole"      "$(run '{"cwd":"/var/log/system-messages"}')"                    "/v/l/system-messages"
check "short path untouched" "$(run '{"cwd":"/tmp"}')"                                        " /tmp "
# On Windows the payload carries a native path. Splitting happens on "/", so
# without normalising it the whole thing arrives as one unshortened segment.
# The drive keeps its colon: "C" alone is not a drive -- and the components
# are joined back up with backslashes, because a Windows path written with
# forward slashes reads as some other machine's path.
win='{"cwd":"C:\\Users\\me\\repos\\thing"}'
check "windows path shortened"    "$(run_win 'C:\Users\other' "$win")"  "C:\U\m\r\thing"
refute "no forward slash on windows" "$(run_win 'C:\Users\other' "$win")" "C:/U"
# USERPROFILE is the home written the way the payload writes it; $HOME in
# Git Bash is the mount form (/c/Users/me) and never matches.
check "windows home as tilde"     "$(run_win 'C:\Users\me' "$win")"     "~\r\thing"
check "windows home itself"       "$(run_win 'C:\Users\me' '{"cwd":"C:\\Users\\me"}')" " ~ "
# A POSIX cwd must keep POSIX separators even with USERPROFILE set, which is
# precisely the situation inside Git Bash.
check "posix path unaffected by USERPROFILE" "$(run_win 'C:\Users\me' '{"cwd":"/var/log/system-messages"}')" "/v/l/system-messages"
# The guard is the drive letter, so a POSIX path containing a backslash -- a
# legal, if unpleasant, filename -- must come through untouched.
check "unix backslash left alone" "$(run '{"cwd":"/home/me/od\\dio/leaf"}')"                    "/h/m/o/leaf"
check "home as tilde"        "$(run '{"cwd":"'"$HOME"'"}')"                                   " ~ "
# bash 5.2 tilde-expands the REPLACEMENT in ${var/#pat/~}, so the old form
# silently gave back $HOME on Linux while working on macOS bash 3.2.
# shellcheck disable=SC2088  # the ~ is expected OUTPUT text, not a path
check "home subdir as tilde" "$(run '{"cwd":"'"$HOME"'/repos/thing"}')"                       "~/r/thing"
refute "no git segment outside a repo" "$(run '{"cwd":"/tmp"}')" "✓"

echo "== cost formatting =="
check "integer cost"   "$(run '{"cwd":"/tmp","cost":{"total_cost_usd":12}}')"      "\$12.00"
check "truncates"      "$(run '{"cwd":"/tmp","cost":{"total_cost_usd":8.4263}}')"  "\$8.42"
check "one decimal"    "$(run '{"cwd":"/tmp","cost":{"total_cost_usd":0.5}}')"     "\$0.50"
refute "no cost segment when absent" "$(run '{"cwd":"/tmp"}')" "\$"

echo "== model badge: fast_mode and effort =="
check "effort in the badge"  "$(run '{"model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"xhigh"}}')" "Opus 5 1M xhigh"
check "fast_mode bolt"       "$(run '{"model":{"display_name":"Opus 5"},"fast_mode":true}')"  "Opus 5 ⚡"
refute "no bolt when off"    "$(run '{"model":{"display_name":"Opus 5"},"fast_mode":false}')" "⚡"
refute "no bolt when absent" "$(run '{"model":{"display_name":"Opus 5"}}')"                   "⚡"

echo "== burn rate =="
# 9.6093421 USD over 2031010 ms of API time = 17 USD/h.
check "rate shown"        "$(run '{"cwd":"/tmp","cost":{"total_cost_usd":9.6093421,"total_api_duration_ms":2031010}}')" "\$9.60 · \$17/h"
refute "hidden under a minute of API" "$(run '{"cwd":"/tmp","cost":{"total_cost_usd":9.6,"total_api_duration_ms":30000}}')" "/h"
refute "hidden without api time"      "$(run '{"cwd":"/tmp","cost":{"total_cost_usd":9.6}}')"                             "/h"
check "cost still shown"              "$(run '{"cwd":"/tmp","cost":{"total_cost_usd":9.6}}')"                             "\$9.60"

echo "== payload shapes =="
check "pretty-printed payload" "$(run '{
  "cwd": "/tmp",
  "context_window": { "used_percentage": 17 }
}')" "ctx $(bar 1) 17%"
check "escaped quote in a value" "$(run '{"cwd":"/a/say \"hi\"/leaf"}')" "/a/s/leaf"
# The payload is untrusted text. It is read with "read", never eval, so a
# quote in a path is a character and not the start of a command.
rm -f /tmp/statusline-injection-canary
out=$(run '{"cwd":"/x/'"'"'; touch /tmp/statusline-injection-canary; echo '"'"'"}')
if [ -e /tmp/statusline-injection-canary ]; then
  fail=$((fail + 1)); echo "  FAIL a quoted path executed a command"
  rm -f /tmp/statusline-injection-canary
else
  pass=$((pass + 1)); echo "  ok   a quoted path executes nothing"
fi

echo "== git segment =="
# Everything above only ever proved the segment is ABSENT outside a repo.
git_cache_clear() { rm -f "${TMPDIR:-/tmp}"/claude-statusline-git-* 2>/dev/null; }
gitdir=$(mktemp -d)
gc() { git --no-optional-locks -C "$gitdir/work" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b main "$gitdir/remote.git" --bare 2>/dev/null
git clone -q "$gitdir/remote.git" "$gitdir/work" 2>/dev/null
if [ -d "$gitdir/work/.git" ]; then
  at_repo() { git_cache_clear; run "{\"cwd\":\"$gitdir/work\"}"; }
  echo a > "$gitdir/work/a.txt"; gc add a.txt >/dev/null; gc commit -qm one >/dev/null
  gc push -q origin main >/dev/null 2>&1
  check "clean"          "$(at_repo)" "main ✓"
  echo b > "$gitdir/work/b.txt"
  check "untracked file is dirty" "$(at_repo)" "main ✗"
  gc add b.txt >/dev/null; gc commit -qm two >/dev/null
  check "ahead"          "$(at_repo)" "main ⇡1 ✓"
  gc push -q origin main >/dev/null 2>&1; gc reset -q --hard HEAD~1 >/dev/null
  check "behind"         "$(at_repo)" "main ⇣1 ✓"
  refute "no arrow when in sync" "$(run '{"cwd":"/tmp"}')" "⇡"
  gc checkout -q --detach HEAD >/dev/null 2>&1
  out=$(at_repo)
  case $out in
    *"main"*) fail=$((fail + 1)); echo "  FAIL detached HEAD still shows a branch name" ;;
    *) pass=$((pass + 1)); echo "  ok   detached HEAD shows the object id" ;;
  esac
else
  echo "  skip  git segment (could not create a test repository)"
fi
rm -rf "$gitdir"

echo "== git cache =="
# The cache line is delimited by 0x1f, not by a tab: tab is IFS whitespace,
# so an empty field (a directory that is not a repository) used to collapse
# and shift every field after it -- /tmp came back with a git segment.
git_cache_clear
first=$(run '{"cwd":"/tmp"}')
second=$(run '{"cwd":"/tmp"}')
refute "non-repo stays non-repo, uncached" "$first"  "✓"
refute "non-repo stays non-repo, cached"   "$second" "✓"
if [ "$first" = "$second" ]; then
  pass=$((pass + 1)); echo "  ok   cached render matches the live one"
else
  fail=$((fail + 1)); printf '  FAIL cache changed the render\n     live:   %s\n     cached: %s\n' "$first" "$second"
fi
if ls "${TMPDIR:-/tmp}"/claude-statusline-git-* >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "  ok   cache file written"
else
  fail=$((fail + 1)); echo "  FAIL no cache file written"
fi
git_cache_clear

echo "== layout: one row, or two when one will not fit =="
# Claude Code captures the output rather than attaching a terminal, so it
# exports COLUMNS instead. Without COLUMNS the layout has to stay on one row:
# the preview generator relies on that to produce a deterministic image.
# Both resets are absolute now, so both can be fixed epochs -- the 5h one used
# to be "now + 9210" so that the countdown rendered a realistic "2h 33m", and
# a payload that depends on the current clock is a payload that renders
# something different every run. Under the pinned TZ these are "10:40" and
# "fri 00:00".
wide='{"cwd":"/x/project","model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":17},"cost":{"total_cost_usd":9.6093421,"total_api_duration_ms":2031010},"rate_limits":{"five_hour":{"used_percentage":23,"resets_at":1788777600},"seven_day":{"used_percentage":73,"resets_at":4102444800}}}'

check_rows() { # $1 = label, $2 = output, $3 = expected row count
  local got; got=$(rows "$2")
  if [ "$got" = "$3" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s: %s rows, want %s\n%s\n' "$1" "$got" "$3" "$2"; fi
}

check_fits() { # $1 = label, $2 = output, $3 = COLUMNS
  local line over=0 w
  while IFS= read -r line; do
    w=$(cols "$line")
    [ "$w" -gt "$3" ] && { over=1; printf '     %s cols > %s: %s\n' "$w" "$3" "$line"; }
  done <<< "$2"
  if [ "$over" = "0" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; fi
}

check_rows "no COLUMNS -> one row"  "$(run "$wide")"        1
check_rows "wide terminal -> one row" "$(run_at 200 "$wide")" 1
out=$(run_at 92 "$wide")
check_rows "92 columns -> two rows" "$out" 2
check_fits "92: every row fits"     "$out" 92
check "identity row keeps the model"  "$out" "Opus 5 1M xhigh"
check "gauge row keeps the gauges"    "$out" "ctx $(bar 1) 17%"
check "92 still shows the reset time" "$out" "23% (10:40)"
out=$(run_at 70 "$wide")
check_rows "70 columns -> two rows" "$out" 2
check_fits "70: every row fits"     "$out" 70
refute "70 sheds the 7d parenthetical" "$out" "(fri"
refute "70 sheds the 5h parenthetical" "$out" "(10:40"
check "70 keeps every gauge"         "$out" "7d $(bar 6) 73%"
# Below about 58 columns the gauge row cannot shrink further -- the bars
# themselves are what is left -- so the identity row is the only one that
# can still give ground, and it gives up the burn rate.
out=$(run_at 45 "$wide")

refute "45 sheds the burn rate"      "$out" "/h"
check "45 keeps the cost"            "$out" "\$9.60"

echo "== a nonsense reset timestamp cannot stretch the line =="
# resets_at in the year 2100 rendered as "(642679h 48m)" and blew the line out
# by ten columns. The countdown guarded against that by refusing to render
# anything beyond a day. Showing WHEN instead of HOW LONG makes the whole
# failure mode structurally impossible: "(HH:MM)" is seven columns no matter
# what the timestamp claims, so nothing has to be suppressed to stay in width.
absurd='{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":23,"resets_at":4102444800}}}'
check  "absurd reset still renders" "$(run "$absurd")" "(00:00)"
refute "no runaway countdown"       "$(run "$absurd")" "h)"
check  "gauge still rendered"       "$(run "$absurd")" "5h $(bar 2) 23%"

echo "== task list segment =="
# The list lives on disk and the payload only names it, so "no directory" is
# the common case (no task list open) and must render nothing at all rather
# than an empty or zeroed segment.
none='{"session_id":"11111111-1111-1111-1111-111111111111","cwd":"/tmp"}'
refute "no list on disk, no segment" "$(run "$none")" "$TASK "
no_stderr "missing list is not an error"

p=$(make_tasks 22222222-2222-2222-2222-222222222222 \
      completed completed completed in_progress pending pending pending)
check "counts completed over total" "$(run "$p")" "$TASK 3/7"

# The segment tells the layout how wide it is, with the escapes excluded by
# hand. A number that does not match what actually renders is invisible until
# much later, as a two-row split that fires at the wrong terminal size -- so
# it is measured against a run of the same payload without the list, and the
# expected growth is the segment plus its separator.
grew=$(( $(cols "$(run "$p")") - $(cols "$(run '{"cwd":"/tmp"}')") ))
if [ "$grew" = "8" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "declared width matches rendered"
else
  fail=$((fail + 1)); printf '  FAIL %s (grew %s, want 8)\n' "declared width matches rendered" "$grew"
fi

# ...and the declared number is what the split reads, so it is also exercised
# through the layout: an understated width overruns the row, which check_fits
# is what catches.
wide_tasks=${wide%\}}',"session_id":"22222222-2222-2222-2222-222222222222"}'
check_fits "task row still fits at 92" "$(run_at 92 "$wide_tasks")" 92
check_fits "task row still fits at 70" "$(run_at 70 "$wide_tasks")" 70
check "task survives the narrow layout" "$(run_at 70 "$wide_tasks")" "$TASK 3/7"

# The dot-files Claude Code keeps in the same directory (.lock, .highwatermark)
# are not tasks. Counting them inflated the total by two.
p=$(make_tasks 33333333-3333-3333-3333-333333333333 in_progress pending)
check "dot-files are not tasks" "$(run "$p")" "$TASK 0/2"

# A directory holding only the dot-files is what Claude Code leaves behind when
# every task completed and it reset the list. That is "no list", not "0/0".
empty_dir=$CLAUDE_CONFIG_DIR/tasks/44444444-4444-4444-4444-444444444444
mkdir -p "$empty_dir"; : > "$empty_dir/.lock"; printf '9' > "$empty_dir/.highwatermark"
refute "reset list renders nothing" \
  "$(run '{"session_id":"44444444-4444-4444-4444-444444444444","cwd":"/tmp"}')" "$TASK "

# The session id comes out of the payload, which is untrusted text. Claude Code
# maps every character outside [a-zA-Z0-9_-] to "-" before using it as a
# directory name; matching that is what makes the lookup find the real list,
# and it is also what stops "../.." from being a path at all.
p=$(make_tasks a-b-c completed pending)
check "session id sanitised like upstream" \
  "$(run '{"session_id":"a.b/c","cwd":"/tmp"}')" "$TASK 1/2"
refute "no traversal out of the tasks dir" \
  "$(run '{"session_id":"../../etc","cwd":"/tmp"}')" "$TASK "

# CLAUDE_CODE_TASK_LIST_ID overrides the session id upstream, so it has to
# override it here too, or a team list renders the wrong counts.
p=$(make_tasks shared-list completed completed pending)
out=$(printf '%s' '{"session_id":"55555555-5555-5555-5555-555555555555","cwd":"/tmp"}' \
  | env -u COLUMNS -u CLAUDE_STATUSLINE_PLAIN CLAUDE_CODE_TASK_LIST_ID=shared-list bash "$script" 2>"$err" | plain)
check "task list id env wins" "$out" "$TASK 2/3"

echo "== task count colour carries the state =="
# Green when something is actually in progress, grey when the list is open but
# nothing is moving -- which is the reading worth having, because it means the
# work stalled. 34;197;94 is the gradient's first stop and appears nowhere
# else: the gauge cells start at 84;193;73.
p=$(make_tasks 66666666-6666-6666-6666-666666666666 completed in_progress pending)
check  "in progress is green"  "$(run_raw "$p")" "38;2;34;197;94"
p=$(make_tasks 77777777-7777-7777-7777-777777777777 completed pending pending)
refute "stalled list is not green" "$(run_raw "$p")" "38;2;34;197;94"
check  "stalled list still counts" "$(run "$p")" "$TASK 1/3"

# Pretty-printed task files (the payload arrives both ways, and nothing
# promises these are one line each).
multi_dir=$CLAUDE_CONFIG_DIR/tasks/88888888-8888-8888-8888-888888888888
rm -rf "$multi_dir"; mkdir -p "$multi_dir"
printf '{\n  "id": "1",\n  "subject": "x",\n  "status": "completed"\n}\n' > "$multi_dir/1.json"
printf '{\n  "id": "2",\n  "subject": "y",\n  "status": "pending"\n}\n'   > "$multi_dir/2.json"
check "pretty-printed files count once" \
  "$(run '{"session_id":"88888888-8888-8888-8888-888888888888","cwd":"/tmp"}')" "$TASK 1/2"

# CRLF, because on Windows everything eventually is. The counting reads the
# files line by line and joins them, which moves the \r from the harmless end
# of a line into the middle of the string -- so it is stripped, and both the
# one-line and the indented shape are pinned here.
crlf_dir=$CLAUDE_CONFIG_DIR/tasks/99999999-9999-9999-9999-999999999999
rm -rf "$crlf_dir"; mkdir -p "$crlf_dir"
printf '{"id":"1","status":"completed"}\r\n'                        > "$crlf_dir/1.json"
printf '{"id":"2","status":"in_progress"}\r\n'                      > "$crlf_dir/2.json"
printf '{\r\n  "id": "3",\r\n  "status": "pending"\r\n}\r\n'      > "$crlf_dir/3.json"
crlf=$(run '{"session_id":"99999999-9999-9999-9999-999999999999","cwd":"/tmp"}')
check "CRLF files count correctly" "$crlf" "$TASK 1/3"
check "CRLF list still reads as active" "$(run_raw '{"session_id":"99999999-9999-9999-9999-999999999999","cwd":"/tmp"}')" "38;2;34;197;94"

# Claude Code deletes every task file the moment the list resets, which can
# land between the glob and the read. A file that cannot be opened must cost
# nothing but its own count -- and above all must not print, because a status
# line writing to stderr ends up in the session log. The redirect order in the
# script is what makes this pass: "< file 2>/dev/null" reports the failure.
race_dir=$CLAUDE_CONFIG_DIR/tasks/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
rm -rf "$race_dir"; mkdir -p "$race_dir"
printf '{"id":"1","status":"completed"}' > "$race_dir/1.json"
printf '{"id":"2","status":"pending"}'   > "$race_dir/2.json"
printf '{"id":"3","status":"pending"}'   > "$race_dir/3.json"
chmod 000 "$race_dir/3.json"
race=$(run '{"session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","cwd":"/tmp"}')
check "unreadable task still counted in the total" "$race" "$TASK 1/3"
no_stderr "an unreadable task file prints nothing"
chmod 644 "$race_dir/3.json"

echo "== the line without a Nerd Font (CLAUDE_STATUSLINE_PLAIN) =="
# U+E0B0 is the line's only private-use codepoint, and the private use area is
# not empty on Windows: Wingdings, Wingdings 2, Wingdings 3 and Webdings cover
# U+F020-U+F0FF, and Segoe UI Symbol carries U+E0B0 itself. So a missing Nerd
# Font does not draw an honest tofu box -- it draws a plausible wrong glyph
# from whatever font DirectWrite falls back to, which nobody reads as "missing
# font". The escape hatch has to hold two things at once: the arrow is gone,
# and the rest of the line is untouched.
#
# This block sits before the fixture teardown on purpose. Rendered after it,
# both sides would be missing the task segment -- the newest thing on the
# line -- and the comparison would be made on a line one segment shorter than
# the one anybody actually looks at.
make_tasks 00000000-0000-0000-0000-000000000000 completed in_progress pending >/dev/null
pe=$(cat "$here/payload-example.json")
dflt=$(run "$pe")
pln=$(run_plain "$pe")

check  "plain uses U+258C"            "$pln"  "$(printf '\342\226\214')"
refute "plain drops U+E0B0"           "$pln"  "$(printf '\356\202\260')"
check  "default keeps U+E0B0"         "$dflt" "$(printf '\356\202\260')"
check  "plain keeps the gauges"       "$pln"  "ctx $(bar 1) 17%"
check  "plain keeps the cost"         "$pln"  "\$9.60"
check  "plain keeps the task segment" "$pln"  "$TASK 1/3"

# Bracketed because check() is a substring test and "10" sits inside "100".
check "plain is exactly as wide" "[$(cols "$dflt")]" "[$(cols "$pln")]"

# ...and therefore the row split fires at the same width, not one column off.
check "plain splits into the same rows" \
  "[$(rows "$(run_at 100 "$pe")")]" "[$(rows "$(run_at_plain 100 "$pe")")]"

# The hatch is opt-in, and opt-in is a list of values rather than "not empty":
# a stray "export CLAUDE_STATUSLINE_PLAIN=" must not change everyone's line,
# and neither must the obvious way to ask for it to be off.
check "empty value is not opt-in" "$(run_flag ''  "$pe")" "$(printf '\356\202\260')"
check "0 is not opt-in"           "$(run_flag 0   "$pe")" "$(printf '\356\202\260')"
check "1 is opt-in"               "$(run_flag 1   "$pe")" "$(printf '\342\226\214')"

rm -rf "$CLAUDE_CONFIG_DIR"
rm -f "$err"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
