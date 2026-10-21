#!/usr/bin/env bash
# =============================================================================
#  bifrost installer
#
#    1. installs the `bifrost` CLI into a PATH directory
#    2. writes an idempotent, marked SSH config block for the Asgard host
#    3. checks that a usable private key exists
#
#  Usage:
#    ./install.sh                                  # interactive prompts
#    ./install.sh --ip 1.2.3.4 --user root         # fully non-interactive
#    ./install.sh --host asgard --ip 1.2.3.4 --user ubuntu --port 22
#
#  Every flag also has an environment equivalent:
#    BIFROST_VPS_IP, BIFROST_VPS_USER, BIFROST_VPS_PORT, BIFROST_VPS_HOST
# =============================================================================

set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/JohnEsleyer/bifrost/main"

# Works both from a clone (./install.sh) and from a pipe
# (curl -fsSL .../install.sh | bash -s -- --ip 1.2.3.4 --user root)
SCRIPT_DIR="."
if [[ -n "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
SRC="$SCRIPT_DIR/bin/bifrost"
TMP_SRC=""

cleanup() { [[ -n "$TMP_SRC" && -f "$TMP_SRC" ]] && rm -f "$TMP_SRC"; }
trap cleanup EXIT

HOST="${BIFROST_VPS_HOST:-asgard}"
VPS_IP="${BIFROST_VPS_IP:-}"
VPS_USER="${BIFROST_VPS_USER:-}"
VPS_PORT="${BIFROST_VPS_PORT:-22}"
IDENTITY=""
DO_SSH_CONFIG=1
BIN_DIR=""
ASSUME_YES=0

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
KEY_CANDIDATES=("id_ed25519" "id_rsa" "id_ecdsa" "id_dsa")

C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_GRN=''; C_RED=''; C_YEL=''; C_BLU=''; C_BLD=''; C_DIM=''; C_OFF=''; }

say()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$1"; }
ok()   { printf '    %s+%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
warn() { printf '    %s!%s %s\n' "$C_YEL" "$C_OFF" "$1"; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit "${2:-1}"; }

usage() {
    cat <<EOF
${C_BLD}bifrost installer${C_OFF}

  --host <alias>      ssh host alias to create      (default: $HOST)
  --ip <address>      VPS IP address or hostname
  --user <name>       ssh username on the VPS
  --port <port>       ssh port                     (default: $VPS_PORT)
  --identity <path>   private key to use
  --bin-dir <dir>     where to install the CLI      (default: auto)
  --no-ssh-config     skip writing the ~/.ssh/config block
  --yes               never prompt
  -h, --help          this message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       HOST="${2:?}"; shift 2 ;;
        --ip)         VPS_IP="${2:?}"; shift 2 ;;
        --user)       VPS_USER="${2:?}"; shift 2 ;;
        --port)       VPS_PORT="${2:?}"; shift 2 ;;
        --identity)   IDENTITY="${2:?}"; shift 2 ;;
        --bin-dir)    BIN_DIR="${2:?}"; shift 2 ;;
        --no-ssh-config) DO_SSH_CONFIG=0; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1" 2 ;;
    esac
done

# Piped installs (curl ... | bash -s -- ...) have no local bin/bifrost: fetch it.
if [[ ! -f "$SRC" ]]; then
    command -v curl >/dev/null 2>&1 || die "curl is required for a remote install"
    TMP_SRC="$(mktemp)"
    say "Fetching bifrost from $REPO_RAW"
    curl -fsSL "$REPO_RAW/bin/bifrost" -o "$TMP_SRC" \
        || die "could not download bin/bifrost from $REPO_RAW"
    SRC="$TMP_SRC"
fi
[[ -f "$SRC" ]] || die "cannot find the bifrost script at $SRC"

# ------------------------------------------------------------- interactive --
ask() {
    local prompt="$1" default="$2" reply
    if (( ASSUME_YES )); then printf '%s' "$default"; return; fi
    if [[ -t 0 ]]; then
        read -r -p "$prompt" reply
        printf '%s' "${reply:-$default}"
    else
        printf '%s' "$default"
    fi
}

if [[ -z "$VPS_IP" ]]; then
    say "Asgard connection details"
    VPS_IP="$(ask "    VPS IP / hostname : " "")"
fi
if [[ -z "$VPS_USER" ]]; then
    VPS_USER="$(ask "    SSH username      : " "$USER")"
fi

# ------------------------------------------------------------- pick a key ---
detect_identity() {
    if [[ -n "$IDENTITY" ]]; then printf '%s' "$IDENTITY"; return; fi
    local candidate
    for candidate in "${KEY_CANDIDATES[@]}"; do
        if [[ -f "$SSH_DIR/$candidate" ]]; then
            printf '%s' "$SSH_DIR/$candidate"
            return
        fi
    done
    printf ''
}

