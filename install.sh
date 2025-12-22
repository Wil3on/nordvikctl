#!/bin/bash

#===============================================================================
# Nordvik Control Installer / Manager
# Usage: curl -sO https://raw.githubusercontent.com/Wil3on/nordvikctl/main/install.sh && sudo bash install.sh
# Or:    curl -s https://raw.githubusercontent.com/Wil3on/nordvikctl/main/install.sh | sudo bash
#===============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
GITHUB_REPO="Wil3on/nordvikctl"
INSTALL_DIR="/srv/nordvik/nordvikctl"
BINARY_NAME="norctl"
SERVICE_NAME="nordvikctl"
WEB_PORT=31777
LOG_FILE="/var/log/nordvik-install.log"

#===============================================================================
# Helper Functions
#===============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_header() {
    clear
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           Nordvik Control Manager                         ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run as root (sudo)${NC}"
        echo "Usage: sudo bash <(curl -s URL)"
        exit 1
    fi
}

detect_os() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    if [ "$OS" != "linux" ]; then
        echo -e "${RED}Error: This installer only supports Linux.${NC}"
        echo "For Windows, please download manually from GitHub releases."
        exit 1
    fi

    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            echo -e "${RED}Error: Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac
}

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="unknown"
    fi
}

get_server_ip() {
    # Try to get the external IP
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 icanhazip.com 2>/dev/null || \
                curl -s --max-time 5 api.ipify.org 2>/dev/null || \
                hostname -I | awk '{print $1}' 2>/dev/null || \
                echo "YOUR_SERVER_IP")
}

get_installed_version() {
    if [ -f "$INSTALL_DIR/$BINARY_NAME" ]; then
        INSTALLED_VERSION=$("$INSTALL_DIR/$BINARY_NAME" --version 2>/dev/null | grep -oP 'v?\d+\.\d+\.\d+' | head -1)
        if [ -z "$INSTALLED_VERSION" ]; then
            INSTALLED_VERSION="unknown"
        fi
    else
        INSTALLED_VERSION=""
    fi
}

get_latest_version() {
    RELEASE_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    RELEASE_INFO=$(curl -s "$RELEASE_URL")
    
    if echo "$RELEASE_INFO" | grep -q "Not Found"; then
        LATEST_VERSION=""
        DOWNLOAD_URL=""
        return 1
    fi

    LATEST_VERSION=$(echo "$RELEASE_INFO" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    DOWNLOAD_URL=$(echo "$RELEASE_INFO" | grep -oP '"browser_download_url":\s*"\K[^"]+linux[^"]+\.tar\.gz' | head -1)
}

check_disk_space() {
    REQUIRED_MB=100
    AVAILABLE_MB=$(df -m "$(dirname "$INSTALL_DIR")" 2>/dev/null | tail -1 | awk '{print $4}')
    
    if [ -n "$AVAILABLE_MB" ] && [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
        echo -e "${RED}Error: Not enough disk space. Required: ${REQUIRED_MB}MB, Available: ${AVAILABLE_MB}MB${NC}"
        return 1
    fi
    return 0
}

is_installed() {
    [ -f "$INSTALL_DIR/$BINARY_NAME" ]
}

#===============================================================================
# Install Dependencies
#===============================================================================

install_dependencies() {
    echo -e "${BLUE}Installing SteamCMD dependencies...${NC}"
    log "Installing SteamCMD dependencies"

    case "$PKG_MANAGER" in
        apt)
            dpkg --add-architecture i386 2>/dev/null || true
            apt-get update -qq
            apt-get install -y -qq lib32gcc-s1 lib32stdc++6 2>/dev/null || \
            apt-get install -y -qq lib32gcc1 lib32stdc++6 2>/dev/null || \
            echo -e "${YELLOW}Warning: Could not install some 32-bit libraries.${NC}"
            echo -e "${GREEN}✅ SteamCMD dependencies installed${NC}"
            ;;
        yum|dnf)
            $PKG_MANAGER install -y -q glibc.i686 libstdc++.i686 2>/dev/null || \
            echo -e "${YELLOW}Warning: Could not install some 32-bit libraries.${NC}"
            echo -e "${GREEN}✅ SteamCMD dependencies installed${NC}"
            ;;
        *)
            echo -e "${YELLOW}Warning: Unknown package manager. Install 32-bit libraries manually.${NC}"
            ;;
    esac
}

#===============================================================================
# Firewall Management
#===============================================================================

