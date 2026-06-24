#!/usr/bin/env bash
# whispertype installer — user-level, idempotent.
#
# Installs (or updates) the bits required for push-to-talk dictation:
#   - whisper.cpp (cloned + built, CUDA when nvcc is present)
#   - a Whisper ggml model (default large-v3 ~3 GB; pick another with the
#     interactive prompt or WHISPERTYPE_INSTALL_MODEL=<name>)
#   - $HOME/.config/whispertype/config recording the chosen model
#   - $HOME/.local/bin/whispertype toggle script
#   - $HOME/.config/systemd/user/whispertype-ydotoold.service
#   - GNOME: caps:menu xkb option (merged, not clobbered)
#   - GNOME custom shortcut: Menu key -> whispertype
#
# Re-running the installer is safe: every step checks current state first.

set -euo pipefail

# --- paths ------------------------------------------------------------------

# When piped from curl (`curl ... | bash`), BASH_SOURCE is unset and $0 is "bash".
# Detect that case and fetch the loose files we need (toggle script + systemd
# unit) from GitHub into a tempdir we clean up on exit. Otherwise run from the
# clone we're already sitting in.
RAW_URL_BASE="${WHISPERTYPE_RAW_URL_BASE:-https://raw.githubusercontent.com/kungla/whispertype/main}"

SCRIPT_SRC="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=""
if [ -f "$SCRIPT_SRC" ]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SRC")" && pwd)"
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/bin/whispertype" ]; then
  REPO_ROOT="$SCRIPT_DIR"
else
  REPO_ROOT="$(mktemp -d -t whispertype-install.XXXXXX)"
  trap 'rm -rf "$REPO_ROOT"' EXIT
  mkdir -p "$REPO_ROOT/bin" "$REPO_ROOT/share/systemd"
  echo "  fetching whispertype assets from $RAW_URL_BASE ..."
  curl -fsSL "$RAW_URL_BASE/bin/whispertype" -o "$REPO_ROOT/bin/whispertype"
  curl -fsSL "$RAW_URL_BASE/share/systemd/whispertype-ydotoold.service" \
    -o "$REPO_ROOT/share/systemd/whispertype-ydotoold.service"
  chmod +x "$REPO_ROOT/bin/whispertype"
fi

WHISPERTYPE_HOME="${WHISPERTYPE_HOME:-$HOME/.local/share/whispertype}"
WHISPER_DIR="$WHISPERTYPE_HOME/whisper.cpp"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SCRIPT_DEST="$BIN_DIR/whispertype"
UNIT_NAME="whispertype-ydotoold.service"
UNIT_DEST="$SYSTEMD_USER_DIR/$UNIT_NAME"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whispertype"
CONFIG_FILE="$CONFIG_DIR/config"

GNOME_KEYBIND_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/whispertype/"
GNOME_KEYBIND_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${GNOME_KEYBIND_PATH}"

# --- pretty output ----------------------------------------------------------

say() { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  WARN: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- 1. dependencies --------------------------------------------------------

install_apt_deps() {
  say "Installing system packages (apt)"
  local pkgs=(ydotool alsa-utils libcanberra-gtk3-module cmake build-essential git curl xz-utils libblas-dev liblapack-dev pkg-config)
  note "Will install: ${pkgs[*]}"
  sudo apt-get update
  sudo apt-get install -y "${pkgs[@]}"
}

print_manual_deps() {
  local mgr="$1"
  cat >&2 <<EOF

System package install is not automated for $mgr yet.

Please install the equivalent of these packages and re-run install.sh:
  ydotool, alsa-utils, libcanberra (GTK module), cmake, gcc/g++, git, curl, xz

PRs welcome to automate this for $mgr.
EOF
  exit 1
}

ensure_system_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    install_apt_deps
  elif command -v dnf >/dev/null 2>&1; then
    print_manual_deps dnf
  elif command -v pacman >/dev/null 2>&1; then
    print_manual_deps pacman
  else
    print_manual_deps "unknown (no apt/dnf/pacman)"
  fi
}

# --- 2. whisper.cpp clone ---------------------------------------------------

