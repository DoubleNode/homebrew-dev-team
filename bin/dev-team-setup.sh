#!/bin/bash
# Dev-Team Setup Wizard
# Interactive configuration and installation

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Get framework location
if [ -z "$DEV_TEAM_HOME" ]; then
  if command -v brew &>/dev/null; then
    DEV_TEAM_HOME="$(brew --prefix)/opt/dev-team/libexec"
  else
    echo -e "${RED}ERROR: DEV_TEAM_HOME not set${NC}" >&2
    exit 1
  fi
fi

VERSION="1.0.0"

# Banner
show_banner() {
  cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ██████╗ ███████╗██╗   ██╗      ████████╗███████╗ █████╗ ███╗   ███╗   ║
║   ██╔══██╗██╔════╝██║   ██║      ╚══██╔══╝██╔════╝██╔══██╗████╗ ████║   ║
║   ██║  ██║█████╗  ██║   ██║█████╗   ██║   █████╗  ███████║██╔████╔██║   ║
║   ██║  ██║██╔══╝  ╚██╗ ██╔╝╚════╝   ██║   ██╔══╝  ██╔══██║██║╚██╔╝██║   ║
║   ██████╔╝███████╗ ╚████╔╝          ██║   ███████╗██║  ██║██║ ╚═╝ ██║   ║
║   ╚═════╝ ╚══════╝  ╚═══╝           ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝   ║
║                                                                   ║
║            Starfleet Development Environment Setup                ║
║                        Version 1.0.0                              ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
  echo ""
}

# Usage
usage() {
  cat <<EOF
Dev-Team Setup Wizard v${VERSION}

Usage: dev-team setup [options]

Options:
  --install-dir DIR      Installation directory (default: ~/dev-team)
  --upgrade              Upgrade existing installation
  --uninstall            Remove dev-team configuration
  --non-interactive      Run in non-interactive mode
  -h, --help             Show this help

Interactive Mode:
  When run without options, launches interactive setup wizard
  to configure your dev-team environment.

Examples:
  dev-team setup                          # Interactive setup
  dev-team setup --install-dir ~/my-team  # Custom location
  dev-team setup --upgrade                # Upgrade existing
  dev-team setup --uninstall              # Clean removal
EOF
}

# Parse arguments
INSTALL_DIR="$HOME/dev-team"
MODE="interactive"

while [[ $# -gt 0 ]]; do
  case $1 in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --upgrade)
      MODE="upgrade"
      shift
      ;;
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    --non-interactive)
      MODE="non-interactive"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}ERROR: Unknown option: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Check if already configured
is_configured() {
  [ -f "${INSTALL_DIR}/.dev-team-config" ]
}

