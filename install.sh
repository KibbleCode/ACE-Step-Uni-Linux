#!/usr/bin/env bash
# ACE-Step 1.5 Installer -- Linux
# One script. One command. Done.
#
# Usage:
#   chmod +x install.sh && ./install.sh
#   ./install.sh --skip-models        Skip model download prompt
#   ./install.sh --skip-llm           DiT-only mode (low-RAM systems)

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# --- Args ---
SKIP_MODELS=false
SKIP_LLM=false
for arg in "$@"; do
    case "$arg" in
        --skip-models) SKIP_MODELS=true ;;
        --skip-llm)    SKIP_LLM=true ;;
    esac
done

echo ""
echo -e "${CYAN}=== ACE-Step 1.5 Installer (Linux) ===${NC}"

# ==============================================================
# STEP 0: Distro detection + system deps
# ==============================================================
echo ""
echo -e "${YELLOW}[0/5] Checking system dependencies...${NC}"

install_pkg() {
    # Detect package manager and install required system packages
    if command -v pacman &>/dev/null; then
        echo -e "  ${GRAY}-> Arch detected, using pacman${NC}"
        sudo pacman -S --needed --noconfirm git python tk python-gobject
    elif command -v apt-get &>/dev/null; then
        echo -e "  ${GRAY}-> Debian/Ubuntu detected, using apt${NC}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq git python3 python3-tk python3-gi
    elif command -v dnf &>/dev/null; then
        echo -e "  ${GRAY}-> Fedora/RHEL detected, using dnf${NC}"
        sudo dnf install -y -q git python3 python3-tkinter python3-gobject
    elif command -v zypper &>/dev/null; then
        echo -e "  ${GRAY}-> openSUSE detected, using zypper${NC}"
        sudo zypper install -y git python3 python3-tk python3-gobject
    else
        echo -e "  ${YELLOW}[!] Unknown distro -- install git, python3, and python3-tk manually${NC}"
    fi
}

# Check for git
if ! command -v git &>/dev/null; then
    echo -e "  ${GRAY}-> git not found, installing system deps...${NC}"
    install_pkg
else
    echo -e "  ${GREEN}[OK] git found${NC}"
fi

# Check for python3
if ! command -v python3 &>/dev/null; then
    echo -e "  ${GRAY}-> python3 not found, installing system deps...${NC}"
    install_pkg
else
    echo -e "  ${GREEN}[OK] python3 found: $(python3 --version 2>&1)${NC}"
fi

# Check tkinter is importable (needed for launcher GUI)
if ! python3 -c "import tkinter" &>/dev/null; then
    echo -e "  ${GRAY}-> tkinter not importable, installing system deps...${NC}"
    install_pkg
    if ! python3 -c "import tkinter" &>/dev/null; then
        echo -e "  ${YELLOW}[!] tkinter still not working -- launcher GUI may not start${NC}"
        echo -e "  ${YELLOW}    Install python3-tk for your distro manually${NC}"
    fi
else
    echo -e "  ${GREEN}[OK] tkinter available${NC}"
fi

# ==============================================================
# STEP 1: Find or clone repo
# ==============================================================
echo ""
echo -e "${YELLOW}[1/5] Locating ACE-Step 1.5...${NC}"

INSTALL_PATH=""
for check_dir in "$HOME/ACE-Step-1.5" "$HOME/Downloads/ACE-Step-1.5"; do
    if [ -d "$check_dir/.git" ]; then
        INSTALL_PATH="$check_dir"
        echo -e "  ${GREEN}[OK] Found existing install at: $INSTALL_PATH${NC}"
        break
    fi
done

# ==============================================================
# STEP 2: Check/Install UV
# ==============================================================
echo ""
echo -e "${YELLOW}[2/5] Checking UV package manager...${NC}"

if ! command -v uv &>/dev/null; then
    echo -e "  ${GRAY}-> UV not found, installing...${NC}"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Source the env so uv is available in this session
    export PATH="$HOME/.local/bin:$PATH"
    if command -v uv &>/dev/null; then
        echo -e "  ${GREEN}[OK] UV installed${NC}"
    else
        echo -e "  ${RED}[FAIL] UV install failed${NC}"
        echo -e "  ${YELLOW}Manual install: https://docs.astral.sh/uv/getting-started/installation/${NC}"
        exit 1
    fi
else
    echo -e "  ${GREEN}[OK] UV found: $(uv --version)${NC}"
fi