clone_whisper() {
  say "Setting up whisper.cpp at $WHISPER_DIR"
  mkdir -p "$WHISPERTYPE_HOME"
  if [ -d "$WHISPER_DIR/.git" ]; then
    note "whisper.cpp already cloned, skipping"
  else
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
  fi
}

# --- 3. build whisper.cpp ---------------------------------------------------

build_whisper() {
  say "Building whisper.cpp"
  if [ -x "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    note "whisper-cli already built at $WHISPER_DIR/build/bin/whisper-cli, skipping"
    note "(remove $WHISPER_DIR/build to force rebuild)"
    return 0
  fi

  cd "$WHISPER_DIR"
  if command -v nvcc >/dev/null 2>&1; then
    note "nvcc detected -> CUDA build"
    # CRITICAL: -j2 cap. nvcc + ggml-cuda template translation units peak at
    # several GB each; a full -j$(nproc) build can blow past available RAM+swap
    # and get the process OOM-killed. Do NOT raise this without thought.
    cmake -B build -DGGML_CUDA=1 -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j2
  else
    note "nvcc not found -> CPU build (with BLAS if available)"
    cmake -B build -DGGML_BLAS=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j"$(nproc)"
  fi

  [ -x "$WHISPER_DIR/build/bin/whisper-cli" ] || die "build failed: whisper-cli not produced"
  cd - >/dev/null
}

# --- 4. choose + download model ---------------------------------------------

# Install-time model menu: "name|approx size|description". large-v3 stays first
# and is the default. Any valid whisper.cpp model name also works (see
# models/download-ggml-model.sh for the full list).
MODEL_CHOICES=(
  "large-v3|~2.9 GB|Most accurate. Full large model — best quality, slowest, biggest. (default)"
  "large-v3-turbo|~1.5 GB|Newer & ~5-8x faster, slightly lower accuracy. Great for everyday dictation."
  "large-v3-turbo-q5_0|~547 MB|Quantised turbo — smallest & fastest, minor extra accuracy loss."
  "medium|~1.5 GB|Older mid-size model. Lower accuracy than large-v3; modest resources."
  "small|~466 MB|Small & fast, noticeably lower accuracy. For low-RAM / no-GPU machines."
)
DEFAULT_MODEL="large-v3"

print_model_choices() {
  local i=1 entry name size desc
  for entry in "${MODEL_CHOICES[@]}"; do
    IFS='|' read -r name size desc <<<"$entry"
    printf '    %d) %-21s %-9s %s\n' "$i" "$name" "$size" "$desc"
    i=$((i + 1))
  done
}

# Derive the model name (e.g. large-v3-turbo) from a WHISPERTYPE_MODEL path in an
# existing config, so a plain reinstall keeps the model you already chose.
config_model_name() {
  [ -f "$CONFIG_FILE" ] || return 1
  local line val
  line="$(grep -E '^[[:space:]]*WHISPERTYPE_MODEL=' "$CONFIG_FILE" 2>/dev/null | tail -1)" || return 1
  [ -n "$line" ] || return 1
  val="${line#*=}"; val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  val="$(basename "$val")"; val="${val#ggml-}"; val="${val%.bin}"
  [ -n "$val" ] && printf '%s' "$val"
}

choose_model() {
  # Precedence: explicit env var > existing config > interactive prompt > default.
  if [ -n "${WHISPERTYPE_INSTALL_MODEL:-}" ]; then
    MODEL_NAME="$WHISPERTYPE_INSTALL_MODEL"
    note "model from WHISPERTYPE_INSTALL_MODEL: $MODEL_NAME"
    return 0
  fi
  local existing
  if existing="$(config_model_name)"; then
    MODEL_NAME="$existing"
    note "keeping model from existing config: $MODEL_NAME"
    return 0
  fi
  if [ -t 0 ]; then
    print_model_choices
    printf '  Selection [1-%d] or model name, Enter for default (%s): ' \
      "${#MODEL_CHOICES[@]}" "$DEFAULT_MODEL"
    local reply name
    read -r reply || reply=""
    if [ -z "$reply" ]; then
      MODEL_NAME="$DEFAULT_MODEL"
    elif printf '%s' "$reply" | grep -qE '^[0-9]+$' \
         && [ "$reply" -ge 1 ] && [ "$reply" -le "${#MODEL_CHOICES[@]}" ]; then
      IFS='|' read -r name _ _ <<<"${MODEL_CHOICES[$((reply - 1))]}"
      MODEL_NAME="$name"
    else
      MODEL_NAME="$reply"   # accept any valid whisper.cpp model name
    fi
  else
    MODEL_NAME="$DEFAULT_MODEL"
    note "Using default model: $DEFAULT_MODEL"
    note "To pick another, re-run with WHISPERTYPE_INSTALL_MODEL=<name>. Choices:"
    print_model_choices
  fi
}

download_model() {
  say "Choosing Whisper model"
  choose_model
  local model_path="$WHISPER_DIR/models/ggml-${MODEL_NAME}.bin"
  if [ -s "$model_path" ]; then
    note "model '$MODEL_NAME' already present, skipping download"
  else
    note "downloading model: $MODEL_NAME"
    cd "$WHISPER_DIR"
    bash models/download-ggml-model.sh "$MODEL_NAME"
    cd - >/dev/null
    [ -s "$model_path" ] || die "model download failed: $model_path missing (is '$MODEL_NAME' a valid whisper.cpp model? see models/download-ggml-model.sh)"
  fi
  MODEL_PATH="$model_path"
  write_model_config
}

# Persist the chosen model so the toggle script (launched by the GNOME shortcut,
# with no inherited env) uses it, and so it survives reinstalls. Only touches the
# WHISPERTYPE_MODEL line — any other settings the user added are left intact.
write_model_config() {
  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ] && grep -qE '^[[:space:]]*WHISPERTYPE_MODEL=' "$CONFIG_FILE"; then
    local tmp
    tmp="$(mktemp)"
    sed "s|^[[:space:]]*WHISPERTYPE_MODEL=.*|WHISPERTYPE_MODEL=\"$MODEL_PATH\"|" "$CONFIG_FILE" >"$tmp"
    mv "$tmp" "$CONFIG_FILE"
  elif [ -f "$CONFIG_FILE" ]; then
    printf 'WHISPERTYPE_MODEL="%s"\n' "$MODEL_PATH" >>"$CONFIG_FILE"
  else
    cat >"$CONFIG_FILE" <<EOF
# whispertype config — sourced by ~/.local/bin/whispertype on every run.
# Simple KEY=value lines. To switch models, change the path below (download
# others with: bash $WHISPER_DIR/models/download-ggml-model.sh <name>).
# Other knobs you may add: WHISPERTYPE_LANG, WHISPERTYPE_MAX_SECS, WHISPERTYPE_BIN.
WHISPERTYPE_MODEL="$MODEL_PATH"
EOF
  fi
  note "active model recorded in $CONFIG_FILE"
}

