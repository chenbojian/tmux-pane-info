# tmux-pane-info

Fast tmux pane metadata CLI for macOS. Uses `libproc` system calls to detect processes (like Claude) running inside pane process trees — no `ps` fork, no shell loops.

## Output

Tab-separated, one line per pane:

```
session:window.pane    window_name    command    path
```

If a pane's process tree contains a Claude process, the `command` column shows `claude` instead of the shell name.

## Build

Requires Swift 5.9+ (included with Xcode / Command Line Tools).

```bash
swift build -c release
```

Binary at `.build/release/tmux-pane-info`.

## Usage with tmux

Bind `pane_launcher.sh` to a tmux key (e.g. `C-j`):

```tmux
# ~/.tmux.conf
bind C-j display-popup -E -w 90% -h 80% "/path/to/pane_launcher.sh"
```

The script calls the binary, formats with `column`, and pipes to `fzf` for fuzzy search + preview.

### Dependencies for pane_launcher.sh

- `fzf`
- `column` (from util-linux: `brew install util-linux`)

## Usage with Alfred / ScriptKit / other tools

Run the binary directly and parse the TSV output:

```bash
~/.local/bin/tmux-pane-info | grep claude
```

## Install

```bash
# Build
swift build -c release

# Symlink (optional)
ln -sf "$(pwd)/.build/release/tmux-pane-info" ~/.local/bin/tmux-pane-info

# Copy launcher script
cp pane_launcher.sh ~/.config/tmux/pane_launcher.sh
```
