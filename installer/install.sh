#!/usr/bin/env bash
# GTA FPV Drone installer (Linux). Copies (or links) drone.lua + drone/ into
# a GTA San Andreas install, checks for the MoonLoader libraries this
# script needs, and sets up the controller bridge daemon.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

say()  { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*"; }

say "=== GTA FPV Drone installer ==="
say "This copies drone.lua + drone/ from:"
say "  $REPO_DIR"
say "into your GTA San Andreas install, and checks required MoonLoader libraries."
say ""

# --- 1. GTA SA path -----------------------------------------------------
read -rp "Path to your GTA San Andreas folder: " GTA_PATH
GTA_PATH="${GTA_PATH%/}"

if [ ! -d "$GTA_PATH" ]; then
    err "That folder doesn't exist: $GTA_PATH"
    exit 1
fi
if [ ! -e "$GTA_PATH/gta_sa.exe" ]; then
    warn "Warning: no gta_sa.exe found there -- are you sure this is the right folder?"
fi
if [ ! -d "$GTA_PATH/moonloader" ]; then
    err "No moonloader/ folder found in $GTA_PATH -- install MoonLoader first (see below), then re-run this installer."
fi

# --- 2. Dependency check, all at once ------------------------------------
say ""
say "--- Checking dependencies ---"

declare -a MISSING=()
check() {
    local label="$1" path="$2" link="$3"
    if [ -e "$path" ]; then
        ok "  [OK]      $label"
    else
        err "  [MISSING] $label"
        MISSING+=("$label -- $link")
    fi
}

check "MoonLoader (moonloader.asi)"      "$GTA_PATH/moonloader.asi"                  "https://blast.hk/moonloader/"
check "mimgui"                           "$GTA_PATH/moonloader/lib/mimgui"           "https://github.com/THE-FYP/mimgui"
check "SAMemory"                         "$GTA_PATH/moonloader/lib/SAMemory"         "search blast.hk's MoonLoader library section for 'SAMemory'"
check "luasocket"                        "$GTA_PATH/moonloader/lib/luasocket"        "https://github.com/lunarmodules/luasocket (or a MoonLoader 'extra libraries' pack on blast.hk)"
check "bass.lua (BASS FFI wrapper)"      "$GTA_PATH/moonloader/lib/bass.lua"         "search blast.hk's MoonLoader library section for a 'bass.lua' wrapper"
check "bass.dll (BASS audio library)"    "$GTA_PATH/bass.dll"                        "https://www.un4seen.com/ (free for non-commercial use)"

say ""
if [ "${#MISSING[@]}" -eq 0 ]; then
    ok "All dependencies found."
else
    warn "Missing ${#MISSING[@]} dependency(ies) -- the drone script needs ALL of these to work:"
    for m in "${MISSING[@]}"; do
        say "  - $m"
    done
    say "Install them, then re-run this installer (or just copy the files below now and add libraries later)."
fi

# --- 3. Copy or link -------------------------------------------------------
say ""
say "--- Install mode ---"
say "  copy - plain copy, works from a downloaded zip or a git clone (recommended)"
say "  link - drone/ is linked back to this folder (git pull updates your install); only useful if you cloned this with git"
read -rp "Copy or link? [copy] " MODE
MODE="${MODE:-copy}"

DEST_LUA="$GTA_PATH/moonloader/drone.lua"
DEST_DIR="$GTA_PATH/moonloader/drone"

rm -rf "$DEST_DIR"
cp "$REPO_DIR/drone.lua" "$DEST_LUA"

if [ "$MODE" = "link" ]; then
    ln -s "$REPO_DIR/drone" "$DEST_DIR"
    ok "Linked $DEST_DIR -> $REPO_DIR/drone"
else
    cp -r "$REPO_DIR/drone" "$DEST_DIR"
    ok "Copied drone/ into $DEST_DIR"
fi
ok "Copied drone.lua into $DEST_LUA"

# --- 4. uv (runs the controller bridge, auto-installs its one dependency) --
say ""
say "--- Controller bridge (uv) ---"
say "The bridge (controllerd.py) declares its own dependency (pysdl2) inline"
say "and runs via 'uv run', which installs it automatically on first run."

if ! command -v uv >/dev/null 2>&1; then
    warn "uv not found."
    read -rp "Install it now? [Y/n] " INSTALL_UV
    if [ "$INSTALL_UV" != "n" ] && [ "$INSTALL_UV" != "N" ]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # The official installer adds ~/.local/bin to PATH via shell rc files,
        # which a running script's current shell won't pick up -- resolve it
        # directly for the rest of this script instead of re-execing.
        if ! command -v uv >/dev/null 2>&1 && [ -x "$HOME/.local/bin/uv" ]; then
            export PATH="$HOME/.local/bin:$PATH"
        fi
    fi
fi

if command -v uv >/dev/null 2>&1; then
    ok "Found uv: $(uv --version 2>&1)"
else
    err "uv still not found -- install it manually: https://docs.astral.sh/uv/getting-started/installation/"
    err "(or install Python 3 + 'pip install pysdl2' yourself and run controllerd.py with plain python3 instead)"
fi

BRIDGE_PY="$DEST_DIR/bridge/controllerd.py"
RUN_CMD="uv run \"$BRIDGE_PY\""

# --- 5. Auto-start or manual ------------------------------------------------
say ""
say "--- Controller bridge startup ---"
say "The bridge must be running whenever you want to fly the drone. The exact command to run it manually:"
say ""
say "  $RUN_CMD"
say ""
read -rp "Set it up to start automatically via systemd --user? [y/N] " AUTOSTART
if [ "$AUTOSTART" = "y" ] || [ "$AUTOSTART" = "Y" ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    UV_BIN="$(command -v uv)"
    sed "s#ExecStart=.*#ExecStart=$UV_BIN run $BRIDGE_PY#" "$DEST_DIR/bridge/controllerd.service" > "$UNIT_DIR/controllerd.service"
    systemctl --user daemon-reload
    systemctl --user enable --now controllerd.service
    ok "Installed and started controllerd.service (systemctl --user status controllerd)"
else
    say "Skipped -- run the command above yourself whenever you want to fly."
fi

# --- 6. Summary --------------------------------------------------------------
say ""
say "=== Done ==="
say "Installed to: $DEST_LUA and $DEST_DIR"
say "Manual bridge command: $RUN_CMD"
say "In-game: type DRONE to spawn (throttle near zero to arm), CFGD for settings. See README.md for default keybinds."
