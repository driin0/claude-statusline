# claude-statusline

A Claude Code status line: powerline segments matching a Powerlevel10k prompt,
with gauges for context usage, the 5h/7d rate limits and session cost. The
whole thing is `statusline.sh` — one bash script, no runtime dependencies
beyond what the OS already ships.

## Installing it (the usual reason someone clones this)

```sh
sh install.sh
```

It symlinks `statusline.sh` into `~/.claude/statusline-command.sh` and sets the
`statusLine` key in `~/.claude/settings.json`, backing up anything it replaces
and leaving every other key alone. It honours `CLAUDE_CONFIG_DIR`.

Then verify, in this order:

```sh
./tests/run-tests.sh    # must print "N passed, 0 failed"
./preview.sh            # renders the line without a live session
```

The new line appears on Claude Code's next render — no restart needed. If it
looks like mojibake rather than connected blocks, the terminal is missing a
**Nerd Font**; that is a terminal setting and `install.sh` cannot fix it.

### Windows

Claude Code runs the status line through **Git Bash** when it is installed and
through PowerShell when it is not, so Git Bash is required — there is no
PowerShell port. Run `sh install.sh` from Git Bash, not from cmd or PowerShell.

Two things that bite here, both already handled but worth knowing:

- `.gitattributes` forces LF. Git for Windows defaults to `core.autocrlf=true`,
  and a bash script checked out with CRLF does not warn — it collapses, with
  `read -r model` reported as an invalid identifier.
- The payload carries a native path (`C:\Users\me\repos\thing`); the script
  normalises it to split on `/`, then renders it back with `\`. The home
  collapses to `~` against **`USERPROFILE`**, not `$HOME` — inside Git Bash
  `$HOME` is the mount form `/c/Users/me` and never matches the payload.

`install.sh` edits `settings.json` with jq, else python, else node, and it
probes each by *running* it: a stock Windows has a `python3` on `PATH` that is
only the Microsoft Store alias, so `command -v` is not evidence. If none of
the three works it prints the exact snippet to paste and changes nothing.
Re-running the installer when nothing changed is a no-op, backups included.

Git Bash usually **copies** rather than symlinks unless developer mode is on,
so on Windows re-run `sh install.sh` after every `git pull`. On macOS and
Linux the symlink makes `git pull` sufficient.

## If you change the script

- `./tests/run-tests.sh` must stay green. Most assertions map to a bug that
  actually shipped; the file header says which.
- Anything that changes what the line *looks like* means regenerating the
  README images: `sh tools/make-preview.sh`, then commit `docs/`. CI fails if
  they drift. The output is byte-reproducible on any machine, so a diff there
  means the look really changed.
- `~/.claude/statusline-command.sh` is a symlink into this repo on macOS and
  Linux. Editing it *is* editing the repo — do not treat it as a separate copy.
- Written for **macOS bash 3.2**: no `printf "%.0f"`, no associative arrays,
  no bash 4+ syntax. CI runs the suite on macOS and Linux for this reason.

The README explains the design decisions and why each one is the way it is.