# --- 5. install toggle script ----------------------------------------------

install_script() {
  say "Installing whispertype script to $SCRIPT_DEST"
  mkdir -p "$BIN_DIR"
  install -m 0755 "$REPO_ROOT/bin/whispertype" "$SCRIPT_DEST"
  note "installed"

  case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *)
      warn "$BIN_DIR is not on your PATH."
      warn "Add this line to your ~/.bashrc or ~/.zshrc:"
      warn "    export PATH=\"\$HOME/.local/bin:\$PATH\""
      ;;
  esac
}

# --- 6. systemd user unit ---------------------------------------------------

install_unit() {
  say "Installing systemd user unit"
  mkdir -p "$SYSTEMD_USER_DIR"
  install -m 0644 "$REPO_ROOT/share/systemd/$UNIT_NAME" "$UNIT_DEST"
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  note "$UNIT_NAME enabled and started"
}

# --- 7. xkb caps:menu (merge, do not clobber) ------------------------------

merge_xkb_caps_menu() {
  say "Configuring xkb: caps:menu (Caps Lock acts as Menu key)"
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found (not on GNOME?). Skipping xkb config."
    warn "Manual: map Caps Lock to the Menu keysym however your DE prefers."
    return 0
  fi

  # Current value, e.g. "['grp_led:scroll']" or "@as []"
  local current
  current="$(gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null || echo "@as []")"

  if printf '%s' "$current" | grep -q "'caps:menu'"; then
    note "caps:menu already set, skipping"
    return 0
  fi

  # Extract existing options between [ and ], strip whitespace.
  local inner stripped
  inner="$(printf '%s' "$current" | sed -n "s/^.*\[\(.*\)\].*$/\1/p")"
  stripped="$(printf '%s' "$inner" | tr -d '[:space:]')"

  local new
  if [ -z "$stripped" ]; then
    new="['caps:menu']"
  else
    new="[$inner, 'caps:menu']"
  fi

  gsettings set org.gnome.desktop.input-sources xkb-options "$new"
  note "xkb-options now: $(gsettings get org.gnome.desktop.input-sources xkb-options)"

  # Best-effort: apply the new keymap *live* so a logout isn't required. GNOME
  # Wayland normally only reads xkb-options at login; re-writing the input
  # `sources` key forces mutter to rebuild the keymap now, on versions that
  # honour it. Harmless where it's ignored — worst case the user logs out once.
  apply_xkb_live
}

