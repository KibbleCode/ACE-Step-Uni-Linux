#!/usr/bin/env bash
# ACE-Step 1.5 Uninstaller

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

echo ""
echo -e "${RED}  ============================================${NC}"
echo -e "${RED}         ACE-Step 1.5 Uninstaller${NC}"
echo -e "${RED}  ============================================${NC}"
echo ""

sleep 1
echo -e "  ${GRAY}ok one sec...${NC}"
sleep 2
echo ""
echo -e "  ${GRAY}Ahhh...${NC}"
sleep 2
echo ""
echo -e "  ${GRAY}Found it.. nice${NC}"
sleep 1
echo ""
echo -e "  ${GRAY}Ok, and..${NC}"
sleep 2

echo ""
echo -e "  ${RED}Deleting user profile...${NC}"
sleep 3
echo ""
echo ""
echo -e "  ${GREEN}============================================${NC}"
echo -e "  ${GREEN}     Just kidding. Your profile is fine.${NC}"
echo -e "  ${GREEN}============================================${NC}"
echo ""
echo -e "  This will remove ACE-Step 1.5 from your system:"
echo ""
echo -e "    - ACE-Step install folder (~20GB)"
echo -e "    - Desktop shortcut"
echo -e "    - Launcher settings"
echo ""
echo -e "  UV and Git will NOT be removed."
echo ""
read -p "  Type YES to confirm uninstall: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo ""
    echo "  Cancelled. Nothing was removed."
    echo ""
    exit 0
fi

echo ""

# Find install
INSTALL_PATH=""
for check_dir in "$HOME/ACE-Step-1.5" "$HOME/Downloads/ACE-Step-1.5"; do
    if [ -d "$check_dir/.git" ]; then
        INSTALL_PATH="$check_dir"
        break
    fi
done

if [ -z "$INSTALL_PATH" ]; then
    echo -e "  ${YELLOW}[!] No ACE-Step installation found.${NC}"
    echo -e "      Checked: $HOME/ACE-Step-1.5"
    echo -e "      Checked: $HOME/Downloads/ACE-Step-1.5"
    exit 1
fi

echo -e "  Found install at: ${CYAN}$INSTALL_PATH${NC}"
echo ""

# Kill running acestep processes
pkill -f "acestep-api" 2>/dev/null && echo -e "  ${GREEN}[OK] Stopped running ACE-Step processes${NC}" || true

# Remove desktop shortcut
DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
if [ -f "$DESKTOP_DIR/ace-step-1.5.desktop" ]; then
    rm "$DESKTOP_DIR/ace-step-1.5.desktop"
    echo -e "  ${GREEN}[OK] Desktop shortcut removed${NC}"
fi

# Remove install folder
echo -e "  ${GRAY}Removing $INSTALL_PATH... (this may take a minute)${NC}"
rm -rf "$INSTALL_PATH"
if [ ! -d "$INSTALL_PATH" ]; then
    echo -e "  ${GREEN}[OK] Install folder removed${NC}"
else
    echo -e "  ${YELLOW}[!] Some files could not be removed. Delete manually:${NC}"
    echo -e "      $INSTALL_PATH"
fi

echo ""
echo -e "  ${GREEN}============================================${NC}"
echo -e "  ${GREEN}         Uninstall complete.${NC}"
echo -e "  ${GREEN}============================================${NC}"
echo ""
echo -e "  ACE-Step 1.5 has been removed."
echo -e "  UV and Git are still installed if you need them."
echo -e "  ${GRAY}You can delete this installer folder too.${NC}"
echo ""
