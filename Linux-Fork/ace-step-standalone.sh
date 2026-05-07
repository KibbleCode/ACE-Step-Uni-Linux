#!/usr/bin/env bash
# ace-step.sh — Self-contained ACE-Step installer + launcher
#
# Behavior:
#   - First run: detects state, installs missing pieces (uv, Python 3.12,
#                ACE-Step repo, ML deps, Qt GUI), then launches.
#   - Subsequent runs: skips install steps, launches directly.
#
# Stack:
#   - uv-managed Python 3.12 (downloads its own, no system Python pollution)
#   - PySide6 for the GUI (Qt6, much better looking than tkinter)
#   - ROCm 7.2 PyTorch for AMD GPUs
#   - Models from Hugging Face (downloaded on first launch)
#
# Distro support: apt, dnf, pacman, zypper, xbps, apk, eopkg
# Hardware: AMD (ROCm). NVIDIA can be added by editing TORCH_INDEX_URL below.

set -u

# ============================================================================
# CONFIG (edit if you want different defaults)
# ============================================================================
TORCH_INDEX_URL="https://download.pytorch.org/whl/rocm7.2"
GPU_VARIANT="amd"   # "amd" or "nvidia"
ACESTEP_REPO_URL="https://github.com/ace-step/ACE-Step-1.5.git"
PYTHON_VERSION="3.12"
UV_VERSION="0.5.13"

# ============================================================================
# UI HELPERS
# ============================================================================
ZENITY=$(command -v zenity 2>/dev/null || true)
KDIALOG=$(command -v kdialog 2>/dev/null || true)

ui_info() {
    local title="$1"; local msg="$2"
    if [ -n "$ZENITY" ]; then zenity --info --title="$title" --text="$msg" --width=500 2>/dev/null
    elif [ -n "$KDIALOG" ]; then kdialog --msgbox "$msg" --title "$title"
    else echo ""; echo "=== $title ==="; echo "$msg"; fi
}

ui_error() {
    local title="$1"; local msg="$2"
    if [ -n "$ZENITY" ]; then zenity --error --title="$title" --text="$msg" --width=500 2>/dev/null
    elif [ -n "$KDIALOG" ]; then kdialog --error "$msg" --title "$title"
    fi
    echo "" >&2; echo "=== $title ===" >&2; echo "$msg" >&2; echo "" >&2
}

ui_yesno() {
    local title="$1"; local msg="$2"
    if [ -n "$ZENITY" ]; then zenity --question --title="$title" --text="$msg" --width=550 --no-wrap 2>/dev/null
    elif [ -n "$KDIALOG" ]; then kdialog --yesno "$msg" --title "$title"
    else
        echo ""; echo "=== $title ==="; echo "$msg"
        read -rp "[Y/n] " a; case "$a" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
    fi
}

# Ask user to choose an install location. Defaults to ~/.local/share/ace-step.
ui_choose_dir() {
    local default="$1"
    local chosen=""
    if [ -n "$ZENITY" ]; then
        # Use file selection dialog with --directory and --filename for default
        chosen=$(zenity --file-selection --directory \
            --title="Choose install location for ACE-Step" \
            --filename="$default/" 2>/dev/null) || return 1
    elif [ -n "$KDIALOG" ]; then
        chosen=$(kdialog --getexistingdirectory "$default" \
            --title "Choose install location for ACE-Step") || return 1
    else
        echo ""
        echo "Where to install ACE-Step?"
        echo "  Default: $default"
        echo -n "Press Enter for default, or type a path: "
        read -r chosen
        [ -z "$chosen" ] && chosen="$default"
    fi
    # zenity returns the parent dir if user just clicks "OK" — append our subdir
    # if the path doesn't already end in ace-step
    case "$chosen" in
        */ace-step|*/ACE-Step|*/acestep) ;;
        *) chosen="$chosen/ace-step" ;;
    esac
    echo "$chosen"
}

# Progress dialog wrapper. Pass it a description; pipe progress lines.
ui_progress() {
    local title="$1"
    if [ -n "$ZENITY" ]; then
        zenity --progress --title="$title" --pulsate --auto-close \
               --width=450 --no-cancel 2>/dev/null
    else
        cat  # just pass through
    fi
}

log_step() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════════"
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================
# We persist the install location to ~/.config/ace-step/install_dir so we know
# where to launch from on subsequent runs.
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ace-step"
INSTALL_DIR_FILE="$USER_CONFIG_DIR/install_dir"

read_install_dir() {
    if [ -f "$INSTALL_DIR_FILE" ]; then
        cat "$INSTALL_DIR_FILE"
    fi
}

write_install_dir() {
    mkdir -p "$USER_CONFIG_DIR"
    echo "$1" > "$INSTALL_DIR_FILE"
}

# ============================================================================
# DETECTION
# ============================================================================
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper"
    elif command -v xbps-install >/dev/null 2>&1; then echo "xbps"
    elif command -v apk >/dev/null 2>&1; then echo "apk"
    elif command -v eopkg >/dev/null 2>&1; then echo "eopkg"
    else echo "unknown"; fi
}

detect_gpu() {
    # Outputs: amd | nvidia | unknown
    if [ ! -d /sys/class/drm ]; then echo "unknown"; return; fi
    for card in /sys/class/drm/card[0-9]*; do
        [ -f "$card/device/vendor" ] || continue
        v=$(cat "$card/device/vendor" 2>/dev/null)
        case "$v" in
            0x1002) echo "amd"; return ;;
            0x10de) echo "nvidia"; return ;;
        esac
    done
    echo "unknown"
}

detect_gpu_name() {
    if [ -d /sys/class/drm ] && command -v lspci >/dev/null 2>&1; then
        for card in /sys/class/drm/card[0-9]*; do
            [ -f "$card/device/vendor" ] || continue
            v=$(cat "$card/device/vendor" 2>/dev/null | sed 's/^0x//')
            d=$(cat "$card/device/device" 2>/dev/null | sed 's/^0x//')
            [ -n "$v" ] && [ -n "$d" ] || continue
            name=$(lspci -mm -d "$v:$d" 2>/dev/null | head -1 | \
                   awk -F'"' '{print $6 " " $8}' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
            if [ -n "$name" ]; then echo "$name"; return; fi
        done
    fi
    echo ""
}

check_rocm_ready() {
    [ -e /dev/kfd ] || { echo "no /dev/kfd"; return 1; }
    [ -r /dev/kfd ] && [ -w /dev/kfd ] || { echo "/dev/kfd not accessible — add yourself to the 'render' group"; return 1; }
    for r in /dev/dri/renderD*; do
        [ -r "$r" ] && [ -w "$r" ] && return 0
    done
    echo "no /dev/dri/renderD* accessible"
    return 1
}

# ============================================================================
# SYSTEM DEP INSTALL
# ============================================================================
install_system_deps() {
    local pkg_mgr="$1"
    local pkg_list cmd

    case "$pkg_mgr" in
        apt)    pkg_list="curl git tcl tk libxcb1 libxcb-cursor0 libx11-6 libxkbcommon-x11-0 libxext6 libxrender1 libxi6 libxtst6 libgl1 libglib2.0-0 libfontconfig1 libdbus-1-3 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-sync1 libxcb-xfixes0 libxcb-xkb1"
                cmd="apt-get update && apt-get install -y $pkg_list" ;;
        dnf)    pkg_list="curl git tcl tk libxcb libX11 libxkbcommon-x11 libXext libXrender libXi libXtst mesa-libGL fontconfig dbus-libs xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm"
                cmd="dnf install -y $pkg_list" ;;
        pacman) pkg_list="curl git tcl tk libxcb libx11 libxkbcommon-x11 libxext libxrender libxi libxtst libglvnd fontconfig dbus xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm"
                cmd="pacman -S --needed --noconfirm $pkg_list" ;;
        zypper) pkg_list="curl git tcl tk libxcb1 libX11-6 libxkbcommon-x11-0 libXext6 libXrender1 libXi6 libXtst6 libGL1 fontconfig libdbus-1-3"
                cmd="zypper install -y $pkg_list" ;;
        xbps)   pkg_list="curl git tcl tk libxcb libX11 libxkbcommon libXext libXrender libXi libXtst MesaLib fontconfig dbus"
                cmd="xbps-install -Sy $pkg_list" ;;
        apk)    pkg_list="curl git tcl tk libxcb libx11 libxkbcommon libxext libxrender libxi libxtst mesa-gl fontconfig dbus-libs"
                cmd="apk add $pkg_list" ;;
        eopkg)  pkg_list="curl git tcl tk libxcb libx11 libxkbcommon libxext libxrender libxi libxtst libglvnd fontconfig dbus"
                cmd="eopkg install -y $pkg_list" ;;
        *)      ui_error "Unknown distro" "Couldn't detect package manager. Install these manually: tcl tk libxcb libX11 curl git, then re-run."; return 3 ;;
    esac

    if ! ui_yesno "Install system libraries" \
"ACE-Step needs these system libraries to display its window:

  $pkg_list

Will run:  sudo $cmd

This is a one-time install. You'll be asked for your password.

Continue?"; then
        ui_info "Cancelled" "Install cancelled. Run manually:  sudo $cmd"
        return 1
    fi

    if command -v pkexec >/dev/null 2>&1; then
        pkexec bash -c "$cmd"
        return $?
    fi
    for term in gnome-terminal konsole xterm; do
        if command -v "$term" >/dev/null 2>&1; then
            case "$term" in
                gnome-terminal) "$term" -- bash -c "sudo $cmd; echo; echo 'Press Enter...'; read"; return $? ;;
                konsole) "$term" --noclose -e bash -c "sudo $cmd"; return $? ;;
                xterm) "$term" -hold -e bash -c "sudo $cmd"; return $? ;;
            esac
        fi
    done
    sudo bash -c "$cmd"
}

# Quick check: are the libs we need already there?
system_deps_present() {
    ldconfig -p 2>/dev/null | grep -q libxcb || return 1
    ldconfig -p 2>/dev/null | grep -q libxkbcommon || return 1
    command -v curl >/dev/null 2>&1 || return 1
    command -v git >/dev/null 2>&1 || return 1
    return 0
}

# ============================================================================
# UV INSTALL
# ============================================================================
install_uv() {
    local install_dir="$1"
    local uv_dir="$install_dir/uv"
    local uv_bin="$uv_dir/uv"
    if [ -x "$uv_bin" ]; then echo "$uv_bin"; return 0; fi

    mkdir -p "$uv_dir"
    local tarball="$uv_dir/uv.tar.gz"
    curl -L --fail --progress-bar \
        -o "$tarball" \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
        || { ui_error "uv download failed" "Couldn't download uv. Check network."; return 1; }

    tar -xzf "$tarball" -C "$uv_dir" --strip-components=1
    rm -f "$tarball"
    chmod +x "$uv_bin"
    echo "$uv_bin"
}

# ============================================================================
# VENV + DEP INSTALL
# ============================================================================
# ============================================================================
# VENV + DEP INSTALL
# ============================================================================

# Install one package via uv pip. Logs success/failure to a tracking array.
# Usage: pip_install_one "$uv_bin" "$venv" "package_spec" [optional_extra_args...]
# Returns 0 on success, non-zero on failure. Never aborts the parent shell.
pip_install_one() {
    local uv_bin="$1"; local venv="$2"; local pkg="$3"; shift 3
    local extra=("$@")
    echo -n "  → $pkg ... "
    if "$uv_bin" pip install --python "$venv/bin/python" "${extra[@]}" "$pkg" >/dev/null 2>&1; then
        echo "OK"
        return 0
    else
        echo "FAILED"
        FAILED_PKGS+=("$pkg")
        return 1
    fi
}

