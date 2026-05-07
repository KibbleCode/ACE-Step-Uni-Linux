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