# Clone if not found
if [ -z "$INSTALL_PATH" ]; then
    echo ""
    echo -e "  ${GRAY}-> No existing install found, cloning repo...${NC}"
    INSTALL_PATH="$HOME/ACE-Step-1.5"
    git clone https://github.com/ace-step/ACE-Step-1.5.git "$INSTALL_PATH"
    if [ $? -ne 0 ]; then
        echo -e "  ${RED}[FAIL] Git clone failed${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}[OK] Cloned${NC}"
fi

cd "$INSTALL_PATH"


# ==============================================================
# STEP 3: Install dependencies
# ==============================================================
echo ""
echo -e "${YELLOW}[3/5] Installing dependencies...${NC}"
echo -e "  ${GRAY}(This may take a few minutes on first run)${NC}"

# Detect GPU vendor BEFORE installing deps
GPU_VENDOR="unknown"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    GPU_VENDOR="nvidia"
    echo -e "  ${GREEN}[OK] NVIDIA GPU detected${NC}"
elif command -v rocm-smi &>/dev/null || [ -d "/opt/rocm" ]; then
    GPU_VENDOR="amd"
    echo -e "  ${GREEN}[OK] AMD GPU detected (ROCm)${NC}"
else
    # Check lspci for AMD GPU even without ROCm installed
    if lspci 2>/dev/null | grep -qi 'vga.*amd\|display.*amd\|vga.*radeon\|display.*radeon'; then
        GPU_VENDOR="amd"
        echo -e "  ${YELLOW}[!] AMD GPU detected but ROCm not found${NC}"
        echo -e "  ${YELLOW}    Install ROCm first: https://rocm.docs.amd.com/en/latest/${NC}"
        echo -e "  ${GRAY}    Continuing with ROCm PyTorch anyway...${NC}"
    else
        echo -e "  ${YELLOW}[!] No GPU detected - will use CPU mode${NC}"
    fi
fi

uv sync
if [ $? -ne 0 ]; then
    echo -e "  ${RED}[FAIL] UV sync failed${NC}"
    exit 1
fi
echo -e "  ${GREEN}[OK] Dependencies installed${NC}"

# If AMD, replace CUDA torch with ROCm torch
if [ "$GPU_VENDOR" = "amd" ]; then
    echo -e "  ${CYAN}-> Replacing CUDA PyTorch with ROCm version...${NC}"
    uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.2.4 --quiet
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[OK] ROCm PyTorch installed${NC}"
    else
        echo -e "  ${YELLOW}[!] ROCm PyTorch install failed - trying rocm6.1...${NC}"
        uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.1 --quiet
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}[OK] ROCm 6.1 PyTorch installed${NC}"
        else
            echo -e "  ${RED}[!] ROCm PyTorch failed. Check ROCm version: https://pytorch.org/get-started/locally/${NC}"
        fi
    fi
fi

# Launcher GUI deps
echo -e "  ${GRAY}Installing launcher dependencies...${NC}"
uv pip install customtkinter Pillow psutil --quiet

# pystray is optional on Linux (launcher guards for it)
uv pip install pystray --quiet 2>/dev/null || true

# Pin torchao to avoid reinstall-on-every-launch bug
echo -e "  ${GRAY}Pinning torchao...${NC}"
uv pip install "torchao==0.14.1" --quiet 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}[OK] torchao pinned${NC}"
else
    echo -e "  ${YELLOW}[!] torchao pin failed - harmless reinstall spam on each launch${NC}"
fi

echo -e "  ${GREEN}[OK] Launcher dependencies installed${NC}"

# Copy launcher.py to install root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_SRC="$SCRIPT_DIR/installer/launcher.py"
# Also check if installer/ is a sibling (running from repo root)
if [ ! -f "$LAUNCHER_SRC" ]; then
    LAUNCHER_SRC="$SCRIPT_DIR/launcher.py"
fi
if [ -f "$LAUNCHER_SRC" ]; then
    cp "$LAUNCHER_SRC" "$INSTALL_PATH/launcher.py"
    echo -e "  ${GREEN}[OK] launcher.py placed at install root${NC}"
else
    echo -e "  ${YELLOW}[!] launcher.py not found in installer folder${NC}"
fi

# Copy webui HTML files
WEBUI_SRC="$SCRIPT_DIR/webui"
# Check parent dir too (repo root structure)
if [ ! -d "$WEBUI_SRC" ]; then
    WEBUI_SRC="$(dirname "$SCRIPT_DIR")/webui"
fi
WEBUI_DST="$INSTALL_PATH/webui"
mkdir -p "$WEBUI_DST"