# Install a list of packages, one at a time. Doesn't abort on individual failures.
pip_install_each() {
    local uv_bin="$1"; local venv="$2"; shift 2
    local pkgs=("$@")
    local pkg
    for pkg in "${pkgs[@]}"; do
        pip_install_one "$uv_bin" "$venv" "$pkg" || true
    done
}

setup_venv() {
    local install_dir="$1"
    local uv_bin="$2"
    local venv="$install_dir/venv"
    local repo="$install_dir/repo"

    # Track which packages failed so we can surface a single summary at the end
    FAILED_PKGS=()
    OPTIONAL_FAILED_PKGS=()

    export UV_CACHE_DIR="$install_dir/cache/uv"
    export UV_PYTHON_INSTALL_DIR="$install_dir/python"
    mkdir -p "$UV_CACHE_DIR" "$UV_PYTHON_INSTALL_DIR"

    log_step "Installing Python $PYTHON_VERSION via uv..."
    "$uv_bin" python install "$PYTHON_VERSION" || return 1

    log_step "Cloning ACE-Step repo..."
    if [ ! -d "$repo/.git" ]; then
        git clone --depth 1 "$ACESTEP_REPO_URL" "$repo" || return 1
    else
        echo "  Repo already cloned, skipping."
    fi

    log_step "Creating virtual environment..."
    if [ -x "$venv/bin/python" ]; then
        echo "  Venv already exists at $venv, reusing."
    else
        "$uv_bin" venv -p "$PYTHON_VERSION" --python-preference managed "$venv" || return 1
    fi

    # Quick check: is torch already installed and importable? Skip torch reinstall if so.
    log_step "Installing PyTorch (this is the largest, ~3 GB)..."
    if "$venv/bin/python" -c "import torch" 2>/dev/null; then
        echo "  ✓ PyTorch already installed ($("$venv/bin/python" -c 'import torch; print(torch.__version__)'))."
    else
        if ! "$uv_bin" pip install --python "$venv/bin/python" \
                --index-url "$TORCH_INDEX_URL" \
                --index-strategy unsafe-best-match \
                torch torchvision torchaudio; then
            echo "  ✗ PyTorch install failed — this is required, aborting."
            return 1
        fi
        echo "  ✓ PyTorch installed."
    fi

    log_step "Installing PySide6 (Qt GUI)..."
    if "$venv/bin/python" -c "import PySide6" 2>/dev/null; then
        echo "  ✓ PySide6 already installed."
    else
        if ! "$uv_bin" pip install --python "$venv/bin/python" "PySide6>=6.6"; then
            echo "  ✗ PySide6 install failed — this is required, aborting."
            return 1
        fi
        echo "  ✓ PySide6 installed."
    fi

    log_step "Installing ACE-Step package (no-deps)..."
    if "$venv/bin/python" -c "import acestep" 2>/dev/null; then
        echo "  ✓ ACE-Step already importable."
    else
        if ! "$uv_bin" pip install --python "$venv/bin/python" --no-deps -e "$repo"; then
            echo "  [!] ACE-Step pip install failed — will fall back to PYTHONPATH"
        else
            echo "  ✓ ACE-Step installed."
        fi
    fi

    # ---- ACE-Step's runtime dependencies ----
    # Installed individually so one failure doesn't take down the rest.
    # Order matters slightly: install foundational deps first.
    log_step "Installing required dependencies (one at a time)..."

    local required_pkgs=(
        "numpy<2"
        "huggingface_hub"
        "psutil"
        "mutagen"
        "Pillow"
        "soundfile>=0.13.1"
        "loguru>=0.7.3"
        "einops>=0.8.1"
        "toml"
        "diskcache"
        "fastapi>=0.110.0"
        "uvicorn[standard]>=0.27.0"
        "scipy>=1.10.1"
        "matplotlib>=3.7.5"
        "transformers>=4.51.0,<4.58.0"
        "diffusers>=0.37.0"
        "accelerate>=1.12.0"
        "gradio==6.2.0"
        "numba>=0.63.1"
        "vector-quantize-pytorch>=1.27.15"
        "peft>=0.18.0"
        "lightning>=2.0.0"
        "tensorboard>=2.20.0"
        "typer-slim>=0.21.1"
        "pytorch-wavelets>=1.3.0"
        "pywavelets>=1.9.0"
        "modelscope"
        "librosa"
    )

    pip_install_each "$uv_bin" "$venv" "${required_pkgs[@]}"

    # ---- Optional / fragile deps (allowed to fail without blocking) ----
    log_step "Installing optional dependencies (failures are OK)..."

    install_optional() {
        local pkg="$1"
        echo -n "  → $pkg ... "
        if "$uv_bin" pip install --python "$venv/bin/python" "$pkg" >/dev/null 2>&1; then
            echo "OK"
        else
            echo "skipped (incompatible with this GPU/Python)"
            OPTIONAL_FAILED_PKGS+=("$pkg")
        fi
    }

    # torchao: precompiled wheels often only target CUDA. ROCm users typically
    # need a source build or specific commit — we skip on failure.
    install_optional "torchao>=0.16.0,<0.17.0"
    # torchcodec: depends on libavcodec headers; can fail without ffmpeg-dev
    install_optional "torchcodec>=0.9.1"
    # lycoris-lora: training-time, often needs latest accelerate
    install_optional "lycoris-lora"

    # ---- nano-vllm from vendored path ----
    log_step "Installing nano-vllm (vendored)..."
    if "$uv_bin" pip install --python "$venv/bin/python" --no-deps \
            "$repo/acestep/third_parts/nano-vllm" >/dev/null 2>&1; then
        echo "  ✓ nano-vllm installed."
    else
        echo "  [!] nano-vllm install failed — LM features may be limited"
        OPTIONAL_FAILED_PKGS+=("nano-vllm")
    fi

    # ---- Summary ----
    log_step "Dependency install summary"
    if [ ${#FAILED_PKGS[@]} -eq 0 ]; then
        echo "  ✓ All required packages installed."
    else
        echo "  ✗ ${#FAILED_PKGS[@]} required package(s) failed:"
        for p in "${FAILED_PKGS[@]}"; do echo "      - $p"; done
    fi
    if [ ${#OPTIONAL_FAILED_PKGS[@]} -gt 0 ]; then
        echo "  ⚠ ${#OPTIONAL_FAILED_PKGS[@]} optional package(s) skipped:"
        for p in "${OPTIONAL_FAILED_PKGS[@]}"; do echo "      - $p"; done
    fi

    # ---- Sanity check: can we actually import the critical modules? ----
    log_step "Verifying installation..."
    local check_script
    check_script=$(cat <<'PYEOF'
import sys
critical = ["torch", "PySide6", "loguru", "fastapi", "transformers", "diffusers"]
missing = []
for m in critical:
    try:
        __import__(m)
    except ImportError as e:
        missing.append(f"{m} ({e})")
if missing:
    print("MISSING_CRITICAL_MODULES:")
    for m in missing:
        print(f"  - {m}")
    sys.exit(1)
print("All critical modules importable.")
PYEOF
)
    if ! "$venv/bin/python" -c "$check_script"; then
        echo ""
        echo "  ✗ Critical modules failed to import. The launcher will not work."
        echo "  Re-run with --reinstall to retry, or install missing modules manually:"
        echo "    $venv/bin/pip install <package>"
        return 1
    fi
    echo "  ✓ Verification passed."

    return 0
}

# ============================================================================
# MODEL DOWNLOAD
# ============================================================================
download_models() {
    local install_dir="$1"
    local models_dir="$install_dir/data/models"
    local marker="$models_dir/.populated"
    local downloader="$install_dir/download_models_qt.py"

    if [ -f "$marker" ]; then
        return 0
    fi

    if ! ui_yesno "Download AI models?" \
"ACE-Step needs ~9 GB of model files from Hugging Face to generate music.

You'll see a progress window with live download stats.

Download now?  (You can also do this later from the launcher.)"; then
        return 0
    fi

    if [ ! -f "$downloader" ]; then
        ui_error "Downloader missing" \
"download_models_qt.py is missing at $downloader.
The install seems incomplete — try --reinstall."
        return 1
    fi

    mkdir -p "$models_dir"

    # Launch the Qt downloader. It opens its own window with a clean progress
    # bar, file list, and live speed/ETA. Exit 0 on success, non-zero on
    # cancel or error.
    "$install_dir/venv/bin/python" "$downloader" \
        --models-dir "$models_dir" \
        --repo "ACE-Step/ACE-Step-v1-3.5B:acestep-v15-turbo" \
        --repo "ACE-Step/ACE-Step-v1-LM-0.6B:acestep-5Hz-lm-0.6B" \
        --repo "ACE-Step/ACE-Step-v1-LM-1.7B:acestep-5Hz-lm-1.7B"

    local rc=$?
    if [ $rc -ne 0 ]; then
        # User cancelled or error — non-fatal, but warn
        echo "  [!] Model download didn't complete (rc=$rc). You can re-run anytime."
        return 0  # Don't block the install over models
    fi
    # The downloader writes the marker itself on success, but touch as backup
    touch "$marker"
}

# ============================================================================
# DESKTOP ENTRY (for app menu integration)
# ============================================================================
write_desktop_entry() {
    local install_dir="$1"
    local script_path="$2"
    local apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$apps_dir"

    cat > "$apps_dir/ace-step.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ACE-Step 1.5
GenericName=AI Music Generator
Comment=Generate music with AI
Exec=$script_path
Terminal=false
Categories=AudioVideo;Audio;Music;
Keywords=AI;music;generation;audio;
StartupNotify=true
StartupWMClass=ACE-Step
EOF
    update-desktop-database "$apps_dir" 2>/dev/null || true
}

# ============================================================================
# MAIN INSTALL FLOW
# ============================================================================
do_install() {
    log_step "ACE-Step Installer"
    echo "Distro: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    echo "GPU: $(detect_gpu_name) ($(detect_gpu))"

    # Step 1: GPU sanity
    local gpu
    gpu=$(detect_gpu)
    if [ "$gpu" != "$GPU_VARIANT" ] && [ "$gpu" != "unknown" ]; then
        if ! ui_yesno "GPU mismatch" \
"This script is configured for $GPU_VARIANT GPUs but detected: $gpu

Continue anyway? (You'll get CPU-only inference unless you edit TORCH_INDEX_URL in the script.)"; then
            exit 1
        fi
    fi

    # AMD ROCm readiness
    if [ "$gpu" = "amd" ] && [ "$GPU_VARIANT" = "amd" ]; then
        local rocm_msg
        if ! rocm_msg=$(check_rocm_ready); then
            ui_error "ROCm not ready" \
"$rocm_msg

Common fix:
  sudo usermod -aG render,video \$USER
Then log out and back in (or reboot)."
            exit 1
        fi
    fi

    # Step 2: System deps
    if ! system_deps_present; then
        local pkg_mgr
        pkg_mgr=$(detect_pkg_mgr)
        log_step "Installing system libraries via $pkg_mgr..."
        if ! install_system_deps "$pkg_mgr"; then
            exit 1
        fi
    else
        log_step "System libraries already installed."
    fi

    # Step 3: Choose install dir
    local default_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ace-step"
    local install_dir
    install_dir=$(ui_choose_dir "$default_dir") || {
        ui_info "Cancelled" "No install location chosen, exiting."
        exit 1
    }

    if [ -z "$install_dir" ]; then install_dir="$default_dir"; fi
    mkdir -p "$install_dir"
    write_install_dir "$install_dir"
    log_step "Installing to: $install_dir"

    # Step 4: uv
    log_step "Installing uv..."
    local uv_bin
    uv_bin=$(install_uv "$install_dir") || exit 1
    echo "uv: $($uv_bin --version)"

    # Step 5: Venv + deps
    if ! setup_venv "$install_dir" "$uv_bin"; then
        ui_error "Setup failed" "Dependency installation failed. Check terminal output."
        exit 1
    fi

    # Step 6: Place launcher.py + downloader inside install dir
    log_step "Installing launcher GUI..."
    cp "$LAUNCHER_PY_PATH" "$install_dir/launcher.py"
    if [ -n "${DOWNLOADER_PY_PATH:-}" ] && [ -f "$DOWNLOADER_PY_PATH" ]; then
        cp "$DOWNLOADER_PY_PATH" "$install_dir/download_models_qt.py"
    fi

    # Step 7: Models
    download_models "$install_dir"

    # Step 8: Desktop entry
    write_desktop_entry "$install_dir" "$(readlink -f "$0")"

    # Step 9: Mark installed
    touch "$install_dir/.installed"

    log_step "Install complete!"
    echo "Launching..."
}

# ============================================================================
# LAUNCH FLOW
# ============================================================================
do_launch() {
    local install_dir="$1"
    local venv="$install_dir/venv"
    local launcher="$install_dir/launcher.py"

    if [ ! -x "$venv/bin/python" ]; then
        ui_error "Broken install" \
"The venv at $venv is missing or broken.
Re-run this script with --reinstall to fix it."
        exit 1
    fi

    if [ ! -f "$launcher" ]; then
        # User may have moved or deleted it; copy our embedded one
        if [ -n "${LAUNCHER_PY_PATH:-}" ] && [ -f "$LAUNCHER_PY_PATH" ]; then
            cp "$LAUNCHER_PY_PATH" "$launcher"
        else
            ui_error "Launcher missing" "Can't find launcher.py at $launcher"
            exit 1
        fi
    fi

    # GPU info for the launcher window
    export GPU_VENDOR=$(detect_gpu)
    export GPU_NAME=$(detect_gpu_name)
    export ACESTEP_INSTALL_DIR="$install_dir"
    export ACESTEP_DATA_DIR="$install_dir/data"
    export ACESTEP_CONFIG_DIR="$install_dir/config"
    export ACESTEP_CACHE_DIR="$install_dir/cache"

    # ROCm hint for the 7800 XT (gfx1101). Only set if user hasn't.
    if [ "$GPU_VARIANT" = "amd" ] && [ -z "${HSA_OVERRIDE_GFX_VERSION:-}" ]; then
        # Don't force it — let pytorch detect natively. Uncomment if needed.
        : # export HSA_OVERRIDE_GFX_VERSION="11.0.1"
        :
    fi

    cd "$install_dir"
    exec "$venv/bin/python" "$launcher" "$@"
}

# ============================================================================
# UNINSTALL
# ============================================================================
do_uninstall() {
    local install_dir
    install_dir=$(read_install_dir)
    if [ -z "$install_dir" ] || [ ! -d "$install_dir" ]; then
        ui_info "Nothing to uninstall" "No ACE-Step install detected."
        exit 0
    fi
    if ! ui_yesno "Confirm uninstall" \
"This will delete:
  $install_dir
  ${XDG_DATA_HOME:-$HOME/.local/share}/applications/ace-step.desktop
  $USER_CONFIG_DIR

Models (~9 GB) and your generations will be lost.
Continue?"; then
        exit 0
    fi
    rm -rf "$install_dir"
    rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/ace-step.desktop"
    rm -rf "$USER_CONFIG_DIR"
    ui_info "Uninstalled" "ACE-Step removed cleanly."
}

# ============================================================================
# EMBEDDED PYTHON SOURCE EXTRACTION
# ============================================================================
# launcher.py and download_models_qt.py are both embedded at the bottom of
# this script, each behind its own marker. On first run we extract both to
# /tmp so the script remains truly self-contained.
LAUNCHER_PY_PATH=""
DOWNLOADER_PY_PATH=""

# Extract a section between two markers from this script.
# $1 = begin marker, $2 = end marker (or empty for "to EOF")
# $3 = output path
extract_section() {
    local begin="$1" end="$2" target="$3"
    if [ -n "$end" ]; then
        awk -v B="$begin" -v E="$end" '
            $0 == B { found=1; next }
            $0 == E { found=0; next }
            found
        ' "$0" | sed 's/^# \?//' > "$target"
    else
        awk -v B="$begin" '
            $0 == B { found=1; next }
            found
        ' "$0" | sed 's/^# \?//' > "$target"
    fi
    [ -s "$target" ]
}

# ============================================================================
# ENTRY POINT
# ============================================================================
case "${1:-}" in
    --uninstall)
        do_uninstall
        exit 0
        ;;
    --reinstall)
        install_dir=$(read_install_dir)
        if [ -n "$install_dir" ] && [ -d "$install_dir" ]; then
            rm -rf "$install_dir/venv" "$install_dir/uv" "$install_dir/python"
        fi
        rm -f "$INSTALL_DIR_FILE"
        ;;
    --repair)
        # Re-run dep install on existing venv without nuking everything.
        # Use this when imports fail (missing deps) but venv + Python are fine.
        REPAIR_MODE=1
        ;;
    --help|-h)
        cat <<EOF
ACE-Step launcher

Usage:
  $(basename "$0")                Install (first run) or launch (subsequent runs)
  $(basename "$0") --repair       Re-install dependencies into existing venv
                                  (use this if you get ModuleNotFoundError)
  $(basename "$0") --reinstall    Wipe venv/uv/Python and reinstall from scratch
  $(basename "$0") --uninstall    Remove ACE-Step entirely
  $(basename "$0") --help         Show this help

EOF
        exit 0
        ;;
esac

# Set up temp files for embedded Python sources
TMP_LAUNCHER=$(mktemp /tmp/ace-step-launcher-XXXXXX.py)
TMP_DOWNLOADER=$(mktemp /tmp/ace-step-downloader-XXXXXX.py)
trap "rm -f $TMP_LAUNCHER $TMP_DOWNLOADER" EXIT

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Try embedded first, fall back to companion files next to the script
if extract_section "# === EMBEDDED_LAUNCHER_PY_BEGIN ===" \
                   "# === EMBEDDED_LAUNCHER_PY_END ===" \
                   "$TMP_LAUNCHER"; then
    LAUNCHER_PY_PATH="$TMP_LAUNCHER"
elif [ -f "$SCRIPT_DIR/launcher.py" ]; then
    LAUNCHER_PY_PATH="$SCRIPT_DIR/launcher.py"
else
    ui_error "Missing launcher.py" \
"Couldn't find launcher.py.

Either embed it in this script between markers:
  # === EMBEDDED_LAUNCHER_PY_BEGIN ===
  ...
  # === EMBEDDED_LAUNCHER_PY_END ===

Or place launcher.py next to this script."
    exit 1
fi

if extract_section "# === EMBEDDED_DOWNLOADER_PY_BEGIN ===" \
                   "# === EMBEDDED_DOWNLOADER_PY_END ===" \
                   "$TMP_DOWNLOADER"; then
    DOWNLOADER_PY_PATH="$TMP_DOWNLOADER"
elif [ -f "$SCRIPT_DIR/download_models_qt.py" ]; then
    DOWNLOADER_PY_PATH="$SCRIPT_DIR/download_models_qt.py"
else
    # Non-fatal — install will warn and skip the model download step
    DOWNLOADER_PY_PATH=""
    echo "[!] download_models_qt.py not found — model download UI unavailable"
fi

# State machine: install, repair, or launch?
existing_dir=$(read_install_dir)

if [ "${REPAIR_MODE:-0}" = "1" ]; then
    # User asked to repair an existing install: re-run dep install only.
    if [ -z "$existing_dir" ] || [ ! -d "$existing_dir/venv" ]; then
        ui_error "Nothing to repair" \
"No existing install found. Run without --repair to install fresh."
        exit 1
    fi
    log_step "Repair mode — reinstalling dependencies into existing venv"
    echo "Install dir: $existing_dir"

    # Locate uv (it's bundled inside the install dir from the original install)
    uv_bin="$existing_dir/uv/uv"
    if [ ! -x "$uv_bin" ]; then
        log_step "uv missing in install dir, re-downloading..."
        uv_bin=$(install_uv "$existing_dir") || exit 1
    fi

    # Re-run setup_venv, which will skip work that's already done (Python
    # already installed, repo already cloned, venv already exists) and
    # install/reinstall the dep list.
    if ! setup_venv "$existing_dir" "$uv_bin"; then
        ui_error "Repair failed" \
"Some required dependencies couldn't be installed.
Check the terminal output above for details."
        exit 1
    fi

    # Refresh launcher.py + downloader (in case we updated them)
    cp "$LAUNCHER_PY_PATH" "$existing_dir/launcher.py"
    [ -n "${DOWNLOADER_PY_PATH:-}" ] && [ -f "$DOWNLOADER_PY_PATH" ] && \
        cp "$DOWNLOADER_PY_PATH" "$existing_dir/download_models_qt.py"

    log_step "Repair complete — launching"
    do_launch "$existing_dir"
elif [ -n "$existing_dir" ] && [ -f "$existing_dir/.installed" ]; then
    do_launch "$existing_dir" "$@"
else
    do_install
    install_dir=$(read_install_dir)
    do_launch "$install_dir" "$@"
fi

# === EMBEDDED_LAUNCHER_PY_BEGIN ===
# """
# ACE-Step Launcher — PySide6 edition (V7)
# 
# A Qt-based replacement for the tkinter launcher. Same functionality, but uses
# Qt6 which has proper threading and doesn't fight libxcb on modern distros.
# 
# Features:
#   - Launch WebUI button (starts API + opens HTML files in browser)
#   - API server toggle with live status indicator
#   - Gradio UI launch
#   - Folder shortcuts (WebUI dir, generations dir)
#   - Settings panel (skip LLM, terminal output)
#   - Local HTTP config server (with CSRF token defense)
#   - Cross-thread-safe via Qt signals/slots
# """
# 
# import sys
# import os
# import subprocess
# import threading
# import time
# import json
# import http.server
# import socketserver
# import socket
# import secrets
# import webbrowser
# import urllib.request
# import shutil
# import struct
# import platform
# import signal
# from pathlib import Path
# 
# import psutil
# 
# from PySide6.QtCore import (
#     Qt, QTimer, QThread, Signal, QObject, QSize, QPropertyAnimation, QEasingCurve, QPoint
# )
# from PySide6.QtGui import (
#     QIcon, QPixmap, QPainter, QColor, QPalette, QFont, QFontDatabase,
#     QLinearGradient, QBrush, QCursor, QAction
# )
# from PySide6.QtWidgets import (
#     QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
#     QPushButton, QLabel, QCheckBox, QFrame, QStatusBar, QSizePolicy,
#     QGraphicsDropShadowEffect, QStyle, QStyleOption, QToolTip, QMessageBox
# )
# 
# IS_LINUX = platform.system() == "Linux"
# IS_MAC = platform.system() == "Darwin"
# IS_WINDOWS = platform.system() == "Windows"
# 
# 
# # ============================================================================
# # PATHS
# # ============================================================================
# def _resolve_dirs():
#     """Locate install dir + XDG dirs. Install dir is passed via env from ace-step.sh."""
#     home = Path.home()
#     install_dir = Path(os.environ.get("ACESTEP_INSTALL_DIR", home / ".local/share/ace-step"))
#     data_dir = Path(os.environ.get("ACESTEP_DATA_DIR", install_dir / "data"))
#     config_dir = Path(os.environ.get("ACESTEP_CONFIG_DIR", install_dir / "config"))
#     cache_dir = Path(os.environ.get("ACESTEP_CACHE_DIR", install_dir / "cache"))
#     for d in (data_dir, config_dir, cache_dir):
#         d.mkdir(parents=True, exist_ok=True)
#     return install_dir, data_dir, config_dir, cache_dir
# 
# 
# INSTALL_DIR, DATA_DIR, CONFIG_DIR, CACHE_DIR = _resolve_dirs()
# REPO_DIR = INSTALL_DIR / "repo"
# VENV_DIR = INSTALL_DIR / "venv"
# WEBUI_DIR = INSTALL_DIR / "webui"
# GENERATIONS_DIR = DATA_DIR / "generations"
# SETTINGS_FILE = CONFIG_DIR / "launcher_settings.json"
# UI_CONFIG_FILE = CONFIG_DIR / "ui_config.json"
# 
# API_PORT = 8001
# GRADIO_PORT = 7860
# CONFIG_PORT = 8765
# 
# LAUNCHER_TOKEN = secrets.token_urlsafe(32)
# 
# 
# # ============================================================================
# # THEME — modern dark with blue accent
# # ============================================================================
# THEME = {
#     "bg":            "#0e1117",
#     "bg_elevated":   "#161b22",
#     "bg_hover":      "#1f262f",
#     "border":        "#30363d",
#     "fg":            "#e6edf3",
#     "fg_dim":        "#7d8590",
#     "accent":        "#2f81f7",
#     "accent_hover":  "#3a94ff",
#     "accent_press":  "#1f6feb",
#     "success":       "#3fb950",
#     "danger":        "#f85149",
#     "warning":       "#d29922",
# }
# 
# QSS = f"""
# QMainWindow, QWidget#central {{
#     background-color: {THEME['bg']};
#     color: {THEME['fg']};
# }}
# 
# QLabel {{
#     color: {THEME['fg']};
#     background: transparent;
# }}
# 
# QLabel#title {{
#     color: {THEME['accent']};
#     font-size: 22px;
#     font-weight: 600;
# }}
# 
# QLabel#subtitle {{
#     color: {THEME['fg_dim']};
#     font-size: 11px;
# }}
# 
# QLabel#status {{
#     color: {THEME['fg_dim']};
#     font-size: 10px;
#     padding: 6px 12px;
# }}
# 
# QFrame#card {{
#     background-color: {THEME['bg_elevated']};
#     border: 1px solid {THEME['border']};
#     border-radius: 8px;
# }}
# 
# QPushButton {{
#     background-color: {THEME['bg_elevated']};
#     color: {THEME['fg']};
#     border: 1px solid {THEME['border']};
#     border-radius: 6px;
#     padding: 8px 14px;
#     font-size: 11px;
#     font-weight: 500;
# }}
# 
# QPushButton:hover {{
#     background-color: {THEME['bg_hover']};
#     border-color: {THEME['accent']};
# }}
# 
# QPushButton:pressed {{
#     background-color: {THEME['accent_press']};
# }}
# 
# QPushButton#primary {{
#     background-color: {THEME['accent']};
#     color: white;
#     border: none;
#     padding: 14px;
#     font-size: 13px;
#     font-weight: 600;
# }}
# 
# QPushButton#primary:hover {{
#     background-color: {THEME['accent_hover']};
# }}
# 
# QPushButton#primary:pressed {{
#     background-color: {THEME['accent_press']};
# }}
# 
# QCheckBox {{
#     color: {THEME['fg_dim']};
#     spacing: 8px;
#     font-size: 11px;
# }}
# 
# QCheckBox::indicator {{
#     width: 16px;
#     height: 16px;
#     border: 1px solid {THEME['border']};
#     border-radius: 3px;
#     background-color: {THEME['bg']};
# }}
# 
# QCheckBox::indicator:hover {{
#     border-color: {THEME['accent']};
# }}
# 
# QCheckBox::indicator:checked {{
#     background-color: {THEME['accent']};
#     border-color: {THEME['accent']};
#     image: none;
# }}
# 
# QStatusBar {{
#     background-color: {THEME['bg_elevated']};
#     color: {THEME['fg_dim']};
#     border-top: 1px solid {THEME['border']};
# }}
# 
# QToolTip {{
#     background-color: {THEME['bg_elevated']};
#     color: {THEME['fg']};
#     border: 1px solid {THEME['border']};
#     padding: 6px 10px;
#     border-radius: 4px;
# }}
# """
# 
# 
# # ============================================================================
# # STATE & SETTINGS
# # ============================================================================
# api_process = None
# api_actual_port = API_PORT
# 
# 
# def open_path(path):
#     path = str(path)
#     if IS_WINDOWS:
#         os.startfile(path)
#     elif IS_MAC:
#         subprocess.Popen(["open", path])
#     else:
#         subprocess.Popen(["xdg-open", path],
#                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
# 
# 
# _DEFAULT_SETTINGS = {"skip_llm": False, "show_terminal": False}
# 
# 
# def load_settings():
#     try:
#         if SETTINGS_FILE.exists():
#             with open(SETTINGS_FILE) as f:
#                 saved = json.load(f)
#             merged = dict(_DEFAULT_SETTINGS)
#             merged.update(saved)
#             return merged
#     except Exception as e:
#         print(f"Warning: failed to load settings: {e}", file=sys.stderr)
#     return dict(_DEFAULT_SETTINGS)
# 
# 
# def save_settings(settings):
#     try:
#         with open(SETTINGS_FILE, "w") as f:
#             json.dump(settings, f, indent=2)
#     except Exception as e:
#         print(f"Warning: failed to save settings: {e}", file=sys.stderr)
# 
# 
# # ============================================================================
# # PORT UTILITIES
# # ============================================================================
# def port_in_use(port):
#     with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
#         s.settimeout(0.2)
#         try:
#             return s.connect_ex(("127.0.0.1", port)) == 0
#         except (socket.timeout, OSError):
#             return False
# 
# 
# def find_free_port(preferred):
#     if not port_in_use(preferred):
#         return preferred
#     for p in range(preferred + 1, preferred + 20):
#         if not port_in_use(p):
#             return p
#     return preferred
# 
# 
# def is_api_running():
#     global api_actual_port
#     if api_actual_port > 0 and port_in_use(api_actual_port):
#         return True
#     if api_actual_port != API_PORT and port_in_use(API_PORT):
#         api_actual_port = API_PORT
#         return True
#     if api_process is not None and api_process.poll() is None:
#         return True
#     return False
# 
# 
# # ============================================================================
# # CONFIG / LIBRARY HTTP SERVER (with CSRF defense)
# # ============================================================================
# _AUDIO_EXTS = {".wav", ".flac", ".mp3", ".ogg", ".opus", ".m4a", ".aac"}
# _MIME_MAP = {
#     ".wav": "audio/wav", ".flac": "audio/flac", ".mp3": "audio/mpeg",
#     ".ogg": "audio/ogg", ".opus": "audio/opus", ".m4a": "audio/mp4", ".aac": "audio/aac",
# }
# _MUTATING_ENDPOINTS = {
#     "/ui_config", "/save_generation", "/library/mkdir", "/library/rename",
#     "/library/move", "/library/delete", "/open_music_folder",
# }
# 
# 
# def _safe_library_path(relative):
#     GENERATIONS_DIR.mkdir(parents=True, exist_ok=True)
#     base = GENERATIONS_DIR.resolve()
#     try:
#         target = (GENERATIONS_DIR / relative).resolve()
#         target.relative_to(base)
#     except (ValueError, OSError):
#         return None
#     return target
# 
# 
# def load_ui_config():
#     try:
#         if UI_CONFIG_FILE.exists():
#             with open(UI_CONFIG_FILE) as f:
#                 return json.load(f)
#     except Exception:
#         pass
#     return {}
# 
# 
# def save_ui_config(data):
#     try:
#         with open(UI_CONFIG_FILE, "w") as f:
#             json.dump(data, f, indent=2)
#     except Exception as e:
#         print(f"Config save failed: {e}", file=sys.stderr)
# 
# 
# class _ConfigHandler(http.server.BaseHTTPRequestHandler):
#     def log_message(self, *args):
#         pass
# 
#     def _cors(self):
#         self.send_header("Access-Control-Allow-Origin", "*")
#         self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
#         self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Launcher-Token")
# 
#     def _check_token(self):
#         provided = self.headers.get("X-Launcher-Token", "")
#         return secrets.compare_digest(provided, LAUNCHER_TOKEN)
# 
#     def _reject(self, code=403, msg=b"forbidden"):
#         self.send_response(code); self._cors(); self.end_headers(); self.wfile.write(msg)
# 
#     def do_OPTIONS(self):
#         self.send_response(204); self._cors(); self.end_headers()
# 
#     def do_GET(self):
#         if self.path == "/ui_config":
#             body = json.dumps(load_ui_config()).encode()
#             self.send_response(200); self._cors()
#             self.send_header("Content-Type", "application/json")
#             self.send_header("Content-Length", str(len(body)))
#             self.end_headers(); self.wfile.write(body)
#         elif self.path == "/launcher_token":
#             origin = self.headers.get("Origin", "")
#             if origin and origin not in ("null", f"http://127.0.0.1:{CONFIG_PORT}", f"http://localhost:{CONFIG_PORT}"):
#                 self._reject(403, b"cross-origin denied"); return
#             body = LAUNCHER_TOKEN.encode()
#             self.send_response(200); self._cors()
#             self.send_header("Content-Type", "text/plain")
#             self.send_header("Content-Length", str(len(body)))
#             self.end_headers(); self.wfile.write(body)
#         elif self.path == "/generations_path":
#             body = str(GENERATIONS_DIR).encode()
#             self.send_response(200); self._cors()
#             self.send_header("Content-Type", "text/plain")
#             self.send_header("Content-Length", str(len(body)))
#             self.end_headers(); self.wfile.write(body)
#         else:
#             self._reject(404, b"not found")
# 
#     def do_POST(self):
#         if self.path in _MUTATING_ENDPOINTS and not self._check_token():
#             self._reject(403, b"invalid X-Launcher-Token"); return
#         length = int(self.headers.get("Content-Length", 0))
#         body = self.rfile.read(length) if length else b""
# 
#         if self.path == "/heartbeat":
#             self.send_response(200); self._cors(); self.end_headers(); self.wfile.write(b"ok")
#         elif self.path == "/open_music_folder":
#             GENERATIONS_DIR.mkdir(parents=True, exist_ok=True)
#             open_path(str(GENERATIONS_DIR))
#             self.send_response(200); self._cors(); self.end_headers()
#         elif self.path == "/ui_config":
#             try:
#                 save_ui_config(json.loads(body))
#                 self.send_response(200); self._cors(); self.end_headers(); self.wfile.write(b"ok")
#             except Exception as e:
#                 self._reject(500, str(e).encode())
#         else:
#             self._reject(404, b"not found")
# 
# 
# def start_config_server():
#     class _ThreadedHTTP(socketserver.ThreadingMixIn, http.server.HTTPServer):
#         daemon_threads = True
#         allow_reuse_address = True
# 
#     def _run():
#         try:
#             srv = _ThreadedHTTP(("127.0.0.1", CONFIG_PORT), _ConfigHandler)
#             srv.serve_forever()
#         except OSError as e:
#             print(f"Config server failed: {e}", file=sys.stderr)
# 
#     threading.Thread(target=_run, daemon=True).start()
# 
# 
# # ============================================================================
# # API MANAGEMENT
# # ============================================================================
# def _venv_bin(name):
#     return str(VENV_DIR / "bin" / name)
# 
# 
# def start_api(skip_llm=False, show_terminal=False):
#     global api_process, api_actual_port
# 
#     if api_process and api_process.poll() is None:
#         return True
#     if port_in_use(api_actual_port):
#         return True
# 
#     api_actual_port = find_free_port(API_PORT)
#     env = os.environ.copy()
#     if skip_llm:
#         env["ACESTEP_INIT_LLM"] = "false"
# 
#     # Try the console-script first (acestep-api), fall back to python -m
#     acestep_api_bin = _venv_bin("acestep-api")
#     python_bin = _venv_bin("python")
# 
#     if Path(acestep_api_bin).exists():
#         cmd = [acestep_api_bin, "--port", str(api_actual_port)]
#     else:
#         cmd = [python_bin, "-m", "acestep.api", "--port", str(api_actual_port)]
# 
#     kwargs = {"cwd": str(REPO_DIR), "env": env, "start_new_session": True,
#               "stdin": subprocess.DEVNULL}
# 
#     try:
#         if show_terminal and IS_LINUX:
#             term = _find_terminal()
#             if term:
#                 shell_cmd = (f'cd "{REPO_DIR}" && '
#                              f'{" ".join(repr(c) for c in cmd)}; '
#                              f'echo; echo "API exited. Press Enter to close."; read')
#                 if term == "gnome-terminal":
#                     api_process = subprocess.Popen([term, "--", "bash", "-c", shell_cmd], **kwargs)
#                 elif term == "konsole":
#                     api_process = subprocess.Popen([term, "--noclose", "-e", "bash", "-c", shell_cmd], **kwargs)
#                 else:
#                     api_process = subprocess.Popen([term, "-e", "bash", "-c", shell_cmd], **kwargs)
#                 return True
# 
#         # Headless
#         log_path = CACHE_DIR / "api.log"
#         log_file = open(log_path, "a", buffering=1)
#         kwargs["stdout"] = log_file
#         kwargs["stderr"] = subprocess.STDOUT
#         api_process = subprocess.Popen(cmd, **kwargs)
#         return True
# 
#     except Exception as exc:
#         print(f"Failed to start API: {exc}", file=sys.stderr)
#         return False
# 
# 
# def _find_terminal():
#     for t in ["x-terminal-emulator", "gnome-terminal", "konsole",
#               "xfce4-terminal", "mate-terminal", "lxterminal",
#               "alacritty", "kitty", "wezterm", "foot", "xterm"]:
#         if shutil.which(t):
#             return t
#     return None
# 
# 
# def stop_api():
#     global api_process, api_actual_port
#     if api_process:
#         try:
#             if not IS_WINDOWS and api_process.poll() is None:
#                 try:
#                     os.killpg(os.getpgid(api_process.pid), signal.SIGTERM)
#                     api_process.wait(timeout=5)
#                 except (ProcessLookupError, PermissionError, subprocess.TimeoutExpired):
#                     try:
#                         os.killpg(os.getpgid(api_process.pid), signal.SIGKILL)
#                     except Exception:
#                         pass
#             else:
#                 api_process.terminate()
#                 api_process.wait(timeout=5)
#         except Exception:
#             try: api_process.kill()
#             except Exception: pass
#         api_process = None
#     kill_orphaned_acestep_procs(silent=True)
#     api_actual_port = API_PORT
# 
# 
# def kill_orphaned_acestep_procs(silent=False):
#     killed = []
#     try:
#         for proc in psutil.process_iter(["pid", "name", "cmdline"]):
#             try:
#                 if not proc.info["name"] or "python" not in proc.info["name"].lower():
#                     continue
#                 cmdline_list = proc.info["cmdline"] or []
#                 is_acestep = any(
#                     arg == "acestep.api" or arg == "acestep-api" or
#                     arg.endswith("/acestep-api") or arg.endswith("acestep/api.py")
#                     for arg in cmdline_list
#                 )
#                 if not is_acestep or proc.pid == os.getpid():
#                     continue
#                 if api_process is not None and proc.pid == api_process.pid:
#                     continue
#                 proc.kill()
#                 killed.append(proc.pid)
#             except (psutil.NoSuchProcess, psutil.AccessDenied):
#                 pass
#     except Exception:
#         pass
#     return killed
# 
# 
# # ============================================================================
# # HTML PREP
# # ============================================================================
# def list_webuis():
#     if not WEBUI_DIR.exists():
#         return []
#     return [p for p in sorted(WEBUI_DIR.glob("*.html")) if not p.name.startswith("_active_")]
# 
# 
# def _rewrite_html(content, port):
#     if port != API_PORT:
#         for old in [f"127.0.0.1:{API_PORT}", f"localhost:{API_PORT}"]:
#             content = content.replace(old, f"127.0.0.1:{port}")
#     if "__LAUNCHER_TOKEN__" in content:
#         content = content.replace("__LAUNCHER_TOKEN__", LAUNCHER_TOKEN)
#     else:
#         meta = f'<meta name="launcher-token" content="{LAUNCHER_TOKEN}">'
#         if "<head>" in content.lower():
#             idx = content.lower().find("<head>") + len("<head>")
#             content = content[:idx] + "\n" + meta + content[idx:]
#         else:
#             content = meta + "\n" + content
#     return content
# 
# 
# def _prepare_html(html_path, port):
#     content = html_path.read_text(encoding="utf-8", errors="replace")
#     content = _rewrite_html(content, port)
#     active = CACHE_DIR / f"_active_{html_path.stem}.html"
#     active.write_text(content, encoding="utf-8")
#     return active
# 
# 
# # ============================================================================
# # QT WORKER (background API operations)
# # ============================================================================
# class APIWorker(QObject):
#     """Runs API start + wait_for_api on a worker thread; emits signals.
# 
#     Critical: NEVER touch GUI widgets here. Only emit signals; the main
#     thread connects to them and updates UI.
#     """
#     status_update = Signal(str)
#     api_started = Signal(bool)
#     webui_ready = Signal(list)
# 
#     def __init__(self):
#         super().__init__()
#         self._cancel = False
# 
#     def start_api_only(self, settings):
#         if not start_api(settings.get("skip_llm", False),
#                          settings.get("show_terminal", False)):
#             self.status_update.emit("Failed to start API")
#             self.api_started.emit(False)
#             return
#         self._wait_for_api()
# 
#     def launch_webui(self, settings):
#         htmls = list_webuis()
#         if not htmls:
#             self.status_update.emit(f"No HTML files in {WEBUI_DIR}")
#             return
#         self.status_update.emit("Starting API server...")
#         if not start_api(settings.get("skip_llm", False),
#                          settings.get("show_terminal", False)):
#             self.status_update.emit("Failed to start API")
#             return
#         if self._wait_for_api():
#             prepared = []
#             for h in htmls:
#                 try:
#                     p = _prepare_html(h, api_actual_port)
#                     prepared.append(p)
#                 except Exception as e:
#                     print(f"Failed to prepare {h}: {e}", file=sys.stderr)
#             self.webui_ready.emit(prepared)
#             self.status_update.emit(f"{len(prepared)} UI(s) open  |  API :{api_actual_port}")
# 
#     def _wait_for_api(self, timeout=180):
#         deadline = time.time() + timeout
#         start = time.time()
#         while time.time() < deadline:
#             if port_in_use(api_actual_port):
#                 self.api_started.emit(True)
#                 return True
#             elapsed = int(time.time() - start)
#             self.status_update.emit(f"Loading models... {elapsed}s ({timeout - elapsed}s left)")
#             time.sleep(1)
#         self.status_update.emit("API timed out")
#         self.api_started.emit(False)
#         return False
# 
# 
# # ============================================================================
# # CUSTOM WIDGETS
# # ============================================================================
# class StatusDot(QWidget):
#     """Small colored circle indicating API state."""
#     def __init__(self, size=10, parent=None):
#         super().__init__(parent)
#         self._size = size
#         self._color = QColor(THEME["danger"])
#         self.setFixedSize(size + 2, size + 2)
# 
#     def set_running(self, running):
#         self._color = QColor(THEME["success"] if running else THEME["danger"])
#         self.update()
# 
#     def paintEvent(self, event):
#         p = QPainter(self)
#         p.setRenderHint(QPainter.Antialiasing)
#         p.setPen(Qt.NoPen)
#         p.setBrush(QBrush(self._color))
#         p.drawEllipse(1, 1, self._size, self._size)
# 
# 
# class IconButton(QPushButton):
#     """A QPushButton that lets us add a leading dot widget."""
#     pass
# 
# 
# # ============================================================================
# # MAIN WINDOW
# # ============================================================================
# class LauncherWindow(QMainWindow):
#     request_launch_webui = Signal(dict)
#     request_toggle_api = Signal(dict)
# 
#     def __init__(self):
#         super().__init__()
#         self.settings = load_settings()
#         self._build_ui()
#         self._setup_workers()
#         self._setup_polling()
#         self._setup_lifecycle()
# 
#     def _build_ui(self):
#         self.setWindowTitle("ACE-Step 1.5")
#         self.setFixedSize(460, 480)
#         self.setStyleSheet(QSS)
# 
#         # Central widget with vertical layout
#         central = QWidget()
#         central.setObjectName("central")
#         self.setCentralWidget(central)
#         layout = QVBoxLayout(central)
#         layout.setContentsMargins(28, 22, 28, 14)
#         layout.setSpacing(10)
# 
#         # Title (clickable -> opens website)
#         title = QLabel("ACE-Step  1.5")
#         title.setObjectName("title")
#         title.setCursor(QCursor(Qt.PointingHandCursor))
#         title.mousePressEvent = lambda _: webbrowser.open("https://ace-step.github.io")
#         layout.addWidget(title)
# 
#         # Subtitle with GPU info
#         gpu_name = os.environ.get("GPU_NAME", "")
#         subtitle_text = f"AI Music Generation  •  {gpu_name}" if gpu_name else "AI Music Generation"
#         subtitle = QLabel(subtitle_text)
#         subtitle.setObjectName("subtitle")
#         layout.addWidget(subtitle)
# 
#         layout.addSpacing(8)
# 
#         # Big launch button
#         self.launch_btn = QPushButton("▶  Launch WebUI")
#         self.launch_btn.setObjectName("primary")
#         self.launch_btn.setMinimumHeight(50)
#         self.launch_btn.setCursor(QCursor(Qt.PointingHandCursor))
#         self.launch_btn.setToolTip("Starts API + opens every HTML in webui/")
#         self.launch_btn.clicked.connect(self._on_launch_clicked)
#         layout.addWidget(self.launch_btn)
# 
#         # API + Gradio row
#         row = QHBoxLayout()
#         row.setSpacing(10)
# 
#         api_box = QHBoxLayout()
#         api_box.setSpacing(8)
#         api_box.setContentsMargins(0, 0, 0, 0)
#         self.api_dot = StatusDot(size=10)
#         api_box.addWidget(self.api_dot)
#         self.api_btn = QPushButton("API Server")
#         self.api_btn.setMinimumHeight(36)
#         self.api_btn.setCursor(QCursor(Qt.PointingHandCursor))
#         self.api_btn.setToolTip("Toggle the API server on/off")
#         self.api_btn.clicked.connect(self._on_toggle_api_clicked)
#         api_box.addWidget(self.api_btn, 1)
#         api_wrap = QWidget()
#         api_wrap.setLayout(api_box)
# 
#         self.gradio_btn = QPushButton("✦  Gradio UI")
#         self.gradio_btn.setMinimumHeight(36)
#         self.gradio_btn.setCursor(QCursor(Qt.PointingHandCursor))
#         self.gradio_btn.setToolTip("Launch ACE-Step's built-in Gradio interface")
#         self.gradio_btn.clicked.connect(self._on_gradio_clicked)
# 
#         row.addWidget(api_wrap, 1)
#         row.addWidget(self.gradio_btn, 1)
#         layout.addLayout(row)
# 
#         # Folder shortcuts row
#         row2 = QHBoxLayout()
#         row2.setSpacing(10)
#         self.webui_folder_btn = QPushButton("📁  WebUI Folder")
#         self.webui_folder_btn.setMinimumHeight(32)
#         self.webui_folder_btn.setCursor(QCursor(Qt.PointingHandCursor))
#         self.webui_folder_btn.clicked.connect(lambda: open_path(WEBUI_DIR))
#         self.gen_folder_btn = QPushButton("🎵  Generations")
#         self.gen_folder_btn.setMinimumHeight(32)
#         self.gen_folder_btn.setCursor(QCursor(Qt.PointingHandCursor))
#         self.gen_folder_btn.clicked.connect(lambda: open_path(GENERATIONS_DIR))
#         row2.addWidget(self.webui_folder_btn, 1)
#         row2.addWidget(self.gen_folder_btn, 1)
#         layout.addLayout(row2)
# 
#         layout.addSpacing(6)
# 
#         # Settings card
#         card = QFrame()
#         card.setObjectName("card")
#         card_lay = QVBoxLayout(card)
#         card_lay.setContentsMargins(14, 12, 14, 12)
#         card_lay.setSpacing(8)
# 
#         settings_title = QLabel("Settings")
#         settings_title.setStyleSheet(f"color: {THEME['fg']}; font-weight: 600; font-size: 11px;")
#         card_lay.addWidget(settings_title)
# 
#         self.skip_llm_cb = QCheckBox("Skip LLM (DiT-only mode)")
#         self.skip_llm_cb.setChecked(self.settings.get("skip_llm", False))
#         self.skip_llm_cb.toggled.connect(self._save_settings)
#         card_lay.addWidget(self.skip_llm_cb)
# 
#         self.show_term_cb = QCheckBox("Show terminal window (API output)")
#         self.show_term_cb.setChecked(self.settings.get("show_terminal", False))
#         self.show_term_cb.toggled.connect(self._save_settings)
#         card_lay.addWidget(self.show_term_cb)
# 
#         layout.addWidget(card)
#         layout.addStretch(1)
# 
#         # Status bar
#         self.status = QStatusBar()
#         self.status.setSizeGripEnabled(False)
#         self.status_label = QLabel("Ready.")
#         self.status_label.setObjectName("status")
#         self.status.addWidget(self.status_label, 1)
#         self.setStatusBar(self.status)
# 
#     def _save_settings(self):
#         self.settings["skip_llm"] = self.skip_llm_cb.isChecked()
#         self.settings["show_terminal"] = self.show_term_cb.isChecked()
#         save_settings(self.settings)
# 
#     def _setup_workers(self):
#         self.api_thread = QThread()
#         self.api_worker = APIWorker()
#         self.api_worker.moveToThread(self.api_thread)
# 
#         # Wire signals (cross-thread, automatically marshaled by Qt)
#         self.api_worker.status_update.connect(self._set_status)
#         self.api_worker.api_started.connect(self.api_dot.set_running)
#         self.api_worker.webui_ready.connect(self._open_webuis)
# 
#         self.request_launch_webui.connect(self.api_worker.launch_webui)
#         self.request_toggle_api.connect(self.api_worker.start_api_only)
# 
#         self.api_thread.start()
# 
#     def _setup_polling(self):
#         # Poll API state every 2s ON THE MAIN THREAD (port_in_use is fast).
#         # Qt's QTimer is single-threaded; no XInitThreads concerns.
#         self.poll_timer = QTimer(self)
#         self.poll_timer.setInterval(2000)
#         self.poll_timer.timeout.connect(self._poll_api_state)
#         self.poll_timer.start()
# 
#     def _setup_lifecycle(self):
#         kill_orphaned_acestep_procs(silent=True)
#         start_config_server()
# 
#     def _poll_api_state(self):
#         running = is_api_running()
#         self.api_dot.set_running(running)
# 
#     def _set_status(self, msg):
#         self.status_label.setText(msg)
# 
#     def _on_launch_clicked(self):
#         self._set_status("Starting API server...")
#         self.request_launch_webui.emit(dict(self.settings))
# 
#     def _on_toggle_api_clicked(self):
#         if is_api_running():
#             stop_api()
#             self.api_dot.set_running(False)
#             self._set_status("API server stopped.")
#         else:
#             self._set_status("Starting API server...")
#             self.request_toggle_api.emit(dict(self.settings))
# 
#     def _on_gradio_clicked(self):
#         def _go():
#             port = find_free_port(GRADIO_PORT)
#             self.api_worker.status_update.emit(f"Starting Gradio on :{port}...")
#             python_bin = _venv_bin("python")
#             try:
#                 subprocess.Popen(
#                     [python_bin, "-m", "acestep.gradio_app", "--port", str(port)],
#                     cwd=str(REPO_DIR), start_new_session=True,
#                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
#                 )
#             except Exception as exc:
#                 self.api_worker.status_update.emit(f"Gradio launch failed: {exc}")
#                 return
#             time.sleep(10)
#             webbrowser.open(f"http://127.0.0.1:{port}")
#             self.api_worker.status_update.emit(f"Gradio open at :{port}")
#         threading.Thread(target=_go, daemon=True).start()
# 
#     def _open_webuis(self, paths):
#         for p in paths:
#             try:
#                 webbrowser.open(p.as_uri())
#             except Exception as e:
#                 print(f"Failed to open {p}: {e}", file=sys.stderr)
# 
#     def closeEvent(self, event):
#         stop_api()
#         if self.api_thread.isRunning():
#             self.api_thread.quit()
#             self.api_thread.wait(2000)
#         super().closeEvent(event)
# 
# 
# # ============================================================================
# # MAIN
# # ============================================================================
# def main():
#     # On Linux, try to set the application's window class so DEs group taskbar
#     # entries correctly.
#     if IS_LINUX:
#         os.environ.setdefault("QT_QPA_PLATFORMTHEME", "")  # don't try to read distro theme
# 
#     app = QApplication(sys.argv)
#     app.setApplicationName("ACE-Step")
#     app.setApplicationDisplayName("ACE-Step 1.5")
#     app.setOrganizationName("ACE-Step")
# 
#     # Force fusion style for consistent dark look across desktops
#     app.setStyle("Fusion")
# 
#     # Print env info to stderr
#     gpu_name = os.environ.get("GPU_NAME", "unknown")
#     gpu_vendor = os.environ.get("GPU_VENDOR", "unknown")
#     print(f"GPU:     {gpu_name} ({gpu_vendor})", file=sys.stderr)
#     print(f"Install: {INSTALL_DIR}", file=sys.stderr)
#     print(f"Venv:    {VENV_DIR}", file=sys.stderr)
# 
#     WEBUI_DIR.mkdir(parents=True, exist_ok=True)
#     GENERATIONS_DIR.mkdir(parents=True, exist_ok=True)
# 
#     win = LauncherWindow()
#     win.show()
#     sys.exit(app.exec())
# 
# 
# if __name__ == "__main__":
#     main()
# === EMBEDDED_LAUNCHER_PY_END ===

# === EMBEDDED_DOWNLOADER_PY_BEGIN ===
# """
# ACE-Step Model Downloader — Qt edition.
# 
# Replaces huggingface_hub's noisy multi-bar tqdm output with a single clean
# progress dialog showing aggregate %, bytes, speed, ETA, and per-file state.
# 
# Design notes:
#   - We pre-list every file via list_repo_files() so we know total bytes upfront.
#   - Downloads are sequential (not parallel) for predictable progress and to
#     avoid hammering HF's CDN with concurrent connections from one host.
#   - Each file is fetched via urllib with 64 KiB chunks; per-chunk we emit
#     a Qt signal carrying current/total byte counts.
#   - Files download to <name>.partial then rename atomically when complete.
#     If the user cancels mid-download, the partial sticks around and we
#     resume on next launch with HTTP Range headers.
#   - All HF API calls go through huggingface_hub when available (handles
#     LFS pointers, revisions, etc) and fall back to the CDN URL pattern.
# 
# Usage from ace-step.sh's download_models step:
#   python3 download_models_qt.py \
#     --models-dir /home/user/.local/share/ace-step/data/models \
#     --repo ACE-Step/ACE-Step-v1-3.5B:acestep-v15-turbo \
#     --repo ACE-Step/ACE-Step-v1-LM-0.6B:acestep-5Hz-lm-0.6B \
#     --repo ACE-Step/ACE-Step-v1-LM-1.7B:acestep-5Hz-lm-1.7B
# """
# 
# from __future__ import annotations
# 
# import argparse
# import json
# import os
# import sys
# import threading
# import time
# from dataclasses import dataclass, field
# from pathlib import Path
# from typing import Optional
# from urllib.error import HTTPError, URLError
# from urllib.request import Request, urlopen
# 
# from PySide6.QtCore import (
#     Qt, QObject, QThread, Signal, QTimer, QSize
# )
# from PySide6.QtGui import QPainter, QColor, QBrush, QFont, QIcon
# from PySide6.QtWidgets import (
#     QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QProgressBar,
#     QPushButton, QFrame, QListWidget, QListWidgetItem, QMessageBox,
#     QSizePolicy, QStyle
# )
# 
# 
# # ============================================================================
# # THEME (matches launcher.py)
# # ============================================================================
# THEME = {
#     "bg":            "#0e1117",
#     "bg_elevated":   "#161b22",
#     "bg_hover":      "#1f262f",
#     "border":        "#30363d",
#     "fg":            "#e6edf3",
#     "fg_dim":        "#7d8590",
#     "accent":        "#2f81f7",
#     "accent_hover":  "#3a94ff",
#     "success":       "#3fb950",
#     "danger":        "#f85149",
#     "warning":       "#d29922",
# }
# 
# QSS = f"""
# QWidget#root {{
#     background-color: {THEME['bg']};
#     color: {THEME['fg']};
# }}
# 
# QLabel {{
#     color: {THEME['fg']};
#     background: transparent;
# }}
# 
# QLabel#title {{
#     font-size: 16px;
#     font-weight: 600;
#     color: {THEME['fg']};
# }}
# 
# QLabel#subtitle {{
#     font-size: 11px;
#     color: {THEME['fg_dim']};
# }}
# 
# QLabel#bigPercent {{
#     font-size: 32px;
#     font-weight: 700;
#     color: {THEME['accent']};
# }}
# 
# QLabel#stats {{
#     font-size: 11px;
#     color: {THEME['fg_dim']};
# }}
# 
# QLabel#currentFile {{
#     font-size: 11px;
#     color: {THEME['fg']};
#     font-family: "DejaVu Sans Mono", "Liberation Mono", monospace;
# }}
# 
# QFrame#card {{
#     background-color: {THEME['bg_elevated']};
#     border: 1px solid {THEME['border']};
#     border-radius: 8px;
# }}
# 
# QProgressBar {{
#     background-color: {THEME['bg_elevated']};
#     border: 1px solid {THEME['border']};
#     border-radius: 6px;
#     height: 14px;
#     text-align: center;
#     color: transparent;
# }}
# 
# QProgressBar::chunk {{
#     background-color: {THEME['accent']};
#     border-radius: 5px;
# }}
# 
# QPushButton {{
#     background-color: {THEME['bg_elevated']};
#     color: {THEME['fg']};
#     border: 1px solid {THEME['border']};
#     border-radius: 6px;
#     padding: 8px 18px;
#     font-size: 11px;
#     font-weight: 500;
# }}
# 
# QPushButton:hover {{
#     background-color: {THEME['bg_hover']};
#     border-color: {THEME['accent']};
# }}
# 
# QPushButton#danger:hover {{
#     border-color: {THEME['danger']};
#     color: {THEME['danger']};
# }}
# 
# QListWidget {{
#     background-color: {THEME['bg_elevated']};
#     border: 1px solid {THEME['border']};
#     border-radius: 6px;
#     color: {THEME['fg_dim']};
#     font-size: 10px;
#     font-family: "DejaVu Sans Mono", "Liberation Mono", monospace;
#     padding: 4px;
# }}
# 
# QListWidget::item {{
#     border: none;
#     padding: 3px 8px;
# }}
# """
# 
# 
# # ============================================================================
# # DATA
# # ============================================================================
# @dataclass
# class FileEntry:
#     repo: str          # e.g. "ACE-Step/ACE-Step-v1-3.5B"
#     rel_path: str      # path within the repo, e.g. "music_vocoder/model.safetensors"
#     local_dir: str     # local subdir name we map this repo to
#     size: int = 0      # total size in bytes (filled in pre-flight)
#     downloaded: int = 0
#     state: str = "pending"  # pending | active | done | error
#     error_msg: str = ""
# 
#     @property
#     def display_path(self) -> str:
#         return f"{self.local_dir}/{self.rel_path}"
# 
#     @property
#     def local_path(self) -> Path:
#         # filled in by caller, but compute here as helper
#         return Path(self.local_dir) / self.rel_path
# 
# 
# @dataclass
# class DownloadPlan:
#     files: list[FileEntry] = field(default_factory=list)
# 
#     @property
#     def total_bytes(self) -> int:
#         return sum(f.size for f in self.files)
# 
#     @property
#     def downloaded_bytes(self) -> int:
#         return sum(f.downloaded for f in self.files)
# 
# 
# # ============================================================================
# # WORKER THREAD
# # ============================================================================
# class DownloadWorker(QObject):
#     """Runs the download on a background thread; emits Qt signals to UI."""
# 
#     plan_ready = Signal(object)              # DownloadPlan
#     file_started = Signal(int)               # file index
#     file_progress = Signal(int, int, int)    # idx, downloaded, total
#     file_done = Signal(int)                  # idx
#     file_error = Signal(int, str)            # idx, error
#     overall_progress = Signal(int, int, float)  # downloaded, total, speed_bps
#     finished = Signal(bool, str)             # success, message
# 
#     def __init__(self, models_dir: Path, repos: list[tuple[str, str]]):
#         """
#         repos: list of (huggingface_repo_id, local_subdir_name)
#         """
#         super().__init__()
#         self.models_dir = Path(models_dir)
#         self.repos = repos
#         self._cancel = False
#         self._plan: Optional[DownloadPlan] = None
# 
#     def cancel(self):
#         self._cancel = True
# 
#     def run(self):
#         try:
#             self._do_run()
#         except Exception as e:
#             self.finished.emit(False, f"Unexpected error: {e}")
# 
#     def _do_run(self):
#         # Step 1: Pre-flight — list all files in all repos.
#         self._plan = DownloadPlan()
# 
#         try:
#             from huggingface_hub import HfApi
#             api = HfApi()
#         except ImportError:
#             self.finished.emit(False, "huggingface_hub not installed in venv")
#             return
# 
#         for repo_id, local_subdir in self.repos:
#             if self._cancel:
#                 self.finished.emit(False, "Cancelled before listing")
#                 return
#             try:
#                 # repo_info has size info; list_repo_files only gives names
#                 info = api.repo_info(repo_id=repo_id, files_metadata=True)
#             except Exception as e:
#                 self.finished.emit(False, f"Failed to query {repo_id}: {e}")
#                 return
# 
#             for sib in info.siblings:
#                 size = getattr(sib, "size", None) or 0
#                 # Skip enormous files we don't need? No — bundle everything,
#                 # snapshot_download equivalent.
#                 self._plan.files.append(FileEntry(
#                     repo=repo_id,
#                     rel_path=sib.rfilename,
#                     local_dir=local_subdir,
#                     size=size,
#                 ))
# 
#         # If sizes are zero (some HF endpoints don't return them), do a HEAD
#         # to fill them in. Otherwise our progress will be wrong.
#         for f in self._plan.files:
#             if f.size == 0 and not self._cancel:
#                 f.size = self._head_size(f) or 0
# 
#         # Account for already-downloaded files (resume support)
#         for f in self._plan.files:
#             target = self.models_dir / f.local_dir / f.rel_path
#             partial = target.with_suffix(target.suffix + ".partial")
#             if target.exists() and target.stat().st_size == f.size:
#                 f.downloaded = f.size
#                 f.state = "done"
#             elif partial.exists():
#                 f.downloaded = partial.stat().st_size
#                 # Keep state=pending; we'll resume
# 
#         self.plan_ready.emit(self._plan)
# 
#         # Step 2: Download each file sequentially.
#         speed_window: list[tuple[float, int]] = []  # (timestamp, total_downloaded)
#         last_overall_emit = 0.0
# 
#         for idx, f in enumerate(self._plan.files):
#             if self._cancel:
#                 self.finished.emit(False, "Cancelled by user")
#                 return
# 
#             if f.state == "done":
#                 # Already complete from previous run
#                 self.file_done.emit(idx)
#                 continue
# 
#             f.state = "active"
#             self.file_started.emit(idx)
# 
#             try:
#                 self._download_file(f, idx, speed_window)
#             except _CancelledError:
#                 self.finished.emit(False, "Cancelled by user")
#                 return
#             except Exception as e:
#                 f.state = "error"
#                 f.error_msg = str(e)
#                 self.file_error.emit(idx, str(e))
#                 self.finished.emit(False, f"Failed: {f.display_path}: {e}")
#                 return
# 
#             f.state = "done"
#             self.file_done.emit(idx)
# 
#         # Mark this set of repos as complete
#         marker = self.models_dir / ".populated"
#         marker.touch()
# 
#         self.finished.emit(True, "All models downloaded successfully.")
# 
#     def _head_size(self, f: FileEntry) -> Optional[int]:
#         url = self._url_for(f)
#         try:
#             req = Request(url, method="HEAD")
#             with urlopen(req, timeout=15) as resp:
#                 cl = resp.headers.get("Content-Length")
#                 if cl:
#                     return int(cl)
#         except Exception:
#             pass
#         return None
# 
#     @staticmethod
#     def _url_for(f: FileEntry) -> str:
#         # Standard HF resolver URL. Branch defaults to "main".
#         # Format: https://huggingface.co/<repo>/resolve/main/<path>
#         return f"https://huggingface.co/{f.repo}/resolve/main/{f.rel_path}"
# 
#     def _download_file(self, f: FileEntry, idx: int, speed_window: list):
#         target = self.models_dir / f.local_dir / f.rel_path
#         target.parent.mkdir(parents=True, exist_ok=True)
#         partial = target.with_suffix(target.suffix + ".partial")
# 
#         # Determine resume offset
#         existing = partial.stat().st_size if partial.exists() else 0
#         if existing > f.size > 0:
#             # Partial is somehow bigger than expected — discard
#             partial.unlink()
#             existing = 0
# 
#         url = self._url_for(f)
#         headers = {}
#         mode = "ab"
#         if existing > 0 and f.size > 0 and existing < f.size:
#             headers["Range"] = f"bytes={existing}-"
#         else:
#             mode = "wb"
#             existing = 0
# 
#         f.downloaded = existing
# 
#         req = Request(url, headers=headers)
#         try:
#             resp = urlopen(req, timeout=30)
#         except HTTPError as e:
#             if e.code == 416 and existing == f.size:
#                 # Already complete; just rename
#                 partial.rename(target)
#                 return
#             raise
# 
#         # Stream to disk
#         chunk = 64 * 1024
#         last_emit = 0.0
# 
#         with open(partial, mode) as out:
#             while True:
#                 if self._cancel:
#                     out.flush()
#                     raise _CancelledError()
#                 buf = resp.read(chunk)
#                 if not buf:
#                     break
#                 out.write(buf)
#                 f.downloaded += len(buf)
# 
#                 now = time.time()
#                 # Throttle UI updates to ~20 Hz
#                 if now - last_emit >= 0.05:
#                     self.file_progress.emit(idx, f.downloaded, f.size)
#                     self._emit_overall(speed_window)
#                     last_emit = now
# 
#         # Atomic rename
#         partial.rename(target)
# 
#         # Final emit
#         self.file_progress.emit(idx, f.downloaded, f.size)
#         self._emit_overall(speed_window)
# 
#     def _emit_overall(self, speed_window: list):
#         if self._plan is None:
#             return
#         downloaded = self._plan.downloaded_bytes
#         total = self._plan.total_bytes
#         now = time.time()
#         speed_window.append((now, downloaded))
#         # Keep only the last ~3 seconds
#         cutoff = now - 3.0
#         while len(speed_window) > 1 and speed_window[0][0] < cutoff:
#             speed_window.pop(0)
#         speed_bps = 0.0
#         if len(speed_window) >= 2:
#             dt = speed_window[-1][0] - speed_window[0][0]
#             db = speed_window[-1][1] - speed_window[0][1]
#             if dt > 0:
#                 speed_bps = db / dt
#         self.overall_progress.emit(downloaded, total, speed_bps)
# 
# 
# class _CancelledError(Exception):
#     pass
# 
# 
# # ============================================================================
# # UI HELPERS
# # ============================================================================
# def fmt_bytes(n: int) -> str:
#     if n < 1024: return f"{n} B"
#     if n < 1024 ** 2: return f"{n/1024:.1f} KB"
#     if n < 1024 ** 3: return f"{n/1024**2:.1f} MB"
#     return f"{n/1024**3:.2f} GB"
# 
# 
# def fmt_speed(bps: float) -> str:
#     if bps <= 0: return "—"
#     if bps < 1024: return f"{bps:.0f} B/s"
#     if bps < 1024 ** 2: return f"{bps/1024:.1f} KB/s"
#     if bps < 1024 ** 3: return f"{bps/1024**2:.1f} MB/s"
#     return f"{bps/1024**3:.2f} GB/s"
# 
# 
# def fmt_eta(remaining_bytes: int, bps: float) -> str:
#     if bps <= 0 or remaining_bytes <= 0: return "—"
#     secs = int(remaining_bytes / bps)
#     if secs < 60: return f"{secs}s"
#     if secs < 3600: return f"{secs//60}m {secs%60}s"
#     h = secs // 3600
#     m = (secs % 3600) // 60
#     return f"{h}h {m}m"
# 
# 
# # ============================================================================
# # MAIN WINDOW
# # ============================================================================
# class DownloadWindow(QWidget):
#     def __init__(self, models_dir: Path, repos: list[tuple[str, str]]):
#         super().__init__()
#         self.models_dir = models_dir
#         self.repos = repos
#         self.plan: Optional[DownloadPlan] = None
#         self.exit_code = 1  # default to failure unless we explicitly succeed
# 
#         self._build_ui()
#         self._start_worker()
# 
#     def _build_ui(self):
#         self.setObjectName("root")
#         self.setWindowTitle("ACE-Step — Downloading Models")
#         self.setStyleSheet(QSS)
#         self.setFixedSize(560, 480)
# 
#         layout = QVBoxLayout(self)
#         layout.setContentsMargins(28, 22, 28, 22)
#         layout.setSpacing(14)
# 
#         # Header
#         title = QLabel("Downloading AI Models")
#         title.setObjectName("title")
#         layout.addWidget(title)
# 
#         self.subtitle = QLabel("Preparing…")
#         self.subtitle.setObjectName("subtitle")
#         layout.addWidget(self.subtitle)
# 
#         # Big percentage card
#         card = QFrame()
#         card.setObjectName("card")
#         card_lay = QVBoxLayout(card)
#         card_lay.setContentsMargins(20, 16, 20, 16)
#         card_lay.setSpacing(8)
# 
#         # Top row: big percentage + stats column
#         top = QHBoxLayout()
#         top.setSpacing(20)
# 
#         self.percent_lbl = QLabel("0%")
#         self.percent_lbl.setObjectName("bigPercent")
#         self.percent_lbl.setMinimumWidth(110)
#         top.addWidget(self.percent_lbl)
# 
#         stats_col = QVBoxLayout()
#         stats_col.setSpacing(2)
#         self.bytes_lbl = QLabel("0 B / —")
#         self.bytes_lbl.setObjectName("stats")
#         self.speed_lbl = QLabel("Speed: — • ETA: —")
#         self.speed_lbl.setObjectName("stats")
#         self.current_lbl = QLabel("Listing files from Hugging Face…")
#         self.current_lbl.setObjectName("currentFile")
#         self.current_lbl.setWordWrap(False)
#         # Truncate long paths visually
#         self.current_lbl.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
#         stats_col.addWidget(self.bytes_lbl)
#         stats_col.addWidget(self.speed_lbl)
#         stats_col.addStretch(1)
#         stats_col.addWidget(self.current_lbl)
#         top.addLayout(stats_col, 1)
# 
#         card_lay.addLayout(top)
# 
#         # Progress bar
#         self.bar = QProgressBar()
#         self.bar.setRange(0, 1000)  # finer than 100 so animation is smooth
#         self.bar.setValue(0)
#         card_lay.addWidget(self.bar)
# 
#         layout.addWidget(card)
# 
#         # File list
#         list_label = QLabel("Files")
#         list_label.setObjectName("subtitle")
#         layout.addWidget(list_label)
# 
#         self.file_list = QListWidget()
#         self.file_list.setSelectionMode(QListWidget.NoSelection)
#         self.file_list.setVerticalScrollMode(QListWidget.ScrollPerPixel)
#         layout.addWidget(self.file_list, 1)
# 
#         # Bottom buttons
#         btn_row = QHBoxLayout()
#         btn_row.addStretch(1)
#         self.cancel_btn = QPushButton("Cancel")
#         self.cancel_btn.setObjectName("danger")
#         self.cancel_btn.clicked.connect(self._on_cancel)
#         btn_row.addWidget(self.cancel_btn)
#         layout.addLayout(btn_row)
# 
#     def _start_worker(self):
#         self.thread = QThread()
#         self.worker = DownloadWorker(self.models_dir, self.repos)
#         self.worker.moveToThread(self.thread)
# 
#         self.worker.plan_ready.connect(self._on_plan_ready)
#         self.worker.file_started.connect(self._on_file_started)
#         self.worker.file_progress.connect(self._on_file_progress)
#         self.worker.file_done.connect(self._on_file_done)
#         self.worker.file_error.connect(self._on_file_error)
#         self.worker.overall_progress.connect(self._on_overall)
#         self.worker.finished.connect(self._on_finished)
# 
#         self.thread.started.connect(self.worker.run)
#         self.thread.start()
# 
#     # ----- worker signal handlers -----
# 
#     def _on_plan_ready(self, plan: DownloadPlan):
#         self.plan = plan
#         total_str = fmt_bytes(plan.total_bytes) if plan.total_bytes > 0 else "—"
#         self.subtitle.setText(f"{len(plan.files)} files • {total_str} total")
#         self.bytes_lbl.setText(f"0 B / {total_str}")
# 
#         # Populate the file list
#         self.file_list.clear()
#         for f in plan.files:
#             label = f.display_path
#             if f.size > 0:
#                 label += f"  ({fmt_bytes(f.size)})"
#             item = QListWidgetItem(f"  ○  {label}")
#             if f.state == "done":
#                 item.setText(f"  ✓  {label}")
#                 item.setForeground(QColor(THEME["success"]))
#             else:
#                 item.setForeground(QColor(THEME["fg_dim"]))
#             self.file_list.addItem(item)
# 
#         # If everything is already done from a prior run, fast-path success
#         if plan.total_bytes > 0:
#             initial_pct = plan.downloaded_bytes / plan.total_bytes
#             self.bar.setValue(int(initial_pct * 1000))
#             self.percent_lbl.setText(f"{int(initial_pct*100)}%")
# 
#     def _on_file_started(self, idx: int):
#         if not self.plan: return
#         f = self.plan.files[idx]
#         label = f.display_path
#         if f.size > 0:
#             label += f"  ({fmt_bytes(f.size)})"
#         item = self.file_list.item(idx)
#         if item:
#             item.setText(f"  ●  {label}")
#             item.setForeground(QColor(THEME["accent"]))
#             self.file_list.scrollToItem(item)
#         # Truncate the current-file label to fit
#         self._set_current_file_label(f.display_path)
# 
#     def _on_file_progress(self, idx: int, downloaded: int, total: int):
#         # We don't update the file list per-chunk — only the current_lbl
#         # gets a per-file %, which avoids redrawing the whole list 20x/sec.
#         if not self.plan: return
#         f = self.plan.files[idx]
#         if total > 0:
#             pct = int(100 * downloaded / total)
#             self._set_current_file_label(f"{f.display_path}  ({pct}%)")
# 
#     def _on_file_done(self, idx: int):
#         if not self.plan: return
#         f = self.plan.files[idx]
#         label = f.display_path
#         if f.size > 0:
#             label += f"  ({fmt_bytes(f.size)})"
#         item = self.file_list.item(idx)
#         if item:
#             item.setText(f"  ✓  {label}")
#             item.setForeground(QColor(THEME["success"]))
# 
#     def _on_file_error(self, idx: int, msg: str):
#         if not self.plan: return
#         f = self.plan.files[idx]
#         item = self.file_list.item(idx)
#         if item:
#             item.setText(f"  ✗  {f.display_path}  ({msg})")
#             item.setForeground(QColor(THEME["danger"]))
# 
#     def _on_overall(self, downloaded: int, total: int, speed_bps: float):
#         if total > 0:
#             ratio = downloaded / total
#             self.bar.setValue(int(ratio * 1000))
#             self.percent_lbl.setText(f"{int(ratio*100)}%")
#         self.bytes_lbl.setText(f"{fmt_bytes(downloaded)} / {fmt_bytes(total)}")
#         eta = fmt_eta(max(0, total - downloaded), speed_bps)
#         self.speed_lbl.setText(f"Speed: {fmt_speed(speed_bps)}  •  ETA: {eta}")
# 
#     def _on_finished(self, success: bool, message: str):
#         self.thread.quit()
#         self.thread.wait(2000)
#         if success:
#             self.exit_code = 0
#             self.bar.setValue(1000)
#             self.percent_lbl.setText("100%")
#             self.subtitle.setText("✓ Complete")
#             self.cancel_btn.setText("Done")
#             self.cancel_btn.setObjectName("")  # remove danger styling
#             self.cancel_btn.setStyleSheet("")
#             self.cancel_btn.clicked.disconnect()
#             self.cancel_btn.clicked.connect(self.close)
#             QTimer.singleShot(800, self.close)
#         else:
#             self.exit_code = 1
#             self.subtitle.setText(f"✗ {message}")
#             self.cancel_btn.setText("Close")
#             self.cancel_btn.clicked.disconnect()
#             self.cancel_btn.clicked.connect(self.close)
# 
#     def _on_cancel(self):
#         if hasattr(self, "worker"):
#             self.worker.cancel()
#         self.cancel_btn.setEnabled(False)
#         self.cancel_btn.setText("Cancelling…")
# 
#     def _set_current_file_label(self, text: str):
#         # Visual truncation for long paths
#         max_chars = 60
#         if len(text) > max_chars:
#             text = "…" + text[-(max_chars - 1):]
#         self.current_lbl.setText(text)
# 
#     def closeEvent(self, event):
#         if hasattr(self, "worker"):
#             self.worker.cancel()
#         if hasattr(self, "thread") and self.thread.isRunning():
#             self.thread.quit()
#             self.thread.wait(2000)
#         super().closeEvent(event)
# 
# 
# # ============================================================================
# # MAIN
# # ============================================================================
# def main():
#     parser = argparse.ArgumentParser()
#     parser.add_argument("--models-dir", required=True,
#                         help="Where to download models (e.g. ~/.local/share/ace-step/data/models)")
#     parser.add_argument("--repo", action="append", required=True,
#                         help="repo:local_subdir, e.g. 'ACE-Step/ACE-Step-v1-3.5B:acestep-v15-turbo'")
#     args = parser.parse_args()
# 
#     repos = []
#     for r in args.repo:
#         if ":" not in r:
#             print(f"ERROR: --repo expects 'repo_id:local_dir', got: {r}", file=sys.stderr)
#             sys.exit(2)
#         repo_id, local = r.split(":", 1)
#         repos.append((repo_id, local))
# 
#     models_dir = Path(args.models_dir).expanduser().resolve()
#     models_dir.mkdir(parents=True, exist_ok=True)
# 
#     app = QApplication(sys.argv)
#     app.setApplicationName("ACE-Step Downloader")
#     app.setApplicationDisplayName("ACE-Step Model Downloader")
#     app.setStyle("Fusion")
# 
#     win = DownloadWindow(models_dir, repos)
#     win.show()
#     app.exec()
#     sys.exit(win.exit_code)
# 
# 
# if __name__ == "__main__":
#     main()
# === EMBEDDED_DOWNLOADER_PY_END ===
