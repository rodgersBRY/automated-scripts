#!/usr/bin/env bash
#
# manage-user.sh — Add or remove a user on a Debian/Ubuntu server.
#
# Usage:
#   sudo ./manage-user.sh --add                     # interactive add
#   sudo ./manage-user.sh --add -u dev1 -s -k "ssh-ed25519 AAAA..."
#   sudo ./manage-user.sh --remove                  # interactive remove
#   sudo ./manage-user.sh --remove -u dev1 --purge-home
#
# Flags:
#   --add            Create a user
#   --remove         Remove a user
#   -u USERNAME      Username
#   -s               (add) Grant sudo
#   -k PUBKEY        (add) SSH public key string
#   --purge-home     (remove) Also delete the home directory  [DESTRUCTIVE]
#   --keep-home      (remove) Keep the home directory
#   -h, --help       Help

set -euo pipefail

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root (sudo ./manage-user.sh ...)"
command -v adduser >/dev/null || err "adduser/deluser not found — this script targets Debian/Ubuntu."

MODE=""
USERNAME=""
GRANT_SUDO=""
PUBKEY=""
HOME_ACTION=""   # purge | keep | "" (ask)

# ---------------------------------------------------------------- arg parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)        MODE="add"; shift ;;
    --remove)     MODE="remove"; shift ;;
    -u)           USERNAME="${2:-}"; shift 2 ;;
    -s)           GRANT_SUDO="yes"; shift ;;
    -k)           PUBKEY="${2:-}"; shift 2 ;;
    --purge-home) HOME_ACTION="purge"; shift ;;
    --keep-home)  HOME_ACTION="keep"; shift ;;
    -h|--help)    grep '^#' "$0" | head -n 18; exit 0 ;;
    *)            err "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$MODE" ]] || err "Specify --add or --remove (see --help)."

if [[ -z "$USERNAME" ]]; then
  read -rp "Username: " USERNAME
fi
[[ "$USERNAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] \
  || err "Invalid username '$USERNAME'."

# ================================================================ ADD
do_add() {
  id "$USERNAME" &>/dev/null && err "User '$USERNAME' already exists. Nothing done."

  info "Creating user '$USERNAME'..."
  adduser --gecos "" "$USERNAME"

  if [[ -z "$GRANT_SUDO" ]]; then
    read -rp "Grant sudo to '$USERNAME'? Only if they genuinely need admin rights. [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] && GRANT_SUDO="yes"
  fi
  if [[ "$GRANT_SUDO" == "yes" ]]; then
    usermod -aG sudo "$USERNAME"
    info "Added '$USERNAME' to sudo group."
  else
    info "No sudo granted (good default)."
  fi

  if [[ -z "$PUBKEY" ]]; then
    cat <<'EOF'

--- How to get an SSH public key ---
The USER generates a keypair on THEIR OWN machine:

    ssh-keygen -t ed25519 -C "their-email@example.com"

They send you ~/.ssh/id_ed25519.pub (starts with "ssh-ed25519 AAAA...").
NEVER generate the keypair on the server and send them the private key.
------------------------------------

EOF
    read -rp "Paste the PUBLIC key now (or Enter to skip): " PUBKEY
  fi

  if [[ -n "$PUBKEY" ]]; then
    [[ "$PUBKEY" == *"PRIVATE KEY"* ]] && err "That is a PRIVATE key. Get the .pub file instead."
    [[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+ ]] \
      || err "That doesn't look like a valid SSH public key. (User was still created.)"

    local ssh_dir="/home/$USERNAME/.ssh"
    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$ssh_dir"
    echo "$PUBKEY" >> "$ssh_dir/authorized_keys"
    chown "$USERNAME:$USERNAME" "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    info "SSH key installed."
  else
    info "Skipped SSH key setup."
  fi

  echo
  info "Done. User: $USERNAME | Sudo: ${GRANT_SUDO:-no} | SSH key: $([[ -n "$PUBKEY" ]] && echo installed || echo none)"
  echo "VERIFY from another terminal before closing this session:  ssh $USERNAME@<server-ip>"
}

# ================================================================ REMOVE
do_remove() {
  id "$USERNAME" &>/dev/null || err "User '$USERNAME' does not exist."

  # Refuse the catastrophic cases
  [[ "$USERNAME" == "root" ]] && err "Refusing to remove root."
  local uid; uid=$(id -u "$USERNAME")
  [[ "$uid" -lt 1000 ]] && err "'$USERNAME' (uid $uid) is a system account. Refusing — removing system users can break services."
  [[ "$USERNAME" == "${SUDO_USER:-}" ]] && err "Refusing to remove the account you are currently sudo'd from. Log in as a different admin first."

  # Warn if they're the last sudoer
  if id -nG "$USERNAME" | grep -qw sudo; then
    local other_sudoers
    other_sudoers=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v "^$USERNAME$" | grep -v '^$' || true)
    if [[ -z "$other_sudoers" ]]; then
      err "'$USERNAME' is the ONLY member of the sudo group. Removing them could lock you out of admin access. Add another sudoer first."
    fi
  fi

  # Show what's about to happen
  echo
  echo "About to remove: $USERNAME (uid $uid)"
  echo "  Groups:     $(id -nG "$USERNAME")"
  echo "  Home:       $(getent passwd "$USERNAME" | cut -d: -f6)"
  echo "  Processes:  $(pgrep -cu "$USERNAME" 2>/dev/null || echo 0) running"
  echo
  read -rp "Type the username again to confirm removal: " confirm
  [[ "$confirm" == "$USERNAME" ]] || err "Confirmation did not match. Nothing done."

  # Kill their processes (deluser fails on active sessions otherwise)
  if pgrep -u "$USERNAME" >/dev/null 2>&1; then
    info "Killing processes owned by '$USERNAME'..."
    pkill -TERM -u "$USERNAME" || true
    sleep 2
    pkill -KILL -u "$USERNAME" 2>/dev/null || true
  fi

  # Decide on home directory
  if [[ -z "$HOME_ACTION" ]]; then
    read -rp "Delete their home directory too? This is IRREVERSIBLE. [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] && HOME_ACTION="purge" || HOME_ACTION="keep"
  fi

  if [[ "$HOME_ACTION" == "purge" ]]; then
    info "Removing '$USERNAME' and their home directory..."
    deluser --remove-home "$USERNAME"
  else
    info "Removing '$USERNAME' (home directory kept)..."
    deluser "$USERNAME"
    echo "NOTE: /home/$USERNAME still exists, now owned by orphaned uid $uid."
    echo "      Archive or reassign it:  tar czf /root/${USERNAME}-home.tar.gz /home/$USERNAME"
  fi

  # Point out what deluser does NOT clean up
  echo
  info "Removed. Things this script did NOT do (check manually if relevant):"
  echo "  - Files owned by uid $uid outside /home (find / -xdev -uid $uid 2>/dev/null)"
  echo "  - Their cron jobs if any survived (/var/spool/cron/crontabs/)"
  echo "  - Custom sudoers entries (grep -r '$USERNAME' /etc/sudoers /etc/sudoers.d/)"
  echo "  - Any app-level access (databases, n8n, dashboards) tied to this person"
}

case "$MODE" in
  add)    do_add ;;
  remove) do_remove ;;
esac