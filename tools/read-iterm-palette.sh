#!/bin/sh
# Print the ANSI palette of an iTerm2 profile as a Python literal, ready to
# paste into tools/ansi-to-svg.py. Run it after changing the iTerm colours so
# the SVG preview keeps matching the real terminal.
#   sh tools/read-iterm-palette.sh [profile-index, default 0]
python3 - "${1:-0}" <<'PY'
import plistlib, os, sys
b = plistlib.load(open(os.path.expanduser(
    "~/Library/Preferences/com.googlecode.iterm2.plist"), "rb"))["New Bookmarks"][int(sys.argv[1])]
def rgb(k):
    c = b[k]
    return tuple(round(c[x + " Component"] * 255) for x in ("Red", "Green", "Blue"))
print("# profile: %s" % b.get("Name"))
print("ANSI16 = [")
for i in range(0, 16, 4):
    print("    " + " ".join("%r," % (rgb("Ansi %d Color" % j),) for j in range(i, i + 4)))
print("]")
print("TERM_BG = %r" % (rgb("Background Color"),))
print("TERM_FG = %r" % (rgb("Foreground Color"),))
PY