# Nudge the compositor to rebuild its keymap without a logout by re-writing the
# input `sources` gsetting (toggle off, then restore). Only attempted when at
# least one input source is configured; a silent no-op otherwise. This is
# best-effort: some GNOME versions still defer xkb changes to the next login.
apply_xkb_live() {
  local sources
  sources="$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo "@as []")"
  case "$sources" in
    "@as []"|"[]"|"")
      note "no configured input sources to nudge; live re-apply skipped"
      return 0
      ;;
  esac
  note "nudging mutter to apply caps:menu live (no logout) ..."
  gsettings set org.gnome.desktop.input-sources sources "[]" 2>/dev/null || true
  gsettings set org.gnome.desktop.input-sources sources "$sources" 2>/dev/null || true
}

# --- 8. GNOME custom shortcut ----------------------------------------------

register_keybinding() {
  say "Registering GNOME custom shortcut: Menu -> whispertype"
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found. Skipping shortcut registration."
    warn "Manual: bind the Menu keysym to: $SCRIPT_DEST"
    return 0
  fi

  # Append our path to the custom-keybindings list, deduplicating.
  local current
  current="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")"

  if ! printf '%s' "$current" | grep -q "'$GNOME_KEYBIND_PATH'"; then
    local inner stripped new
    inner="$(printf '%s' "$current" | sed -n "s/^.*\[\(.*\)\].*$/\1/p")"
    stripped="$(printf '%s' "$inner" | tr -d '[:space:]')"
    if [ -z "$stripped" ]; then
      new="['$GNOME_KEYBIND_PATH']"
    else
      new="[$inner, '$GNOME_KEYBIND_PATH']"
    fi
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$new"
    note "custom-keybindings list updated"
  else
    note "shortcut path already registered, skipping list update"
  fi

  # Always set/overwrite the actual binding properties (cheap, ensures freshness).
  gsettings set "$GNOME_KEYBIND_SCHEMA" name 'whispertype'
  gsettings set "$GNOME_KEYBIND_SCHEMA" command "$SCRIPT_DEST"
  gsettings set "$GNOME_KEYBIND_SCHEMA" binding 'Menu'
  note "binding set: Menu -> $SCRIPT_DEST"
}

# --- 9. success message -----------------------------------------------------

print_success() {
  cat <<EOF

================================================================
All set. Press Caps Lock to start. Press it again to transcribe
and type into the focused window.

Model: ${MODEL_NAME:-large-v3}  (change any time by editing $CONFIG_FILE —
see README.md "Changing the model").

If Caps Lock doesn't trigger dictation yet, log out and back in
ONCE so the compositor applies the Caps Lock -> Menu mapping.
This is a one-time step: every future login applies it
automatically. (If your keyboard has a physical Menu key, it
works right away, no logout needed.)

See README.md "Troubleshooting" for more.
================================================================
EOF
}

# --- main -------------------------------------------------------------------

main() {
  ensure_system_deps
  clone_whisper
  build_whisper
  download_model
  install_script
  install_unit
  merge_xkb_caps_menu
  register_keybinding
  print_success
}

main "$@"