if [ -d "$WEBUI_SRC" ]; then
    HTML_COUNT=$(find "$WEBUI_SRC" -maxdepth 1 -name '*.html' 2>/dev/null | wc -l)
    if [ "$HTML_COUNT" -gt 0 ]; then
        cp "$WEBUI_SRC"/*.html "$WEBUI_DST/"
        echo -e "  ${GREEN}[OK] $HTML_COUNT WebUI file(s) copied to /webui/${NC}"
    else
        echo -e "  ${YELLOW}[!] No .html files found in installer webui/ folder${NC}"
    fi
else
    echo -e "  ${YELLOW}[!] No webui folder in installer package${NC}"
fi

# --- VRAM Detection + .env ---
echo -e "  ${GRAY}Detecting GPU VRAM...${NC}"
VRAM_GB=0
GPU_NAME=""

if [ "$GPU_VENDOR" = "nvidia" ] && command -v nvidia-smi &>/dev/null; then
    # Parse nvidia-smi for best GPU
    while IFS=',' read -r mem name; do
        mem=$(echo "$mem" | tr -d ' ')
        name=$(echo "$name" | xargs)
        if [ -n "$mem" ] && [ "$mem" -gt 0 ] 2>/dev/null; then
            gb=$(echo "scale=1; $mem / 1024" | bc 2>/dev/null || echo "0")
            gb_int=${gb%.*}
            vram_int=${VRAM_GB%.*}
            if [ "${gb_int:-0}" -gt "${vram_int:-0}" ] 2>/dev/null; then
                VRAM_GB="$gb"
                GPU_NAME="$name"
            fi
        fi
    done < <(nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>/dev/null)
elif [ "$GPU_VENDOR" = "amd" ] && command -v rocm-smi &>/dev/null; then
    # Parse rocm-smi for AMD GPU VRAM
    # Try the newer JSON output first, fall back to text parsing
    VRAM_BYTES=$(rocm-smi --showmeminfo vram --json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    best = 0
    for card in data.values():
        if isinstance(card, dict):
            total = int(card.get('VRAM Total Memory (B)', card.get('vram_total', 0)))
            if total > best:
                best = total
    print(best)
except:
    print(0)
" 2>/dev/null)
    if [ -n "$VRAM_BYTES" ] && [ "$VRAM_BYTES" -gt 0 ] 2>/dev/null; then
        VRAM_GB=$(echo "scale=1; $VRAM_BYTES / 1073741824" | bc 2>/dev/null || echo "0")
    fi
    # Get GPU name
    GPU_NAME=$(rocm-smi --showproductname 2>/dev/null | grep -i "card series" | head -1 | sed 's/.*: *//' || echo "AMD GPU")
    [ -z "$GPU_NAME" ] && GPU_NAME="AMD GPU"
fi

if [ "$(echo "$VRAM_GB >= 12" | bc 2>/dev/null)" = "1" ]; then
    LM_MODEL="acestep-5Hz-lm-1.7B"
    echo -e "  ${GREEN}[OK] $GPU_NAME - ${VRAM_GB}GB - using 1.7B LM model${NC}"
elif [ "$(echo "$VRAM_GB > 0" | bc 2>/dev/null)" = "1" ]; then
    LM_MODEL="acestep-5Hz-lm-0.6B"
    echo -e "  ${YELLOW}[OK] $GPU_NAME - ${VRAM_GB}GB - using 0.6B LM model (1.7B needs 12GB+)${NC}"
else
    LM_MODEL="acestep-5Hz-lm-0.6B"
    echo -e "  ${YELLOW}[!] Could not detect VRAM - defaulting to 0.6B LM model${NC}"
fi

INIT_LLM="auto"
if [ "$SKIP_LLM" = true ]; then
    INIT_LLM="false"
fi

echo -e "  ${GRAY}Writing .env config...${NC}"
cat > "$INSTALL_PATH/.env" << EOF
ACESTEP_CONFIG_PATH=acestep-v15-turbo
ACESTEP_LM_MODEL_PATH=$LM_MODEL
ACESTEP_DEVICE=auto
ACESTEP_LM_BACKEND=pt
ACESTEP_INIT_LLM=$INIT_LLM
NO_PROXY=127.0.0.1,localhost
no_proxy=127.0.0.1,localhost
EOF

if [ "$SKIP_LLM" = true ]; then
    echo -e "  ${GREEN}[OK] .env written (DiT-only mode - LLM disabled)${NC}"
else
    echo -e "  ${GREEN}[OK] .env written (LM: $LM_MODEL)${NC}"