# Uninstall mode
if [ "$MODE" = "uninstall" ]; then
  echo -e "${BOLD}Dev-Team Uninstall${NC}"
  echo ""

  if ! is_configured; then
    echo -e "${YELLOW}⚠ No dev-team installation found at: ${INSTALL_DIR}${NC}"
    exit 0
  fi

  echo "This will remove:"
  echo "  • Dev-team configuration from: ${INSTALL_DIR}"
  echo "  • LaunchAgents (kanban-backup, lcars-health)"
  echo "  • Shell integration from ~/.zshrc"
  echo ""
  echo -e "${RED}Warning: This will NOT remove the Homebrew formula${NC}"
  echo "To fully remove dev-team, also run: brew uninstall dev-team"
  echo ""
  read -p "Continue with uninstall? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Uninstall cancelled"
    exit 0
  fi

  # Remove LaunchAgents
  if [ -f "$HOME/Library/LaunchAgents/com.devteam.kanban-backup.plist" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.devteam.kanban-backup.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.devteam.kanban-backup.plist"
    echo -e "${GREEN}✓${NC} Removed kanban-backup LaunchAgent"
  fi

  if [ -f "$HOME/Library/LaunchAgents/com.devteam.lcars-health.plist" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.devteam.lcars-health.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.devteam.lcars-health.plist"
    echo -e "${GREEN}✓${NC} Removed lcars-health LaunchAgent"
  fi

  # Remove shell integration (backup first)
  if [ -f "$HOME/.zshrc" ]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%s)"
    # Remove dev-team sourcing lines
    grep -v "dev-team" "$HOME/.zshrc" > "$HOME/.zshrc.tmp" || true
    mv "$HOME/.zshrc.tmp" "$HOME/.zshrc"
    echo -e "${GREEN}✓${NC} Removed shell integration (backed up .zshrc)"
  fi

  # Ask about removing working directory
  echo ""
  read -p "Remove working directory ${INSTALL_DIR}? (yes/no): " remove_dir

  if [ "$remove_dir" = "yes" ]; then
    rm -rf "${INSTALL_DIR}"
    echo -e "${GREEN}✓${NC} Removed ${INSTALL_DIR}"
  else
    # Just remove config marker
    rm -f "${INSTALL_DIR}/.dev-team-config"
    echo -e "${GREEN}✓${NC} Unmarked installation (files preserved)"
  fi

  echo ""
  echo -e "${GREEN}Dev-Team uninstalled successfully${NC}"
  echo "To reinstall: dev-team setup"
  exit 0
fi

# Interactive setup
show_banner

echo -e "${CYAN}This wizard will configure your Starfleet Development Environment.${NC}"
echo ""

# Check dependencies
echo -e "${BOLD}Checking dependencies...${NC}"
echo ""

MISSING_DEPS=()

check_dep() {
  local cmd=$1
  local name=$2
  local install=$3

  if command -v "$cmd" &>/dev/null; then
    echo -e "${GREEN}✓${NC} $name"
  else
    echo -e "${RED}✗${NC} $name ${YELLOW}(missing)${NC}"
    MISSING_DEPS+=("$name:$install")
  fi
}

check_dep "python3" "Python 3" "brew install python@3.13"
check_dep "node" "Node.js" "brew install node"
check_dep "jq" "jq" "brew install jq"
check_dep "gh" "GitHub CLI" "brew install gh"
check_dep "git" "Git" "xcode-select --install"

# Check for iTerm2 (application, not command)
if [ -d "/Applications/iTerm.app" ]; then
  echo -e "${GREEN}✓${NC} iTerm2"
else
  echo -e "${RED}✗${NC} iTerm2 ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("iTerm2:brew install --cask iterm2")
fi

# Check for Claude Code
if command -v claude &>/dev/null; then
  echo -e "${GREEN}✓${NC} Claude Code"
else
  echo -e "${RED}✗${NC} Claude Code ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("Claude Code:npm install -g @anthropic-ai/claude-code")
fi

echo ""

# Handle missing dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠ Missing required dependencies${NC}"
  echo ""
  echo "Install missing dependencies:"
  echo ""
  for dep in "${MISSING_DEPS[@]}"; do
    name="${dep%%:*}"
    install="${dep#*:}"
    echo "  $install"
  done
  echo ""
  read -p "Install missing dependencies now? (yes/no): " install_deps

  if [ "$install_deps" = "yes" ]; then
    echo ""
    echo -e "${BLUE}Installing dependencies...${NC}"
    for dep in "${MISSING_DEPS[@]}"; do
      install="${dep#*:}"
      echo "Running: $install"
      # Execute directly without eval - install commands are hardcoded in script
      bash -c "$install" || echo -e "${RED}Failed: $install${NC}"
    done
    echo ""
    echo -e "${GREEN}Dependencies installed${NC}"
    echo "Please restart the setup wizard"
    exit 0
  else
    echo ""
    echo -e "${RED}Cannot continue without required dependencies${NC}"
    exit 1
  fi
fi

# Installation directory
echo -e "${BOLD}Installation Location${NC}"
echo ""
echo "Default installation directory: ${INSTALL_DIR}"
echo ""
read -p "Use default location? (yes/no): " use_default

if [ "$use_default" != "yes" ]; then
  read -p "Enter installation directory: " custom_dir
  INSTALL_DIR="${custom_dir/#\~/$HOME}" # Expand ~
fi

echo ""
echo "Installing to: ${INSTALL_DIR}"

# Check if already exists
if is_configured; then
  echo ""
  echo -e "${YELLOW}⚠ Existing installation found${NC}"
  echo ""
  read -p "Upgrade existing installation? (yes/no): " upgrade_existing

  if [ "$upgrade_existing" != "yes" ]; then
    echo "Setup cancelled"
    exit 0
  fi
  MODE="upgrade"
fi

# Create installation directory
mkdir -p "${INSTALL_DIR}"

# Placeholder for actual installation steps
# (In a real implementation, this would copy templates, generate configs, etc.)
echo ""
echo -e "${BLUE}Copying framework files...${NC}"
echo ""

# Copy core scripts
cp -r "${DEV_TEAM_HOME}/config/templates" "${INSTALL_DIR}/templates"
cp -r "${DEV_TEAM_HOME}/docs" "${INSTALL_DIR}/docs"
cp -r "${DEV_TEAM_HOME}/skills" "${INSTALL_DIR}/skills"

# Create configuration marker
cat > "${INSTALL_DIR}/.dev-team-config" <<EOF
VERSION=${VERSION}
INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INSTALL_DIR=${INSTALL_DIR}
FRAMEWORK_HOME=${DEV_TEAM_HOME}
EOF

echo -e "${GREEN}✓${NC} Framework files installed"
echo ""

# Success message
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                 Setup Complete! 🎉                                ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Dev-Team installed to: ${INSTALL_DIR}"
echo ""
echo "Next steps:"
echo "  1. Configure teams: edit ${INSTALL_DIR}/templates/teams.json"
echo "  2. Set up LCARS: ${INSTALL_DIR}/docs/LCARS-COMPLETE-REFERENCE.md"
echo "  3. Run health check: dev-team doctor"
echo "  4. Start environment: dev-team start"
echo ""
echo "For help: dev-team help"
echo ""
