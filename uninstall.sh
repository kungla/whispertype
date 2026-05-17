#!/usr/bin/env bash
# whispertype uninstaller — undoes what install.sh did, conservatively.
#
# Removes:
#   - the whispertype binary from ~/.local/bin
#   - the user systemd unit (stopped + disabled + file removed)
#   - the GNOME custom shortcut entry
#   - 'caps:menu' from xkb-options (preserves anything else there)
#
# Does NOT remove:
#   - ~/.local/share/whispertype  (whisper.cpp checkout + ~3 GB model)
#     -> you decide if you want those gone

set -euo pipefail

WHISPERTYPE_HOME="${WHISPERTYPE_HOME:-$HOME/.local/share/whispertype}"
BIN_DIR="$HOME/.local/bin"
SCRIPT_DEST="$BIN_DIR/whispertype"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
UNIT_NAME="whispertype-ydotoold.service"
UNIT_DEST="$SYSTEMD_USER_DIR/$UNIT_NAME"

GNOME_KEYBIND_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/whispertype/"

say() { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  WARN: %s\n' "$*" >&2; }

# --- script -----------------------------------------------------------------
say "Removing whispertype script"
if [ -e "$SCRIPT_DEST" ]; then
  rm -f "$SCRIPT_DEST"
  note "removed $SCRIPT_DEST"
else
  note "not installed at $SCRIPT_DEST, skipping"
fi

# --- systemd unit -----------------------------------------------------------
say "Disabling systemd user unit"
if systemctl --user list-unit-files 2>/dev/null | grep -q "^$UNIT_NAME"; then
  systemctl --user disable --now "$UNIT_NAME" || true
  note "$UNIT_NAME disabled and stopped"
fi
if [ -e "$UNIT_DEST" ]; then
  rm -f "$UNIT_DEST"
  systemctl --user daemon-reload || true
  note "removed $UNIT_DEST"
else
  note "no unit file at $UNIT_DEST, skipping"
fi

# --- GNOME custom shortcut --------------------------------------------------
say "Removing GNOME custom shortcut"
if command -v gsettings >/dev/null 2>&1; then
  current="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")"
  if printf '%s' "$current" | grep -q "'$GNOME_KEYBIND_PATH'"; then
    # Remove our path (with optional surrounding comma/space) from the list literal.
    cleaned="$(printf '%s' "$current" \
      | sed "s|, *'$GNOME_KEYBIND_PATH'||g; s|'$GNOME_KEYBIND_PATH', *||g; s|'$GNOME_KEYBIND_PATH'||g")"
    # If we now have an empty list, normalize to "@as []".
    if printf '%s' "$cleaned" | grep -Eq "^\[\s*\]$"; then
      cleaned="@as []"
    fi
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$cleaned"
    note "removed from custom-keybindings list"
  else
    note "shortcut not registered, skipping list edit"
  fi

  # Reset the schema entries for our path (best-effort).
  gsettings reset "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${GNOME_KEYBIND_PATH}" name 2>/dev/null || true
  gsettings reset "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${GNOME_KEYBIND_PATH}" command 2>/dev/null || true
  gsettings reset "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${GNOME_KEYBIND_PATH}" binding 2>/dev/null || true
else
  warn "gsettings not available, skipping GNOME shortcut cleanup"
fi

# --- xkb caps:menu (remove only, preserve others) --------------------------
say "Removing caps:menu from xkb-options (preserving other options)"
if command -v gsettings >/dev/null 2>&1; then
  current="$(gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null || echo "@as []")"
  if printf '%s' "$current" | grep -q "'caps:menu'"; then
    cleaned="$(printf '%s' "$current" \
      | sed "s|, *'caps:menu'||g; s|'caps:menu', *||g; s|'caps:menu'||g")"
    if printf '%s' "$cleaned" | grep -Eq "^\[\s*\]$"; then
      cleaned="@as []"
    fi
    gsettings set org.gnome.desktop.input-sources xkb-options "$cleaned"
    note "xkb-options now: $(gsettings get org.gnome.desktop.input-sources xkb-options)"
    note "(log out / log in for Caps Lock to revert)"
  else
    note "caps:menu not present, skipping"
  fi
else
  warn "gsettings not available, skipping xkb-options cleanup"
fi

# --- data dir note ----------------------------------------------------------
cat <<EOF

================================================================
Done. whisper.cpp checkout and the ~3 GB model are still at:

    $WHISPERTYPE_HOME

Remove manually if no longer needed:

    rm -rf "$WHISPERTYPE_HOME"
================================================================
EOF