open_firewall_ports() {
    local ports="$@"
    echo -e "${BLUE}Opening firewall ports: ${ports}...${NC}"
    log "Opening firewall ports: ${ports}"

    for port in $ports; do
        if command -v ufw &> /dev/null; then
            ufw allow $port/tcp 2>/dev/null || true
        elif command -v firewall-cmd &> /dev/null; then
            firewall-cmd --permanent --add-port=$port/tcp 2>/dev/null || true
        elif command -v iptables &> /dev/null; then
            iptables -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        fi
    done

    # Reload firewall if needed
    if command -v ufw &> /dev/null; then
        echo -e "${GREEN}✅ Ports opened (ufw)${NC}"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --reload 2>/dev/null || true
        echo -e "${GREEN}✅ Ports opened (firewalld)${NC}"
    elif command -v iptables &> /dev/null; then
        iptables-save > /etc/iptables.rules 2>/dev/null || true
        echo -e "${GREEN}✅ Ports opened (iptables)${NC}"
    else
        echo -e "${YELLOW}Warning: No firewall detected.${NC}"
    fi
}

close_firewall_port() {
    echo -e "${BLUE}Closing firewall port $WEB_PORT...${NC}"
    log "Closing firewall port $WEB_PORT"

    if command -v ufw &> /dev/null; then
        ufw delete allow $WEB_PORT/tcp 2>/dev/null || true
        echo -e "${GREEN}✅ Port $WEB_PORT closed (ufw)${NC}"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --remove-port=$WEB_PORT/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        echo -e "${GREEN}✅ Port $WEB_PORT closed (firewalld)${NC}"
    elif command -v iptables &> /dev/null; then
        iptables -D INPUT -p tcp --dport $WEB_PORT -j ACCEPT 2>/dev/null || true
        echo -e "${GREEN}✅ Port $WEB_PORT closed (iptables)${NC}"
    fi
}

#===============================================================================
# Service Management
#===============================================================================

create_service() {
    echo -e "${BLUE}Creating systemd service...${NC}"
    log "Creating systemd service"

    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=Nordvik Control Web UI
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$BINARY_NAME
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME 2>/dev/null || true
    systemctl start $SERVICE_NAME 2>/dev/null || true
    echo -e "${GREEN}✅ Systemd service created and started${NC}"
}

remove_service() {
    echo -e "${BLUE}Removing systemd service...${NC}"
    log "Removing systemd service"

    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload
    echo -e "${GREEN}✅ Systemd service removed${NC}"
}

#===============================================================================
# Install Function
#===============================================================================

do_install() {
    print_header
    echo -e "${CYAN}=== Installing Nordvik Control ===${NC}"
    echo ""
    log "Starting installation"

    # Check if already installed
    if is_installed; then
        echo -e "${YELLOW}Nordvik Control is already installed.${NC}"
        read -p "Do you want to reinstall? (Y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Installation cancelled.${NC}"
            return
        fi
        # Stop service before reinstall
        systemctl stop $SERVICE_NAME 2>/dev/null || true
    fi

    # Check disk space
    if ! check_disk_space; then
        return 1
    fi

    # Ask for port configuration
    echo -e "${CYAN}Port Configuration:${NC}"
    echo ""
    read -p "Panel port [default: 8080]: " PANEL_PORT
    PANEL_PORT=${PANEL_PORT:-8080}
    
    read -p "Daemon port [default: 8081]: " DAEMON_PORT
    DAEMON_PORT=${DAEMON_PORT:-8081}
    
    echo ""
    echo -e "Panel will run on port: ${YELLOW}$PANEL_PORT${NC}"
    echo -e "Daemon will run on port: ${YELLOW}$DAEMON_PORT${NC}"
    echo ""

    # Confirmation
    echo -e "${YELLOW}This will install:${NC}"
    echo "  • nordvikctl to $INSTALL_DIR"
    echo "  • SteamCMD dependencies"
    echo "  • Open firewall ports: $WEB_PORT, $PANEL_PORT, $DAEMON_PORT"
    echo "  • Create systemd service (auto-start)"
    echo ""
    read -p "Continue? (Y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        return
    fi

    echo ""

    # Get latest version
    echo -e "${BLUE}Fetching latest release...${NC}"
    if ! get_latest_version; then
        echo -e "${RED}Error: Could not fetch release info.${NC}"
        return 1
    fi
    echo -e "${GREEN}Latest version: $LATEST_VERSION${NC}"

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}Error: Could not find download URL.${NC}"
        return 1
    fi

    # Install dependencies
    install_dependencies
    echo ""

    # Open firewall
    open_firewall_port
    echo ""

    # Create directory
    echo -e "${BLUE}Creating install directory...${NC}"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/config"

    # Download
    echo -e "${BLUE}Downloading $LATEST_VERSION...${NC}"
    TEMP_DIR=$(mktemp -d)
    TEMP_FILE="$TEMP_DIR/nordvikctl.tar.gz"

    if command -v wget &> /dev/null; then
        wget -q --show-progress -O "$TEMP_FILE" "$DOWNLOAD_URL" 2>&1 || \
        curl -#L "$DOWNLOAD_URL" -o "$TEMP_FILE"
    else
        curl -#L "$DOWNLOAD_URL" -o "$TEMP_FILE"
    fi

    # Extract
    echo -e "${BLUE}Extracting...${NC}"
    tar -xzf "$TEMP_FILE" -C "$INSTALL_DIR"
    rm -rf "$TEMP_DIR"

    # Make executable
    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    # Create symlink
    ln -sf "$INSTALL_DIR/$BINARY_NAME" /usr/local/bin/norctl
    echo -e "${GREEN}✅ Created symlink: /usr/local/bin/norctl${NC}"
    echo ""

    # Save port configuration
    echo -e "${BLUE}Saving port configuration...${NC}"
    cat > "$INSTALL_DIR/config/ports.conf" << EOF
