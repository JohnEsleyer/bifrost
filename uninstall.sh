#!/usr/bin/env bash
# =============================================================================
#  bifrost uninstaller - removes the CLI and the managed SSH config block.
# =============================================================================

set -uo pipefail

HOST="${BIFROST_VPS_HOST:-asgard}"
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_RED=''; C_GRN=''; C_YEL=''; C_OFF=''; }

say() { printf '==> %s\n' "$1"; }
ok()  { printf '    %s+%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
warn(){ printf '    %s!%s %s\n' "$C_YEL" "$C_OFF" "$1"; }

say "Removing the bifrost CLI"
removed=0
for dir in /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    if [[ -f "$dir/bifrost" ]]; then
        if [[ -w "$dir" ]]; then
            rm -f "$dir/bifrost" && ok "removed $dir/bifrost" && removed=1
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo rm -f "$dir/bifrost" && ok "removed $dir/bifrost" && removed=1
        else
            warn "$dir/bifrost needs root: sudo rm -f $dir/bifrost"
        fi
    fi
done
(( removed == 0 )) && warn "no bifrost binary found"

say "Cleaning the SSH config block for '$HOST'"
if [[ -f "$SSH_CONFIG" ]]; then
    begin="# >>> bifrost managed block: $HOST >>>"
    end="# <<< bifrost managed block: $HOST <<<"
    tmp="$(mktemp)"
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$SSH_CONFIG" > "$tmp"
    if cmp -s "$tmp" "$SSH_CONFIG"; then
        rm -f "$tmp"
        warn "no managed block found (already clean)"
    else
        mv "$tmp" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        ok "removed managed block from $SSH_CONFIG"
    fi
fi

say "Removing stale control sockets"
rm -f "$SSH_DIR"/bifrost-* 2>/dev/null && ok "cleared $SSH_DIR/bifrost-*" || true

printf '\nBifrost is uninstalled. The rainbow bridge is closed.\n'
