#!/usr/bin/env bash

# Optional paths - only bind if they exist
OPTIONAL_BINDS=""
[ -d "$HOME/.nvm" ] && OPTIONAL_BINDS="$OPTIONAL_BINDS --ro-bind $HOME/.nvm $HOME/.nvm"
[ -d "$HOME/.config/git" ] && OPTIONAL_BINDS="$OPTIONAL_BINDS --ro-bind $HOME/.config/git $HOME/.config/git"
[ -d "$HOME/.config/gh" ] && OPTIONAL_BINDS="$OPTIONAL_BINDS --ro-bind $HOME/.config/gh $HOME/.config/gh"
[ -d "$HOME/.confluence-cli/" ] && OPTIONAL_BINDS="$OPTIONAL_BINDS --ro-bind $HOME/.confluence-cli/ $HOME/.confluence-cli/"
[ -d "/home/linuxbrew/.linuxbrew/bin" ] && OPTIONAL_BINDS="$OPTIONAL_BINDS --ro-bind /home/linuxbrew/.linuxbrew/bin /home/linuxbrew/.linuxbrew/bin"
[ -d "$HOME/.scripts" ] && OPTIONAL_BINDS="$OPTIONAL_BINDS --ro-bind $HOME/.scripts $HOME/.scripts"

# SSH agent socket - only bind if SSH_AUTH_SOCK is set and exists
SSH_BINDS=""
SSH_ENV=""
if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  SSH_BINDS="--bind $(dirname "$SSH_AUTH_SOCK") $(dirname "$SSH_AUTH_SOCK") --ro-bind $SSH_AUTH_SOCK $SSH_AUTH_SOCK"
  SSH_ENV="--setenv SSH_AUTH_SOCK $SSH_AUTH_SOCK"
fi

# SSH public keys - bind whichever key types exist
SSH_PUBKEY_BINDS=""
for pubkey in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_ed25519_LIN_GM0P2L94.pub"; do
  [ -f "$pubkey" ] && SSH_PUBKEY_BINDS="$SSH_PUBKEY_BINDS --ro-bind $pubkey $pubkey"
done

XDG_RUNTIME="/run/user/$(id -u)"

# D-Bus session bus - required for GNOME Keyring / Secret Service access
# (Claude Code stores auth tokens in the system keyring)
DBUS_BINDS=""
DBUS_ENV=""
if [ -S "$XDG_RUNTIME/bus" ]; then
  DBUS_BINDS="--bind $XDG_RUNTIME/bus $XDG_RUNTIME/bus"
  DBUS_ENV="--setenv DBUS_SESSION_BUS_ADDRESS unix:path=$XDG_RUNTIME/bus"
fi

# PODMAN
PODMAN_BINDS=""
if [ -d "$XDG_RUNTIME/podman" ]; then
  PODMAN_BINDS="--bind $XDG_RUNTIME/podman $XDG_RUNTIME/podman"
fi

# zellij pipe
ZELLIJ_PIPE_BINDS=""
ZELLIJ_ENV=""
if [ -d "$XDG_RUNTIME/zellij" ]; then
  ZELLIJ_PIPE_BINDS="$ZELLIJ_PIPE_BINDS --ro-bind $HOME/.cargo/bin/zellij $HOME/.cargo/bin/zellij"
  ZELLIJ_PIPE_BINDS="$ZELLIJ_PIPE_BINDS --ro-bind $HOME/.config/zellij $HOME/.config/zellij"
  ZELLIJ_PIPE_BINDS="$ZELLIJ_PIPE_BINDS --bind $XDG_RUNTIME/zellij $XDG_RUNTIME/zellij"

  ZELLIJ_ENV="$ZELLIJ_ENV --setenv ZELLIJ_SESSION_NAME $ZELLIJ_SESSION_NAME"
  ZELLIJ_ENV="$ZELLIJ_ENV --setenv ZELLIJ_PANE_ID $ZELLIJ_PANE_ID"
fi

# GNOME Keyring sockets - needed for secret service credential retrieval
KEYRING_BINDS=""
if [ -d "$XDG_RUNTIME/keyring" ]; then
  KEYRING_BINDS="--bind $XDG_RUNTIME/keyring $XDG_RUNTIME/keyring"
fi

# GPG configuration
# Bind the full .gnupg directory (with write access for trustdb updates)
# and the GPG agent socket directory for signing operations
GPG_ENV=""
[ -n "$GPG_SIGNING_KEY_ID" ] && GPG_ENV="--setenv GPG_SIGNING_KEY_ID $GPG_SIGNING_KEY_ID"

GPG_BINDS=""
# Bind the .gnupg directory with write access (needed for trustdb, key operations)
if [ -d "$HOME/.gnupg" ]; then
  GPG_BINDS="--bind $HOME/.gnupg $HOME/.gnupg"
fi

# Bind the GPG agent socket directory (usually /run/user/<uid>/gnupg)
GPG_SOCKDIR=$(gpgconf --list-dirs socketdir 2>/dev/null)
if [ -n "$GPG_SOCKDIR" ] && [ -d "$GPG_SOCKDIR" ]; then
  GPG_BINDS="$GPG_BINDS --bind $GPG_SOCKDIR $GPG_SOCKDIR"
fi

bwrap \
  --ro-bind /usr /usr \
  --ro-bind /lib /lib \
  --ro-bind /lib64 /lib64 \
  --ro-bind /bin /bin \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind /etc/hosts /etc/hosts \
  --ro-bind /etc/ssl /etc/ssl \
  --ro-bind /etc/passwd /etc/passwd \
  --ro-bind /etc/group /etc/group \
  --ro-bind "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts" \
  --tmpfs /tmp \
  $SSH_BINDS \
  $SSH_PUBKEY_BINDS \
  --ro-bind /usr/bin/gpg /usr/bin/gpg \
  $GPG_ENV \
  --ro-bind "$HOME/Dotfiles" "$HOME/Dotfiles" \
  --ro-bind "$HOME/.gitconfig" "$HOME/.gitconfig" \
  --ro-bind "$HOME/.git-pro.conf" "$HOME/.git-pro.conf" \
  --ro-bind "$HOME/.git-perso.conf" "$HOME/.git-perso.conf" \
  $OPTIONAL_BINDS \
  --ro-bind "$HOME/.local" "$HOME/.local" \
  --ro-bind "$HOME/Code/PRO" "$HOME/Code/PRO" \
  --ro-bind "$HOME/.m2/settings.xml" "$HOME/.m2/settings.xml" \
  --bind "$HOME/.m2/repository" "$HOME/.m2/repository" \
  --bind "$HOME/.local/share/kotlin/daemon" "$HOME/.local/share/kotlin/daemon" \
  --bind "$HOME/.local/share/uv/tools/" "$HOME/.local/share/uv/tools/" \
  --bind "$HOME/.claude" "$HOME/.claude" \
  --bind "$HOME/.claude.json" "$HOME/.claude.json" \
  --bind "$PWD" "$PWD" \
  $GPG_BINDS \
  $DBUS_BINDS \
  $PODMAN_BINDS \
  $ZELLIJ_PIPE_BINDS \
  $KEYRING_BINDS \
  --proc /proc \
  --dev /dev \
  --setenv HOME "$HOME" \
  $SSH_ENV \
  --setenv USER "$USER" \
  $DBUS_ENV \
  $ZELLIJ_ENV \
  --share-net \
  --unshare-pid \
  --die-with-parent \
  --chdir "$PWD" \
  "$(which claude)" "$@"