# Nordvik Port Configuration
PANEL_PORT=$PANEL_PORT
DAEMON_PORT=$DAEMON_PORT
WEB_PORT=$WEB_PORT
EOF
    echo -e "${GREEN}✅ Port configuration saved${NC}"
    echo ""

    # Open firewall ports
    open_firewall_ports $WEB_PORT $PANEL_PORT $DAEMON_PORT
    echo ""

    # Create service
    create_service
    echo ""

    # Get server IP
    get_server_ip

    # Success message
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Installation Complete!                          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Version:  ${YELLOW}$LATEST_VERSION${NC}"
    echo -e "Location: ${YELLOW}$INSTALL_DIR${NC}"
    echo ""
    echo -e "${CYAN}Installed:${NC}"
    echo "  ✅ nordvikctl binary"
    echo "  ✅ SteamCMD dependencies"
    echo "  ✅ Firewall ports: $WEB_PORT, $PANEL_PORT, $DAEMON_PORT"
    echo "  ✅ Systemd service (auto-start)"
    echo ""
    echo -e "${BLUE}Port Configuration:${NC}"
    echo -e "  Web UI:    ${YELLOW}http://$SERVER_IP:$WEB_PORT${NC}"
    echo -e "  Panel:     ${YELLOW}$PANEL_PORT${NC}"
    echo -e "  Daemon:    ${YELLOW}$DAEMON_PORT${NC}"
    echo ""
    echo -e "${BLUE}Service commands:${NC}"
    echo "  systemctl status $SERVICE_NAME"
    echo "  systemctl restart $SERVICE_NAME"
    echo "  journalctl -u $SERVICE_NAME -f"
    echo ""
    log "Installation completed successfully"
}

#===============================================================================
# Update Function
#===============================================================================

