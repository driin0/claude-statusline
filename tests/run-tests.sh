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

# Strip ANSI/OSC escapes so assertions match on the visible text only.
plain() { LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g'; }

run() { # $1 = payload; echoes the rendered line, stderr captured in $err
  # COLUMNS is unset on purpose: with it, the layout may split into two rows,
  # and every assertion in this file would depend on the size of the window
  # the suite happened to be run in.
  printf '%s' "$1" | env -u COLUMNS bash "$script" 2>"$err" | plain
}

run_at() { # $1 = COLUMNS, $2 = payload
  printf '%s' "$2" | COLUMNS="$1" bash "$script" 2>"$err" | plain
}

run_win() { # $1 = USERPROFILE, $2 = payload -- Windows needs it pinned:
  # the variable is set for real on a Windows box and absent on the CI
  # runners, and "does the home collapse" is exactly what it decides.
  printf '%s' "$2" | env -u COLUMNS USERPROFILE="$1" bash "$script" 2>"$err" | plain
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

rm -f "$err"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
