#!/bin/bash
# Claude Code status line -- Powerlevel10k-inspired segments (layout B).
# Reads the session JSON from stdin and renders, left to right:
#   model | cwd | git branch+status | task list | metrics (ctx/5h/7d) | cost
# Segment/separator colors are 256-color (38;5;N / 48;5;N), copied from
# ~/.p10k.zsh, so they follow the terminal's ANSI theme like p10k does. The
# metrics segment's gauge cells use 24-bit truecolor (38;2;R;G;Bm) for a
# position-based (not value-based) 4-stop gradient across the 8 cells.
# No external deps beyond bash/git/sed, all shipped on macOS.
# Tracked in the claude-statusline repo: edit it there and run install.sh --
# the copy under ~/.claude is a symlink, so a hand-edit there edits the repo.
#
# NOTE on the separator glyph: U+E0B0 (the solid powerline arrow), i.e. the
# exact same codepoint as POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR in ~/.p10k.zsh,
# so the status line and the shell prompt use an identical shape. It needs
# the Nerd Font the user already has (POWERLEVEL9K_MODE=nerdfont-complete).
# Set CLAUDE_STATUSLINE_PLAIN=1 to render the line without a Nerd Font at all.

# --- Field extraction: one awk pass over the payload ------------------------
# This used to be a dozen "printf | sed | head" pipelines, about thirty forks
# and 28 of the render's 48 ms. One awk process does the same work in 2.9 ms.
#
# The values come back newline-separated in a fixed order and are read with
# "read", never eval: a payload value is untrusted text, and a single quote in
# a path ("~/notes/don't-delete") would turn an eval into command execution.
# A JSON string cannot contain a raw newline, so line-per-value is unambiguous.
#
# Two shapes need different handling, and getting it wrong is silent:
#  * keys that are unique in the whole document (display_name, cwd,
#    total_cost_usd, fast_mode) are matched anywhere;
#  * keys repeated across sibling objects (used_percentage lives in
#    context_window AND in every rate_limits sub-object) are read only after
#    obj() has sliced out the parent, so a match cannot cross into a sibling.
#    obj() strips the nested "current_usage" object first, because otherwise
#    its closing brace would end the slice before used_percentage.
parsed=$(awk '
function jstr(s, key,   v) {
  if (!match(s, "\"" key "\"[ \t]*:[ \t]*\"([^\"\\\\]|\\\\.)*\"")) return ""
  v = substr(s, RSTART, RLENGTH)
  sub(/^[^:]*:[ \t]*"/, "", v)
  sub(/"$/, "", v)
  gsub(/\\"/, "\"", v)          # unescape what JSON escapes: \" \/ \\
  gsub(/\\\//, "/", v)
  gsub(/\\\\/, "\\", v)
  return v
}
function jnum(s, key,   v) {
  if (!match(s, "\"" key "\"[ \t]*:[ \t]*-?[0-9]+(\\.[0-9]+)?")) return ""
  v = substr(s, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*/, "", v); return v
}
function jbool(s, key,   v) {
  if (!match(s, "\"" key "\"[ \t]*:[ \t]*(true|false)")) return ""
  v = substr(s, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*/, "", v); return v
}
function obj(s, name,   tail, stop) {
  if (!match(s, "\"" name "\"[ \t]*:[ \t]*\\{")) return ""
  tail = substr(s, RSTART + RLENGTH)
  gsub(/"current_usage"[ \t]*:[ \t]*\{[^}]*\}/, "", tail)
  stop = index(tail, "}")
  if (stop > 0) return substr(tail, 1, stop - 1)
  return tail
}
{ j = j $0 }                    # the payload may arrive pretty-printed
END {
  fh = obj(j, "five_hour"); sd = obj(j, "seven_day")
  print jstr(j, "display_name")
  print jstr(j, "cwd")
  print jnum(j, "total_cost_usd")
  print jnum(obj(j, "context_window"), "used_percentage")
  print jnum(fh, "used_percentage")
  print jnum(sd, "used_percentage")
  print jnum(fh, "resets_at")
  print jnum(sd, "resets_at")
  print jbool(j, "fast_mode")
  print jstr(obj(j, "effort"), "level")
  print jnum(j, "total_api_duration_ms")
  print jstr(j, "session_id")
}')
{
  read -r model
  read -r cwd
  read -r cost_usd
  read -r used_pct
  read -r five_hour_pct
  read -r seven_day_pct
  read -r five_hour_reset
  read -r seven_day_reset
  read -r fast_mode
  read -r effort_level
  read -r api_ms
  read -r session_id
} <<< "$parsed"

# One clock reading for the whole render: fmt_left and the git cache both
# need "now", and a fork is a fork.
NOW=$(date +%s)

[ -z "$model" ] && model="Claude"
[ -z "$cwd" ] && cwd="$PWD"

# On Windows, Claude Code runs the status line through Git Bash, but hands
# over a native path ("C:\Users\me\repos\thing"). The shortening below
# splits on "/", so without this the whole path arrives as one segment and
# nothing shortens at all. The guard is a leading drive letter, which a POSIX
# path cannot have, so a Unix path that legitimately contains a backslash is
# left alone.
#
# The drive is NOT rewritten to the Git Bash mount form (/c/Users/...), so a
# Windows home directory will not collapse to "~". That needs knowing what
# $HOME and cwd actually look like there, which is not something to guess at.
#
# The separator is remembered rather than discarded: splitting on "/" is an
# implementation detail of the shortening below, and a Windows path rendered
# back with forward slashes reads as some other machine's path. So the
# components are re-joined with the separator the payload actually used.
DIR_SEP=/
# shellcheck disable=SC1003  # a backslash in single quotes is literal, not an
# escape -- and a directive has to sit in front of the whole case, not a branch.
case $cwd in
  [A-Za-z]:[\\/]*) cwd=${cwd//\\//}; DIR_SEP='\' ;;
esac

# Compact the model name: "Opus 5 (1M context)" -> "Opus 5" + the badge "1M".
# The parenthetical only ever carries the window size, and the word "context"
# is dead weight sitting two segments away from a gauge already labelled ctx.
# The badge is rendered a shade lighter than the name, the same "dim means
# abbreviated or secondary" rule the directory uses. Pure parameter expansion.
model_badge=""
case $model in
  *\(*\)*)
    _inner=${model#*(}; _inner=${_inner%)*}; _inner=${_inner% context}
    model="${model%% (*}"
    model_badge=$_inner
    ;;
esac

# effort.level rides along in the same badge: it is set per session, it changes
# how much the session costs and how long it takes, and nothing else on screen
# says which one is active.
[ -n "$effort_level" ] && model_badge="${model_badge:+$model_badge }${effort_level}"

# Shorten the directory the way p10k's "truncate_to_first_char" does: $HOME
# becomes ~, every PARENT segment is cut to its first character (a leading dot
# is kept, so .config reads ".c"), and the leaf is left whole because that is
# the part actually being read. ~/repos/claude-statusline -> ~/r/claude-statusline.
# Paths of two segments or fewer are left alone -- there is nothing to gain.
#
# The shortening is signalled with brightness rather than with an extra
# character, which is what p10k itself does and costs no columns: a component
# whose rendered text is not its real name drops to 250, structural pieces and
# untouched components stay at the base 254, and the leaf is 255 bold. So
# anything dim has been abbreviated and the bright part is whole -- and the
# rule is self-checking, because the colour is chosen by comparing the short
# form against the original, not by assuming the cut did something.
# Values copied from ~/.p10k.zsh: DIR_FOREGROUND, DIR_SHORTENED_FOREGROUND,
# DIR_ANCHOR_FOREGROUND + DIR_ANCHOR_BOLD.
DIR_FG=254; DIR_SHORT_FG=250; DIR_ANCHOR_FG=255
# NOT "${cwd/#$HOME/~}": in bash 5.2 the REPLACEMENT is tilde-expanded, so the
# ~ turns straight back into $HOME and the home directory never shortens. bash
# 3.2 does not expand it, so the bug was invisible on macOS and showed up only
# on Linux. An explicit case is immune to the difference either way.
#
# On Windows the two sides are written in different dialects: $HOME is the
# Git Bash mount form (/c/Users/me) while cwd is native (C:/Users/me after
# the normalisation above), so they never match and the home directory would
# never collapse. USERPROFILE is that same home written the way the payload
# writes it. Without it the drive stays put, which is the honest fallback:
# guessing at a home directory is worse than showing the real path.
_home=$HOME
if [ "$DIR_SEP" != / ] && [ -n "${USERPROFILE:-}" ]; then   # i.e. a native Windows path
  _home=${USERPROFILE//\\//}
fi
case $cwd in
  "$_home")   _home_rel="~" ;;
  "$_home"/*) _home_rel="~${cwd#"$_home"}" ;;
  *)          _home_rel=$cwd ;;
esac
IFS='/' read -r -a _parts <<< "$_home_rel"
n=${#_parts[@]}
dir_display=""
dir_w=0
for ((i = 0; i < n; i++)); do
  _p=${_parts[$i]}
  if [ "$i" -eq "$((n - 1))" ]; then          # the leaf: never cut, always brightest
    printf -v _seg '\033[1;38;5;%dm%s\033[22;38;5;%dm' "$DIR_ANCHOR_FG" "$_p" "$DIR_FG"
  else
    _s=$_p
    if [ "$n" -gt 2 ]; then
      case $_p in
        ''|'~') ;;                            # the leading "/" or ~: nothing to cut
        [A-Za-z]:) ;;                         # a Windows drive: "C" alone is not a drive
        .?*)    _s=${_p:0:2} ;;               # hidden dir: the dot alone says nothing
        *)      _s=${_p:0:1} ;;
      esac
    fi
    if [ "$_s" = "$_p" ]; then
      printf -v _seg '\033[38;5;%dm%s' "$DIR_FG" "$_s"
    else
      printf -v _seg '\033[38;5;%dm%s' "$DIR_SHORT_FG" "$_s"
    fi
  fi
  dir_display+=$_seg
  if [ "$i" -eq "$((n - 1))" ]; then dir_w=$((dir_w + ${#_p})); else dir_w=$((dir_w + ${#_s})); fi
  if [ "$i" -lt "$((n - 1))" ]; then
    printf -v _seg '\033[38;5;%dm%s' "$DIR_FG" "$DIR_SEP"
    dir_display+=$_seg
    dir_w=$((dir_w + 1))
  fi
done

# --- Pure integer helpers (macOS ships bash 3.2: no float printf "%.0f"/"%.2f") ---
# Every helper below returns through a named global instead of stdout. The
# obvious spelling -- x=$(helper ...) -- forks a subshell per call, which is a
# rounding error on Unix and is not one here: MSYS has no real fork(), so on
# Windows a subshell costs ~8 ms and an external process ~15 ms against ~0.8
# ms for a builtin, and a dozen of those was most of a 121 ms render.
# grad_color already worked this way (GC_R/GC_G/GC_B); the rest now match it.
round_pct() {
  # $1 = raw numeric string (int or decimal) -> RP_OUT = rounded 0-100 int, or "" if not numeric.
  local v=$1 int frac
  int=${v%%.*}
  frac=${v#*.}
  [ "$int" = "$v" ] && frac=0
  case ${int} in
    ''|*[!0-9]*) RP_OUT=""; return ;;
  esac
  case ${frac} in
    [5-9]*) int=$((int + 1)) ;;
  esac
  [ "$int" -gt 100 ] && int=100
  RP_OUT=$int
}

format_cost() {
  # $1 = raw numeric string -> FC_OUT = "$X.YY", or "" if not numeric.
  local v=$1 int frac
  int=${v%%.*}
  case ${int} in
    ''|*[!0-9]*) FC_OUT=""; return ;;
  esac
  if [ "$int" = "$v" ]; then
    frac="00"
  else
    frac=${v#*.}
    case ${frac} in
      *[!0-9]*|'') frac="00" ;;
      *) frac="${frac}00"; frac="${frac:0:2}" ;;
    esac
  fi
  FC_OUT='$'"${int}.${frac}"
}

burn_rate() {
  # $1 = cost in dollars, $2 = elapsed API milliseconds -> BR_OUT = "$17/h",
  # or "" when either input is missing.
  #
  # The denominator is API time, NOT cost.total_duration_ms: wall-clock
  # includes every minute the session sat idle, so a session left open over
  # lunch would report a rate several times below what the work actually
  # costs -- a number that is wrong in the reassuring direction is worse than
  # no number. Below a minute of API time the ratio is noise, so nothing is
  # shown.
  local cents int frac rate
  case ${2} in
    ''|*[!0-9]*) BR_OUT=""; return ;;
  esac
  [ "$2" -lt 60000 ] && { BR_OUT=""; return; }
  int=${1%%.*}
  case ${int} in
    ''|*[!0-9]*) BR_OUT=""; return ;;
  esac
  if [ "$int" = "$1" ]; then
    frac="00"
  else
    frac=${1#*.}
    case ${frac} in
      *[!0-9]*|'') frac="00" ;;
      *) frac="${frac}00"; frac="${frac:0:2}" ;;
    esac
  fi
  cents=$((10#$int * 100 + 10#$frac))
  # cents/100 dollars over ms/3600000 hours = cents * 36000 / ms.
  rate=$((cents * 36000 / $2))
  [ "$rate" -lt 1 ] && { BR_OUT=""; return; }
  BR_OUT='$'"${rate}/h"
}

fmt_reset() {
  # $1 = unix epoch seconds (rate_limits.*.resets_at), $2 = strftime format.
  # BSD date (macOS) spells it "-r <epoch>"; GNU date reads "-r" as a
  # reference FILE and fails, so it gets "-d @<epoch>". Trying BSD first
  # costs nothing on the machine this runs on and makes the script work on
  # Linux, which the CI needs and the servers would too.
  # LC_ALL=C keeps the weekday abbreviation stable (the shell locale is
  # it_IT). Empty for a missing/non-numeric value -- build_bar then omits the
  # parenthetical. Result in FR_OUT.
  local out
  case ${1} in
    ''|*[!0-9]*) FR_OUT=""; return ;;
  esac
  out=$(LC_ALL=C date -r "$1" "+$2" 2>/dev/null)
  [ -z "$out" ] && out=$(LC_ALL=C date -d "@$1" "+$2" 2>/dev/null)
  # The lowercasing was "| tr", which is a pipeline, which is a fork -- ~15 ms
  # on Windows. Under LC_ALL=C the only letters either format in use can
  # produce ("%a %H:%M" and "%H:%M") are the seven weekday abbreviations, so
  # seven cases replace the pipe with parameter expansion. A format with
  # letters anywhere but the front would need this extended.
  case $out in
    Mon*) out="mon${out#Mon}" ;;
    Tue*) out="tue${out#Tue}" ;;
    Wed*) out="wed${out#Wed}" ;;
    Thu*) out="thu${out#Thu}" ;;
    Fri*) out="fri${out#Fri}" ;;
    Sat*) out="sat${out#Sat}" ;;
    Sun*) out="sun${out#Sun}" ;;
  esac
  FR_OUT=$out
}

# --- Position-based truecolor gradient (4 stops, piecewise-linear, integer math) ---
#   i=1..4 (t 0.125-0.50): green  #22c55e -> yellow #eab308
#   i=5..6 (t 0.625-0.75): yellow #eab308 -> orange #f97316
#   i=7..8 (t 0.875-1.00): orange #f97316 -> red    #ef4444
# Sets globals GC_R/GC_G/GC_B (no subshell -- called up to 24x per render).
grad_color() {
  local i=$1 d
  if [ "$i" -le 4 ]; then
    GC_R=$((34 + 200 * i / 4))
    GC_G=$((197 + (-18 * i) / 4))
    GC_B=$((94 + (-86 * i) / 4))
  elif [ "$i" -le 6 ]; then
    d=$((i - 4))
    GC_R=$((234 + 15 * d / 2))
    GC_G=$((179 + (-64 * d) / 2))
    GC_B=$((8 + 14 * d / 2))
  else
    d=$((i - 6))
    GC_R=$((249 + (-10 * d) / 2))
    GC_G=$((115 + (-47 * d) / 2))
    GC_B=$((22 + 46 * d / 2))
  fi
}

build_bar() {
  # $1 = 0-100 int percentage, $2 = short label (ctx/5h/7d), $3 = optional
  # parenthetical -> BAR_OUT = "label <8-cell gauge> pct% (extra)" with embedded
  # truecolor/256-color escapes. The label leads: it names the thing before
  # the eye reaches its value, and it puts the two variable-width pieces (the
  # number and the parenthetical) together at the end instead of straddling
  # the bar. The gauge cells are standard Unicode -- no Nerd Font needed.
  local pct=$1 label=$2 reset=$3 filled i out cell
  # The caller needs to know how wide this is without parsing escapes back
  # out of the result, so the width is computed from the pieces as they are
  # emitted: label + space + 8 cells + the number field + any parenthetical.
  BAR_W=$(( ${#label} + 1 + 8 + 4 ))
  [ "$pct" -ge 100 ] && BAR_W=$((BAR_W + 1))
  [ -n "$reset" ] && BAR_W=$(( BAR_W + 3 + ${#reset} ))
  filled=$(( (pct * 8 + 50) / 100 ))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt 8 ] && filled=8
  printf -v out '\033[38;5;244m%s ' "$label"
  for ((i = 1; i <= 8; i++)); do
    if [ "$i" -le "$filled" ]; then
      grad_color "$i"
      printf -v cell '\033[38;2;%d;%d;%dm▰' "$GC_R" "$GC_G" "$GC_B"
    else
      printf -v cell '\033[38;2;72;76;86m▱'
    fi
    out+="$cell"
  done
  # The number is painted the colour of the bar's TIP, so severity reads at a
  # glance without counting cells; the label and the reset stay dim so the
  # number is the only thing competing with the bar. "%3d" pins the width, so
  # a gauge crossing 9->10 or 99->100 no longer shoves the rest of the line
  # sideways -- with three live gauges that jitter is constant otherwise.
  local tip=$filled
  [ "$tip" -lt 1 ] && tip=1
  grad_color "$tip"
  # No literal space before the number: "%3d" already right-pads one- and
  # two-digit values, so the pair reads as one object instead of drifting
  # apart. Three digits are the exception and get a space of their own --
  # at 100% the last cell and the number are both red, and with nothing
  # between them they merge into a single blob at the one moment the reading
  # matters most. The cost is one column of shift when a gauge saturates,
  # which is a far cheaper trade than the 9->10 jitter "%3d" exists to stop:
  # that boundary is crossed early and often, this one at most once, at the
  # end, after which the value cannot change again.
  if [ "$pct" -ge 100 ]; then
    printf -v cell '\033[38;2;%d;%d;%dm %d%%' "$GC_R" "$GC_G" "$GC_B" "$pct"
  else
    printf -v cell '\033[38;2;%d;%d;%dm%3d%%' "$GC_R" "$GC_G" "$GC_B" "$pct"
  fi
  out+="$cell"
  if [ -n "$reset" ]; then
    printf -v cell '\033[38;5;244m (%s)' "$reset"
    out+="$cell"
  fi
  BAR_OUT=$out
}

# --- Segment palette, copied from ~/.p10k.zsh where noted ---
#   model    : bg 7   fg 232  (p10k os_icon)
#   directory: bg 4   fg 254  (p10k dir)
#   git clean: bg 34  fg 0    (p10k vcs clean, but see below)
#   git dirty: bg 214 fg 0    (p10k vcs modified, but see below)
#   metrics  : bg 236 fg 250  (dark panel; gauge cells override fg per-cell)
#   cost     : bg 232 fg 6    (p10k background_jobs style, but see below)
#
# Three of these do NOT copy p10k, and they are the three whose colour is
# carrying information rather than decoration. Colours 0-15 are the terminal's
# to redefine, so a value in that range is a request, not a choice; 16-255 are
# fixed. The rule that came out of it: if the meaning of a colour is a
# CONTRAST -- with the background, or with another segment -- it may not live
# in 0-15. Identity colours (the model's bg 7, the directory's bg 4) still
# follow the theme on purpose, because looking at home is the whole point.
#
# cost was p10k's bg 0. The p10k presets map ANSI black onto the iTerm2
# background, so the segment rendered as nothing at all -- and looked
# deliberate doing it, while on Windows, where black is #000, it was a solid
# block. 232 is the darkest step of the greyscale ramp (#080808).
#
# git was p10k's bg 2 (clean) and bg 3 (dirty). Measured in the profile where
# this went wrong, ANSI 2 is (0,194,0) and ANSI 3 is (199,196,0): a hue gap of
# 61 degrees, and dirty reads as a yellow-GREEN rather than as yellow. The one
# distinction on that segment that anybody needs had gone soft. Pinning a
# fixed YELLOW does not fix it: yellow and green differ only in the red
# channel, so with green high in both, the eye keeps reading both as green.
# The operative condition is R > G -- that is, an orange. No yellow and no
# yellow-green can satisfy it, since both keep R <= G; 106 (#87af00) and 178
# (#d7af00) were tried and both sit at G=175 with B=0, differing only along
# the very axis that is already weak. 214 (#ffaf00) is R=255 against G=175,
# and against 34 (#00af00) the hue gap is 79 degrees rather than 25. Orange
# also happens to be what "dirty" means.
# printf -v, not $(printf ...): command substitution forks a subshell, and
# these two ran on every render for no reason at all.
# U+E0B0 lives in the Unicode private use area, which makes it this line's one
# hard font dependency -- and its failure mode is not the honest tofu box you
# would hope for. On Windows the same codepoints are squatted on by Wingdings,
# Webdings and Symbol, so a terminal without a patched font falls back to one
# of those and draws an unrelated dingbat that looks entirely deliberate --
# nobody reads it as "missing font". CLAUDE_STATUSLINE_PLAIN=1 swaps in U+258C,
# the left half block, which ships in every stock monospace font (Cascadia
# Mono, Consolas, Menlo, DejaVu Sans Mono). It is drawn with the same fg/bg
# pair as the arrow -- previous segment's color as foreground, next segment's
# as background -- so the two colors still meet inside the one cell and in the
# same order, and the boundary reads as a straight edge instead of a point.
# It is also one column wide, so row_width()'s "one column per separator"
# stays true and not a single layout number changes.
if [ -n "${CLAUDE_STATUSLINE_PLAIN:-}" ]; then
  printf -v SEP '\342\226\214'   # U+258C LEFT HALF BLOCK
else
  printf -v SEP '\356\202\260'   # U+E0B0, same as POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR
fi
# Between gauges: U+00B7, at 240 -- a shade below the labels, so it groups the
# three readings without joining the competition for attention. Written in
# octal for the same reason as SEP: a multibyte glyph pasted into a file is
# one bad copy away from becoming an empty string, and this one would fail
# silently (the gauges would just run together).
printf -v GAUGE_SEP '\033[38;5;240m \302\267 '
SEG_FG=()
SEG_BG=()
SEG_TXT=()
SEG_W=()     # visible width, escapes excluded -- see the layout section
SEG_ROW=()   # 0 or 1, decided once every segment exists
add_segment() { SEG_FG+=("$1"); SEG_BG+=("$2"); SEG_TXT+=("$3"); SEG_W+=("$4"); SEG_ROW+=(0); }

# 1) model
# fast_mode gets a bolt rather than a word: it is a mode you can forget you
# left on, and it costs one column only while it is actually on.
model_w=${#model}
if [ "$fast_mode" = "true" ]; then
  model="${model} \342\232\241"
  printf -v model '%b' "$model"
  model_w=$((model_w + 3))   # space + the bolt, which is two columns wide
fi
if [ -n "$model_badge" ]; then
  printf -v model_txt ' %s \033[38;5;240m%s\033[38;5;232m ' "$model" "$model_badge"
  model_w=$((model_w + ${#model_badge} + 1))
else
  model_txt=" ${model} "
fi
add_segment 232 7 "$model_txt" "$((model_w + 2))"
# 2) current directory
add_segment 254 4 " ${dir_display} " "$((dir_w + 2))"

# 3) git branch + ahead/behind + clean/dirty (skipped outside a git repo)
#
# ONE git process, not three. "status --porcelain=v2 --branch" reports the
# branch name, the detached-HEAD object id, the ahead/behind counts and every
# modified path in a single pass -- what costs 23 ms as rev-parse + branch +
# status. Ahead/behind therefore comes for free; on its own it would not be
# worth a fourth git process.
#
# Empty output means "not a repository": inside one the --branch header lines
# are always emitted. A git too old for porcelain=v2 (< 2.11) also yields
# nothing, so the segment disappears rather than showing a wrong state.
git_read_state() {
  local line ab
  branch=""; oid=""; dirty=0; ahead=0; behind=0
  while IFS= read -r line; do
    case $line in
      '# branch.oid '*)  oid=${line#\# branch.oid } ;;
      '# branch.head '*) branch=${line#\# branch.head } ;;
      '# branch.ab '*)
        ab=${line#\# branch.ab }
        ahead=${ab%% *};  ahead=${ahead#+}
        behind=${ab##* }; behind=${behind#-}
        ;;
      '#'*) ;;
      ?*) dirty=1 ;;   # any non-header line is a change, tracked or not
    esac
  done <<< "$1"
  [ "$branch" = "(detached)" ] && branch=${oid:0:7}
}

# A 2-second cache in front of it. On a normal repo the call is ~8 ms, but on
# a large one "status" walks the whole worktree and the status line stalls
# with it -- and the line is redrawn far more often than the worktree changes.
# Being wrong is bounded and self-correcting: for at most two seconds after a
# commit the segment shows the previous state.
git_cache_key=${cwd//\//%}
[ ${#git_cache_key} -gt 120 ] && git_cache_key=${git_cache_key: -120}
git_cache_file="${TMPDIR:-/tmp}/claude-statusline-git-${#cwd}-${git_cache_key}"
git_state_ok=0
if [ -r "$git_cache_file" ]; then
  # US (0x1f) as the delimiter, not TAB: tab is IFS *whitespace*, so repeated
  # delimiters collapse into one and an empty field shifts every field after
  # it -- a non-repo cached as "<now>||0|0|0" came back parsed as branch="0",
  # and /tmp grew a git segment. 0x1f cannot occur in the data either: git
  # forbids control characters in ref names.
  #
  # A torn read is possible (a concurrent render truncating the file), so the
  # line is validated rather than trusted: anything unexpected counts as a
  # miss and falls through to a live call.
  IFS=$'\037' read -r c_at branch dirty ahead behind extra < "$git_cache_file"
  case ${c_at}${extra} in
    ''|*[!0-9]*) ;;
    *) [ "$((NOW - c_at))" -lt 2 ] && [ -n "$dirty" ] && git_state_ok=1 ;;
  esac
fi
if [ "$git_state_ok" = "0" ]; then
  git_read_state "$(git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch 2>/dev/null)"
  printf '%s\037%s\037%s\037%s\037%s\n' "$NOW" "$branch" "$dirty" "$ahead" "$behind" \
    > "$git_cache_file" 2>/dev/null
fi

if [ -n "$branch" ]; then
  vcs=" ${branch}"
  vcs_w=$(( ${#branch} + 1 ))
  # p10k's own glyphs, U+21E1 / U+21E3, in octal for the same reason as SEP.
  [ "$ahead"  != "0" ] && { printf -v _a ' \342\207\241%s' "$ahead";  vcs+=$_a; vcs_w=$((vcs_w + 2 + ${#ahead})); }
  [ "$behind" != "0" ] && { printf -v _b ' \342\207\243%s' "$behind"; vcs+=$_b; vcs_w=$((vcs_w + 2 + ${#behind})); }
  if [ "$dirty" = "1" ]; then
    add_segment 0 214 "${vcs} ✗ " "$((vcs_w + 3))"
  else
    add_segment 0 34 "${vcs} ✓ " "$((vcs_w + 3))"
  fi
fi

# 4) task list progress (skipped unless a list exists on disk)
#
# Claude Code keeps the session's task list as one JSON file per task under
# <config dir>/tasks/<list id>/, and deletes every one of them the moment the
# last task reaches "completed". So a directory holding no *.json is the
# normal resting state, and it means there is nothing to say -- not "0/0".
# The .highwatermark it leaves behind is a count of tasks that once existed,
# which is not a reading anybody wants on a status line.
#
# The list id is the session id, unless CLAUDE_CODE_TASK_LIST_ID overrides it
# -- which is what a shared team list does. Upstream maps every character
# outside [a-zA-Z0-9_-] onto "-" before using the value as a directory name.
# Repeating that here is what makes the lookup find the real directory; it is
# also, for free, why a session id out of the payload cannot walk anywhere:
# both "/" and "." are gone before the value is ever part of a path.
task_list_id=${CLAUDE_CODE_TASK_LIST_ID:-$session_id}
task_list_id=${task_list_id//[!a-zA-Z0-9_-]/-}
if [ -n "$task_list_id" ]; then
  task_files=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/${task_list_id}"/*.json)
  # An unmatched glob comes back as the pattern itself in bash 3.2 -- nullglob
  # would fix it and is not worth setting, because it would silently change
  # every other glob in the script -- so the first element is tested for
  # existence rather than counted. Dot-files need no filtering: "*" does not
  # match a leading dot, which is precisely why .lock and .highwatermark stay
  # out of the total without a word being spent on them.
  if [ -e "${task_files[0]}" ]; then
    # Counted in the shell, with no awk and no subshell: this is the one
    # place a segment can add a fork to EVERY render, and on Windows a fork is
    # the most expensive thing this script can do (see the performance notes --
    # MSYS has no real fork() and pays about 200 ms a render for the ones that
    # were already here). An awk pass over these files measured +2 ms on macOS
    # and would have cost far more there, to read a few hundred bytes.
    #
    # Spaces and tabs go first, so one pattern covers both the compact form
    # Claude Code writes and a pretty-printed file. Deleting them cannot create
    # a false match: a status written inside subject or description has its
    # quotes escaped, and \"status\" offers no closing quote where the pattern
    # needs one. Then the content is cut at the FIRST occurrence of the key,
    # because "status" can appear a second time as a metadata key and metadata
    # is written after the real field.
    task_done=0
    task_active=0
    for task_file in "${task_files[@]}"; do
      task_json=""
      # "|| [ -n "$line" ]" because the files carry no trailing newline, and
      # without it read returns false on the last line and drops it -- which
      # for a one-line file is the whole file.
      # The stderr redirect comes BEFORE the input one, and the order is not
      # cosmetic: redirections apply left to right, so with "< file 2>/dev/null"
      # the open fails while stderr still points at the real one and bash
      # reports it. Claude Code deletes every task file the instant the list
      # resets, which can land between the glob above and this read, so the
      # race is real rather than theoretical -- and a status line that prints
      # to stderr is one that shows up in a session log.
      while IFS= read -r task_line || [ -n "$task_line" ]; do
        task_json+=$task_line
      done 2>/dev/null < "$task_file"
      task_json=${task_json// /}
      task_json=${task_json//$'\t'/}
      # And the carriage return, which read leaves at the end of every line of
      # a CRLF file. It survived the awk this used to be -- that pattern closed
      # on a quote, so a \r past it was harmless -- but here the lines are
      # concatenated, which moves the \r INTO the middle of the string.
      task_json=${task_json//$'\r'/}
      case ${task_json#*'"status":'} in
        '"completed"'*)   task_done=$((task_done + 1)) ;;
        '"in_progress"'*) task_active=$((task_active + 1)) ;;
      esac
    done
    # No guard on the count: the glob already found a file, so the total is at
    # least one.
    task_count="${task_done}/${#task_files[@]}"
    # The one colour on this segment that carries information rather than
    # decoration: green while something is actually in progress, plain while
    # the list is open and nothing is moving. The second state is the reason
    # the colour is here at all -- an open list with no task in progress
    # means the work stopped, and that is worth noticing from across a desk.
    # 34;197;94 is the gradient's first stop, and it appears nowhere else on
    # the line: the gauge cells start one step in, at 84;193;73.
    if [ "$task_active" -gt 0 ]; then
      task_col='\033[38;2;34;197;94m'
    else
      task_col='\033[38;5;252m'
    fi
    # bg 240 is one step lighter than the metrics panel's 236, which is one
    # step lighter than cost's 232: the three dark segments descend rather
    # than repeat, so the seams show without a fourth hue being introduced to
    # a line that already carries four. The icon is 248 rather than the
    # gauges' 244 for the same reason a label is dimmer than its value at all
    # -- what is copied is the RELATIONSHIP to the background, not the number,
    # and this background is lighter.
    #
    # U+2263 (three horizontal strokes -- a list) and NOT a tick: the git
    # segment already spends U+2713 on "clean", and two different ticks on one
    # line meaning two different things is worse than no icon at all.
    #
    # Three codepoints were tried and rejected before this one. All three
    # failures came from reasoning about a property that can be measured
    # locally instead of the one that decides: whether the glyph is in the
    # font that will actually draw it, on the machine that will draw it.
    #
    # U+2630 draws the same strokes and went first, because East_Asian_Width=W
    # looked like a width guarantee. It is not: W says how many cells the
    # terminal RESERVES, not how wide the drawn glyph is. Missing from the
    # terminal font, it arrives from fallback with an advance of its own --
    # measured on stock Windows Terminal at about one and a half of the two
    # cells reserved. It is also absent from MesloLGS NF.
    #
    # U+F0C9 moved it to the private use area, which fixed the width and broke
    # something worse: U+F020-U+F0FF is where Windows maps Wingdings, Webdings
    # and Symbol, so without a Nerd Font the glyph becomes an unrelated
    # dingbat -- wrong, plausible, and never reported as a bug.
    #
    # U+F44E cleared that range (above U+F0FF nothing legacy claims anything),
    # so it failed visibly instead of silently. But visibly was still a
    # failure, and a worse-placed one than assumed: stock Windows draws U+E0B0
    # from Segoe UI Symbol, so the separators render and only the icon would
    # have been an empty box, in an otherwise perfect line.
    #
    # U+2263 needs no fallback at all. It ships inside the fonts that are
    # already active: Cascadia Mono on a stock Windows Terminal, MesloLGS NF
    # and Menlo on macOS. That is a stronger guarantee than the separator's,
    # which does depend on a fallback happening to be installed.
    # A space between the icon and the count. The two-column U+2630 this
    # replaced carried its own gap and did not need one; a one-cell glyph sits
    # hard against the digits without it.
    printf -v task_txt ' \033[38;5;248m\342\211\243 %b%s\033[38;5;252m ' "$task_col" "$task_count"
    add_segment 252 240 "$task_txt" "$((${#task_count} + 4))"
  fi
fi

# 5) metrics: one dark segment holding up to 3 gauges (ctx / 5h / 7d).
#    Each gauge is independently optional; the whole segment is skipped
#    if none of the three values are available.
round_pct "$used_pct";       ctx_int=$RP_OUT
round_pct "$five_hour_pct";  five_hour_int=$RP_OUT
round_pct "$seven_day_pct";  seven_day_int=$RP_OUT
metrics_txt=""
metrics_w=0
append_gauge() { # $1 = a built gauge, $2 = its visible width
  if [ -n "$metrics_txt" ]; then metrics_txt+="$GAUGE_SEP"; metrics_w=$((metrics_w + 3)); fi
  metrics_txt+="$1"
  metrics_w=$((metrics_w + $2))
}
# build_bar returns through BAR_OUT and BAR_W, so the text and its width come
# back together and there is no subshell to smuggle the width through. This
# used to append the width after a newline and split it back apart.
gauge() { # $1..$3 -> feeds append_gauge with text and width
  build_bar "$1" "$2" "$3"
  append_gauge "$BAR_OUT" "$BAR_W"
}
[ -n "$ctx_int" ] && gauge "$ctx_int" "ctx" ""
# Both windows say WHEN they reset, not how long is left. A countdown is only
# true at the instant it is drawn, and this line is not drawn on a clock:
# Claude Code re-runs it when the session does something, so between events
# "2h 33m" sits there going quietly stale while still reading as a fact. An
# absolute time is just as correct an hour later. The 5h window always lands
# today or just past midnight, so it needs no weekday; the 7d one can be days
# out and keeps its own. Fixed width is the bonus: "(4h 59m)" was three
# columns wider than "(45m)", and the layout had to carry slack for it.
[ -n "$five_hour_int" ] && { fmt_reset "$five_hour_reset" '%H:%M'; gauge "$five_hour_int" "5h" "$FR_OUT"; }
[ -n "$seven_day_int" ] && { fmt_reset "$seven_day_reset" '%a %H:%M'; gauge "$seven_day_int" "7d" "$FR_OUT"; }
METRICS_IDX=-1
if [ -n "$metrics_txt" ]; then
  METRICS_IDX=${#SEG_TXT[@]}
  add_segment 250 236 "  ${metrics_txt}  " "$((metrics_w + 4))"
fi

# 6) session cost
COST_IDX=-1
if [ -n "$cost_usd" ]; then
  format_cost "$cost_usd"; cost_fmt=$FC_OUT
  if [ -n "$cost_fmt" ]; then
    burn_rate "$cost_usd" "$api_ms"; rate_fmt=$BR_OUT
    if [ -n "$rate_fmt" ]; then
      printf -v cost_txt ' %s \033[38;5;240m\302\267 %s\033[38;5;6m ' "$cost_fmt" "$rate_fmt"
      cost_w=$(( ${#cost_fmt} + ${#rate_fmt} + 5 ))
    else
      cost_txt=" ${cost_fmt} "
      cost_w=$(( ${#cost_fmt} + 2 ))
    fi
    COST_IDX=${#SEG_TXT[@]}
    add_segment 6 232 "$cost_txt" "$cost_w"
  fi
fi

# --- Layout: one row, or two when one will not fit -------------------------
#
# Claude Code captures the script output rather than attaching it to the
# terminal, so tput and /dev/tty are both unavailable (verified: /dev/tty is
# "Device not configured"). It exports COLUMNS and LINES instead. If COLUMNS
# is absent -- running the script by hand, or from the preview generator --
# the layout stays on one row, which keeps those outputs deterministic.
#
# The split puts the identity on the first row (model, directory, git, cost)
# and the three gauges on the second. That is the natural seam: the first row
# answers "where am I", the second "how much is left", and the gauge row is
# the one whose width actually grows.
#
# The decision is made against the width the line COULD reach, not the width
# it happens to have: percentages can each gain a column at 100%, and the 5h
# countdown is three columns wider at "(4h 59m)" than at "(45m)". Without that
# allowance the layout would flip between one and two rows as the numbers
# changed -- far worse than the one-column jitter %3d exists to prevent. With
# it, the row count changes only when the window is resized, which is a
# deliberate act.
LAYOUT_SLACK=8

row_width() { # $1 = row number -> ROW_W = its rendered width
  local row=$1 i w=0 n=0
  for ((i = 0; i < ${#SEG_TXT[@]}; i++)); do
    if [ "${SEG_ROW[$i]}" = "$row" ]; then w=$((w + SEG_W[i])); n=$((n + 1)); fi
  done
  ROW_W=$((w + n))   # one column per separator, including the trailing one
}

if [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null && [ "$METRICS_IDX" -ge 0 ]; then
  row_width 0
  if [ "$((ROW_W + LAYOUT_SLACK))" -gt "$COLUMNS" ]; then
    SEG_ROW[METRICS_IDX]=1
    # If the gauge row still overruns, the parentheticals go: they are the
    # most expendable thing on the line (a reset time you can infer) and the
    # widest, about 21 columns between the two.
    row_width 1
    if [ "$((ROW_W + LAYOUT_SLACK))" -gt "$COLUMNS" ]; then
      metrics_txt=""; metrics_w=0
      [ -n "$ctx_int" ] && gauge "$ctx_int" "ctx" ""
      [ -n "$five_hour_int" ] && gauge "$five_hour_int" "5h" ""
      [ -n "$seven_day_int" ] && gauge "$seven_day_int" "7d" ""
      SEG_TXT[METRICS_IDX]="  ${metrics_txt}  "
      SEG_W[METRICS_IDX]=$((metrics_w + 4))
    fi
    # And if the identity row is still too wide, the burn rate goes: of
    # everything on that row it is the only piece that is an inference rather
    # than a fact, and it is the widest.
    row_width 0
    if [ "$COST_IDX" -ge 0 ] && [ "$ROW_W" -gt "$COLUMNS" ]; then
      SEG_TXT[COST_IDX]=" ${cost_fmt} "
      SEG_W[COST_IDX]=$(( ${#cost_fmt} + 2 ))
    fi
  fi
fi

# --- Render as connected powerline blocks ---
render_row() { # $1 = row number; prints nothing if the row holds no segments
  local row=$1 i k n s nb
  local idx=()
  for ((i = 0; i < ${#SEG_TXT[@]}; i++)); do
    [ "${SEG_ROW[$i]}" = "$row" ] && idx+=("$i")
  done
  n=${#idx[@]}
  [ "$n" -eq 0 ] && return 1
  for ((k = 0; k < n; k++)); do
    s=${idx[$k]}
    printf '\033[38;5;%sm\033[48;5;%sm%s' "${SEG_FG[$s]}" "${SEG_BG[$s]}" "${SEG_TXT[$s]}"
    if [ "$((k + 1))" -lt "$n" ]; then
      nb=${SEG_BG[${idx[$((k + 1))]}]}
      printf '\033[38;5;%sm\033[48;5;%sm%s' "${SEG_BG[$s]}" "$nb" "$SEP"
    else
      printf '\033[38;5;%sm\033[49m%s\033[0m' "${SEG_BG[$s]}" "$SEP"
    fi
  done
  return 0
}

render_row 0
_has_row1=0
for ((i = 0; i < ${#SEG_ROW[@]}; i++)); do [ "${SEG_ROW[$i]}" = "1" ] && _has_row1=1; done
if [ "$_has_row1" = "1" ]; then
  printf '\n'
  render_row 1
fi
