#!/bin/bash

BINARY="$HOME/workspace/tmux-pane-info/.build/release/tmux-pane-info"

LIST=$("$BINARY" | /opt/homebrew/opt/util-linux/bin/column -t -s $'\t')

TARGET=$(echo "$LIST" | \
    fzf --reverse \
        --header 'Jump to Pane (C-j)' \
        --preview 'tmux capture-pane -pt $(echo {} | cut -d " " -f1)' \
        --preview-window down:50%)

if [ -n "$TARGET" ]; then
    TARGET_ID=$(echo "$TARGET" | awk '{print $1}')
    tmux switch-client -t "$TARGET_ID"
fi