IDENTITY="$(detect_identity)"
if [[ -z "$IDENTITY" ]]; then
    warn "no private key found in $SSH_DIR - generate one with:"
    printf '        ssh-keygen -t ed25519 -f %s/id_ed25519 -C "bifrost"\n' "$SSH_DIR"
fi

# ---------------------------------------------------------- install binary --
pick_bin_dir() {
    if [[ -n "$BIN_DIR" ]]; then printf '%s' "$BIN_DIR"; return; fi
    local d
    for d in /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
        [[ -d "$d" ]] || continue
        if [[ -w "$d" ]]; then printf '%s' "$d"; return; fi
    done
    printf '%s' "$HOME/.local/bin"
}

install_binary() {
    local dir; dir="$(pick_bin_dir)"
    mkdir -p "$dir" || die "cannot create $dir"

    local target="$dir/bifrost"
    if [[ ! -w "$dir" ]]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo install -m 0755 "$SRC" "$target" || die "sudo install failed"
        else
            die "$dir is not writable and passwordless sudo is unavailable.
    Re-run with:  sudo install -m 0755 $SRC $target"
        fi
    else
        install -m 0755 "$SRC" "$target" || die "install failed"
    fi
    printf '%s' "$target"
}

say "Installing the bifrost CLI"
INSTALLED_TO="$(install_binary)"
ok "installed: $INSTALLED_TO"

case ":$PATH:" in
    *":$(dirname "$INSTALLED_TO"):"*) ok "already on PATH" ;;
    *) warn "$(dirname "$INSTALLED_TO") is not on your PATH - add it to ~/.bashrc" ;;
esac

# ------------------------------------------------------- write ssh config ---
write_ssh_block() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    [[ -f "$SSH_CONFIG" ]] || { : > "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"; }
    chmod 600 "$SSH_CONFIG" 2>/dev/null

    local begin="# >>> bifrost managed block: $HOST >>>"
    local end="# <<< bifrost managed block: $HOST <<<"
    local tmp; tmp="$(mktemp)"

    # Strip any previous managed block for this host.
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$SSH_CONFIG" > "$tmp"

    {
        printf '\n%s\n' "$begin"
        printf 'Host %s\n' "$HOST"
        printf '    HostName %s\n' "$VPS_IP"
        printf '    User %s\n' "$VPS_USER"
        printf '    Port %s\n' "$VPS_PORT"
        if [[ -n "$IDENTITY" ]]; then
            # Prefer a ~/.ssh-relative path so the config stays portable.
            local identity="$IDENTITY"
            [[ "$identity" == "$HOME/"* ]] && identity="~/${identity#"$HOME/"}"
            printf '    IdentityFile %s\n' "$identity"
            printf '    IdentitiesOnly yes\n'
        fi
        printf '\n'
        printf '    # Agent hardening: never ask for interactive passwords/prompts\n'
        printf '    BatchMode yes\n'
        printf '    StrictHostKeyChecking accept-new\n'
        printf '\n'
        printf '    # Instant execution (Connection Multiplexing)\n'
        printf '    ControlMaster auto\n'
        printf '    ControlPath ~/.ssh/bifrost-%%r@%%h:%%p\n'
        printf '    ControlPersist 10m\n'
        printf '\n'
        printf '    # Anti-lag / keepalive\n'
        printf '    ServerAliveInterval 15\n'
        printf '    ServerAliveCountMax 3\n'
        printf '%s\n' "$end"
    } >> "$tmp"

    mv "$tmp" "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
}

if (( DO_SSH_CONFIG )); then
    say "Configuring SSH multiplexing for host '$HOST'"
    if [[ -z "$VPS_IP" ]]; then
        warn "no VPS IP given - wrote a placeholder block."
        warn "edit $SSH_CONFIG and replace the HostName/User lines."
        VPS_IP="YOUR_VPS_IP"
        VPS_USER="${VPS_USER:-$USER}"
        write_ssh_block
        printf '        %ssh config:%s %s\n' "$C_DIM" "$C_OFF" "$SSH_CONFIG"
    else
        write_ssh_block
        ok "wrote managed block to $SSH_CONFIG"
    fi
fi

# ------------------------------------------------------------- final check --
say "Verifying"
if ssh -G "$HOST" >/dev/null 2>&1; then
    ok "ssh resolves the alias '$HOST'"
else
    warn "ssh could not resolve '$HOST' - check the block in $SSH_CONFIG"
fi

printf '\n%sThe bridge is ready.%s\n\n' "$C_BLD" "$C_OFF"
cat <<EOF
    Next steps:
      1. Make sure your public key is on the VPS:
           ssh-copy-id ${VPS_USER:+$VPS_USER@}${VPS_IP:-<vps-ip>}
      2. Open the bridge:
           ${INSTALLED_TO##*/} open
      3. Run a command:
           ${INSTALLED_TO##*/} "uptime && free -h"
      4. Check the diagnostics:
           ${INSTALLED_TO##*/} doctor
EOF
