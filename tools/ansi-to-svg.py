#!/usr/bin/env python3
"""Turn the status line's ANSI output into a self-contained SVG.

A screenshot would be simpler, but it would also be a 200 KB PNG that has to
be retaken by hand after every tweak. This reads the same bytes the terminal
reads, so `make-preview.sh` regenerates a pixel-identical preview from the
script itself -- the README can never drift from what the code does.

Two things are drawn as geometry rather than as glyphs, on purpose:

  * the U+E0B0 separator, which needs a Nerd Font nobody reading the README
    on github.com is guaranteed to have, and
  * the gauge cells U+25B0/U+25B1, whose advance width is not reliably
    monospace even in fonts that do have them -- as polygons the bar can
    never come out ragged.

Everything else is text, pinned to the monospace grid with textLength.

Usage:  <ansi lines> | ansi-to-svg.py [--title TEXT] > out.svg
"""
import re
import sys

# --- palette ---------------------------------------------------------------
# ANSI 0-15 read from the iTerm2 "Default" profile this line was designed
# against, so the preview shows the colours actually on screen. Regenerate
# with tools/read-iterm-palette.sh if the profile changes.
ANSI16 = [
    (20, 25, 30), (180, 60, 42), (0, 194, 0), (199, 196, 0),
    (39, 68, 199), (192, 64, 190), (0, 197, 199), (199, 199, 199),
    (104, 104, 104), (221, 121, 117), (88, 231, 144), (236, 225, 0),
    (167, 171, 242), (225, 126, 225), (96, 253, 255), (255, 255, 255),
]
TERM_BG = (21, 25, 31)
TERM_FG = (220, 220, 220)


def xterm256(n):
    """Index -> RGB, for the whole 0-255 range."""
    if n < 16:
        return ANSI16[n]
    if n < 232:                      # 6x6x6 colour cube
        n -= 16
        levels = (0, 95, 135, 175, 215, 255)
        return (levels[n // 36], levels[(n // 6) % 6], levels[n % 6])
    return (8 + (n - 232) * 10,) * 3  # 24-step grayscale ramp


# --- parse -----------------------------------------------------------------
SGR = re.compile(r"\033\[([0-9;]*)m")


def parse(line):
    """-> list of (char, fg rgb, bg rgb or None)."""
    cells, fg, bg, pos = [], TERM_FG, None, 0
    for m in SGR.finditer(line):
        for ch in line[pos:m.start()]:
            cells.append((ch, fg, bg))
        pos = m.end()
        params = [p for p in m.group(1).split(";") if p != ""] or ["0"]
        i = 0
        while i < len(params):
            p = int(params[i])
            if p == 0:
                fg, bg = TERM_FG, None
            elif p == 39:
                fg = TERM_FG
            elif p == 49:
                bg = None
            elif p in (38, 48) and i + 1 < len(params):
                mode = int(params[i + 1])
                if mode == 5 and i + 2 < len(params):
                    col = xterm256(int(params[i + 2]))
                    i += 2
                elif mode == 2 and i + 4 < len(params):
                    col = tuple(int(x) for x in params[i + 2:i + 5])
                    i += 4
                else:
                    i += 1
                    continue
                if p == 38:
                    fg = col
                else:
                    bg = col
            i += 1
    for ch in line[pos:]:
        cells.append((ch, fg, bg))
    return cells


# --- draw ------------------------------------------------------------------
CW, LH, FS = 9.0, 26.0, 15.0        # cell width, line height, font size
PAD_X, PAD_Y = 14.0, 12.0
ARROW = ""
FILLED, EMPTY = "▰", "▱"
SLANT = 1.7                          # parallelogram lean, inside the cell


def hex_(c):
    return "#%02x%02x%02x" % c


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def draw_line(cells, y):
    """-> list of SVG elements for one rendered line."""
    out = []
    top, bot = y, y + LH
    baseline = y + LH * 0.72

    # 1. background runs (one rect per contiguous same-bg stretch)
    start = 0
    while start < len(cells):
        bg = cells[start][2]
        end = start
        while end + 1 < len(cells) and cells[end + 1][2] == bg:
            end += 1
        if bg is not None:
            out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
                       % (PAD_X + start * CW, top, (end - start + 1) * CW, LH, hex_(bg)))
        start = end + 1

    # 2. glyphs: geometry for the three shapes above, text for the rest
    run, run_fg, run_start = [], None, 0

    def flush():
        if not run:
            return
        out.append('<text x="%.1f" y="%.1f" fill="%s" textLength="%.1f" '
                   'lengthAdjust="spacingAndGlyphs" xml:space="preserve">%s</text>'
                   % (PAD_X + run_start * CW, baseline, hex_(run_fg),
                      len(run) * CW, esc("".join(run))))
        run.clear()

    for i, (ch, fg, _bg) in enumerate(cells):
        x = PAD_X + i * CW
        if ch == ARROW:
            flush()
            out.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="%s"/>'
                       % (x, top, x + CW, (top + bot) / 2, x, bot, hex_(fg)))
        elif ch in (FILLED, EMPTY):
            flush()
            # The lean lives INSIDE the cell's bounding box, it is not added
            # to it: the shape spans x0..x1 whichever row you measure, and the
            # top and bottom edges are the ones that shift. Adding the slant to
            # the outside instead makes each cell overhang its neighbour, and
            # the image then lies about the spacing -- which matters, because
            # spacing is exactly what these previews get used to judge.
            x0, x1 = x + 0.75, x + CW - 0.75
            y0, y1 = top + 6.5, bot - 6.5
            out.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="%s"/>'
                       % (x0 + SLANT, y0, x1, y0, x1 - SLANT, y1, x0, y1,
                          hex_(fg)))
        else:
            if fg != run_fg or not run:
                flush()
                run_fg, run_start = fg, i
            run.append(ch)
    flush()
    return out


def main():
    title = None
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "--title":
        title = args[1]
    lines = [ln for ln in sys.stdin.read().split("\n") if ln.strip()]
    rendered = [parse(ln) for ln in lines]
    cols = max(len(c) for c in rendered)
    head = LH if title else 0.0
    w = PAD_X * 2 + cols * CW
    h = PAD_Y * 2 + head + len(rendered) * LH

    body = ['<rect width="%.1f" height="%.1f" rx="7" fill="%s"/>' % (w, h, hex_(TERM_BG))]
    if title:
        body.append('<text x="%.1f" y="%.1f" fill="#6b7280" font-size="12">%s</text>'
                    % (PAD_X, PAD_Y + 13, esc(title)))
    for i, cells in enumerate(rendered):
        body += draw_line(cells, PAD_Y + head + i * LH)

    print('<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" '
          'viewBox="0 0 %.1f %.1f" font-family="ui-monospace, SFMono-Regular, '
          'Menlo, DejaVu Sans Mono, Consolas, monospace" font-size="%.1f">'
          % (w, h, w, h, FS))
    print("\n".join(body))
    print("</svg>")


if __name__ == "__main__":
    main()