do_update() {
    print_header
    echo -e "${CYAN}=== Updating Nordvik Control ===${NC}"
    echo ""
    log "Starting update"

    if ! is_installed; then
        echo -e "${RED}Nordvik Control is not installed.${NC}"
        echo "Please install first."
        return 1
    fi

    # Get versions
    get_installed_version
    echo -e "Current version: ${YELLOW}$INSTALLED_VERSION${NC}"
    
    echo -e "${BLUE}Checking for updates...${NC}"
    if ! get_latest_version; then
        echo -e "${RED}Error: Could not fetch release info.${NC}"
        return 1
    fi
    echo -e "Latest version:  ${GREEN}$LATEST_VERSION${NC}"
    echo ""

    # Compare versions
    if [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
        echo -e "${GREEN}You already have the latest version!${NC}"
        return 0
    fi

    # Backup config
    echo -e "${BLUE}Backing up configuration...${NC}"
    if [ -d "$INSTALL_DIR/config" ]; then
        cp -r "$INSTALL_DIR/config" "$INSTALL_DIR/config.backup" 2>/dev/null || true
        echo -e "${GREEN}✅ Config backed up${NC}"
    fi

    # Confirmation
    read -p "Update to $LATEST_VERSION? (Y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Update cancelled.${NC}"
        return
    fi

    # Stop service
    echo -e "${BLUE}Stopping service...${NC}"
    systemctl stop $SERVICE_NAME 2>/dev/null || true

    # Download
    echo -e "${BLUE}Downloading $LATEST_VERSION...${NC}"
    TEMP_DIR=$(mktemp -d)
    TEMP_FILE="$TEMP_DIR/nordvikctl.tar.gz"
    curl -#L "$DOWNLOAD_URL" -o "$TEMP_FILE"

    # Extract (preserve config)
    echo -e "${BLUE}Extracting...${NC}"
    tar -xzf "$TEMP_FILE" -C "$INSTALL_DIR"
    rm -rf "$TEMP_DIR"

    # Restore config
    if [ -d "$INSTALL_DIR/config.backup" ]; then
        cp -r "$INSTALL_DIR/config.backup"/* "$INSTALL_DIR/config/" 2>/dev/null || true
        rm -rf "$INSTALL_DIR/config.backup"
        echo -e "${GREEN}✅ Config restored${NC}"
    fi

    # Make executable
    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    # Restart service
    echo -e "${BLUE}Restarting service...${NC}"
    systemctl start $SERVICE_NAME
    echo -e "${GREEN}✅ Service restarted${NC}"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Update Complete!                                ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Updated to: ${YELLOW}$LATEST_VERSION${NC}"
    echo ""
    log "Update completed successfully to $LATEST_VERSION"
}

#===============================================================================
# Uninstall Function
#===============================================================================

do_uninstall() {
    print_header
    echo -e "${CYAN}=== Uninstalling Nordvik Control ===${NC}"
    echo ""
    log "Starting uninstall"

    if ! is_installed; then
        echo -e "${YELLOW}Nordvik Control is not installed.${NC}"
        return 0
    fi

    echo -e "${RED}WARNING: This will remove:${NC}"
    echo "  • nordvikctl binary and config"
    echo "  • Systemd service"
    echo "  • Firewall rules for port $WEB_PORT"
    echo ""
    echo -e "${YELLOW}Your authentication config will be deleted!${NC}"
    echo ""

    read -p "Are you sure? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Uninstall cancelled.${NC}"
        return
    fi

    echo ""

    # Remove service
    remove_service
    echo ""

    # Close firewall port
    close_firewall_port
    echo ""

    # Remove symlink
    rm -f /usr/local/bin/norctl
    echo -e "${GREEN}✅ Symlink removed${NC}"

    # Remove install directory
    echo -e "${BLUE}Removing files...${NC}"
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}✅ Files removed${NC}"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Uninstall Complete!                             ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log "Uninstall completed successfully"
}

#===============================================================================
# Version Check Function
#===============================================================================

do_version_check() {
    print_header
    echo -e "${CYAN}=== Version Check ===${NC}"
    echo ""

    # Get installed version
    get_installed_version
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "Installed: ${RED}Not installed${NC}"
    else
        echo -e "Installed: ${YELLOW}$INSTALLED_VERSION${NC}"
    fi

    # Get latest version
    echo -e "${BLUE}Checking GitHub for latest version...${NC}"
    if get_latest_version; then
        echo -e "Latest:    ${GREEN}$LATEST_VERSION${NC}"
        echo ""

        if [ -z "$INSTALLED_VERSION" ]; then
            echo -e "${YELLOW}Nordvik Control is not installed.${NC}"
            echo "Select option 1 to install."
        elif [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
            echo -e "${GREEN}✅ You have the latest version!${NC}"
        else
            echo -e "${YELLOW}⚠️  Update available!${NC}"
            echo "Select option 2 to update."
        fi
    else
        echo -e "Latest:    ${RED}Could not fetch${NC}"
    fi

    # Service status
    echo ""
    if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
        echo -e "Service:   ${GREEN}Running${NC}"
    elif systemctl is-enabled --quiet $SERVICE_NAME 2>/dev/null; then
        echo -e "Service:   ${YELLOW}Stopped${NC}"
    else
        echo -e "Service:   ${RED}Not installed${NC}"
    fi

    echo ""
}

#===============================================================================
# Main Menu
#===============================================================================

show_menu() {
    print_header
    
    detect_os
    detect_package_manager

    echo -e "${CYAN}System: Linux $ARCH | Package Manager: $PKG_MANAGER${NC}"
    echo ""

    # Quick status
    get_installed_version
    if [ -n "$INSTALLED_VERSION" ]; then
        echo -e "Status: ${GREEN}Installed${NC} (v$INSTALLED_VERSION)"
    else
        echo -e "Status: ${YELLOW}Not installed${NC}"
    fi
    echo ""

    echo -e "${YELLOW}Select an option:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Install Nordvikctl"
    echo -e "  ${BLUE}2)${NC} Update Nordvikctl"
    echo -e "  ${RED}3)${NC} Uninstall Nordvikctl"
    echo -e "  ${CYAN}4)${NC} Check Version"
    echo -e "  ${MAGENTA}0)${NC} Exit"
    echo ""
    read -p "Enter option [0-4]: " choice

    case $choice in
        1) do_install ;;
        2) do_update ;;
        3) do_uninstall ;;
        4) do_version_check ;;
        0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac

    echo ""
    read -p "Press Enter to continue..."
    show_menu
}

#===============================================================================
# Entry Point
#===============================================================================

check_root
mkdir -p "$(dirname "$LOG_FILE")"
log "=== Nordvik Control Manager started ==="
show_menu