fi

# Remove empty/broken LM checkpoint dirs (causes init crash)
for lm_dir in "$INSTALL_PATH/checkpoints/acestep-5Hz-lm-0.6B" "$INSTALL_PATH/checkpoints/acestep-5Hz-lm-1.7B"; do
    if [ -d "$lm_dir" ]; then
        has_weights=false
        for wf in model.safetensors pytorch_model.bin tf_model.h5 model.ckpt.index flax_model.msgpack; do
            [ -f "$lm_dir/$wf" ] && has_weights=true && break
        done
        # Check sharded safetensors
        if [ "$has_weights" = false ]; then
            shards=$(find "$lm_dir" -name 'model-*.safetensors' 2>/dev/null | head -1)
            [ -n "$shards" ] && has_weights=true
        fi
        if [ "$has_weights" = false ]; then
            rm -rf "$lm_dir"
            echo -e "  ${GREEN}[OK] Removed empty/broken dir: $(basename "$lm_dir")${NC}"
        fi
    fi
done

# ==============================================================
# STEP 4: Models
# ==============================================================
echo ""
echo -e "${YELLOW}[4/5] Downloading models...${NC}"

if [ "$SKIP_MODELS" = true ]; then
    echo -e "  ${GRAY}-> Skipped (--skip-models). Models will download on first launch.${NC}"
else
    echo -e "  ${CYAN}  Downloading models (~9GB, resumes if interrupted)...${NC}"
    uv run acestep-download
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[OK] Models downloaded${NC}"
    else
        echo -e "  ${YELLOW}[!] Download stopped or incomplete. Run installer again to resume.${NC}"
    fi
fi

# ==============================================================
# STEP 5: Desktop shortcut (.desktop file)
# ==============================================================
echo ""
echo -e "${YELLOW}[5/5] Creating desktop shortcut...${NC}"

DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
LAUNCHER_DST="$INSTALL_PATH/launcher.py"
UV_PATH="$(command -v uv 2>/dev/null || echo "")"

if [ -f "$LAUNCHER_DST" ] && [ -d "$DESKTOP_DIR" ]; then
    cat > "$DESKTOP_DIR/ace-step-1.5.desktop" << EOF
[Desktop Entry]
Type=Application
Name=ACE-Step 1.5
Comment=AI Music Generation
Icon=audio-x-generic
Terminal=false
EOF

    # Add Exec line based on whether uv is available
    if [ -n "$UV_PATH" ]; then
        echo "Exec=$UV_PATH run python \"$LAUNCHER_DST\"" >> "$DESKTOP_DIR/ace-step-1.5.desktop"
    else
        echo "Exec=python3 \"$LAUNCHER_DST\"" >> "$DESKTOP_DIR/ace-step-1.5.desktop"
    fi
    echo "Path=$INSTALL_PATH" >> "$DESKTOP_DIR/ace-step-1.5.desktop"

    chmod +x "$DESKTOP_DIR/ace-step-1.5.desktop"
    # Some DEs need this to trust the .desktop file
    if command -v gio &>/dev/null; then
        gio set "$DESKTOP_DIR/ace-step-1.5.desktop" metadata::trusted true 2>/dev/null || true
    fi
    echo -e "  ${GREEN}[OK] Desktop shortcut created${NC}"
else
    echo -e "  ${YELLOW}[!] Could not create shortcut (launcher or Desktop dir missing)${NC}"
    echo -e "  ${GRAY}  Run manually: cd $INSTALL_PATH && uv run python launcher.py${NC}"
fi

# ==============================================================
# DONE
# ==============================================================
echo ""
echo -e "  ${GREEN}============================================${NC}"
echo -e "  ${GREEN}        INSTALLATION COMPLETE!${NC}"
echo -e "  ${GREEN}============================================${NC}"
echo ""
echo -e "  ${YELLOW}Installed to: $INSTALL_PATH${NC}"
echo ""
echo -e "  ${CYAN}Launch: cd $INSTALL_PATH && uv run python launcher.py${NC}"
echo -e "  ${GRAY}Or double-click the desktop shortcut.${NC}"
echo -e "  ${GRAY}First launch downloads models (~9GB) if not already present.${NC}"
echo ""
echo -e "  ${GRAY}--------------------------------------------${NC}"
echo -e "  ${GRAY}Everything lives in $INSTALL_PATH now.${NC}"
echo -e "  ${GRAY}You can safely delete this installer folder.${NC}"
echo -e "  ${GRAY}--------------------------------------------${NC}"
echo ""
