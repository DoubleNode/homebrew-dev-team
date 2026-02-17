# Dev-Team Homebrew Tap

![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-blue)
![Version](https://img.shields.io/badge/version-1.0.0-green)
![macOS](https://img.shields.io/badge/macOS-Big_Sur+-blue)

**Starfleet Development Environment** - AI-powered multi-team development infrastructure

> This Homebrew tap provides the `dev-team` formula for installing and managing the Dev-Team environment on macOS - a comprehensive AI-assisted development platform with specialized teams, visual kanban management, and multi-machine coordination.

## What is Dev-Team?

Dev-Team is a comprehensive development environment designed for AI-assisted development with multiple specialized teams.

### Key Features

#### 🎯 Multi-Team Architecture
Separate teams (iOS, Android, Firebase, etc.) with distinct AI agents, kanban boards, and workflows.

```bash
dev-team start ios      # Start iOS team
ios-picard              # Launch Captain Picard agent
kb-list                 # View iOS kanban board
```

#### 🖥️ LCARS Kanban System
Star Trek-inspired visual kanban board with real-time updates and automatic agent tracking.

```bash
kb-add "New feature"            # Add kanban item
kb-move XIOS-0042 in_progress   # Move to in progress
kb-run XIOS-0042                # Create worktree and start work
```

**Access in browser:** http://localhost:8082

#### 🤖 Claude Code Integration
AI pair programming with team-specific personas that auto-track work in kanban.

```bash
ios-picard      # Lead Feature Developer
ios-beverly     # Bugfix Specialist
ios-data        # Testing & QA
```

Each agent has a unique personality and specialization based on Star Trek characters.

#### 🔄 Git Worktree Management
Advanced git workflow automation for parallel development.

```bash
wt-create feature/new-ui    # Create worktree
wt-list                     # List worktrees
wt-remove feature/new-ui    # Clean up after merge
```

#### 🌐 Fleet Monitor
Multi-machine coordination for distributed development across multiple Macs.

```bash
# View all machines, agents, and kanban state
open http://localhost:3000
```

#### 💻 Terminal Automation
iTerm2 integration with automated window/tab management (optional).

```bash
dev-team start ios
# Automatically opens terminals, configures environments
```

## Quick Start

Get up and running in under 5 minutes:

```bash
# 1. Add tap and install
brew tap DoubleNode/dev-team
brew install dev-team

# 2. Run interactive setup wizard
dev-team setup

# 3. Verify installation
dev-team doctor

# 4. Start your environment
dev-team start ios
```

**That's it!** Your AI-powered development environment is ready.

## Installation

### Prerequisites

- **macOS Big Sur (11.0) or later**
- **Homebrew** - [Install here](https://brew.sh) if you don't have it

### Step-by-Step Installation

**Step 1: Add the Dev-Team tap**
```bash
brew tap DoubleNode/dev-team
```

**Step 2: Install Dev-Team**
```bash
brew install dev-team
```

This installs the framework and required dependencies (Python 3, Node.js, jq, GitHub CLI, Git).

**Step 3: Run the Setup Wizard**
```bash
dev-team setup
```

The interactive wizard guides you through:
1. ✓ Checking dependencies
2. ✓ Installing missing tools (if needed)
3. ✓ Selecting teams (iOS, Android, Firebase, etc.)
4. ✓ Configuring features (LCARS Kanban, Fleet Monitor, etc.)
5. ✓ Setting up shell environment
6. ✓ Installing system services

**Typical setup time: 5-10 minutes** (depending on how many dependencies need installation).

**Step 4: Restart Your Terminal**
```bash
source ~/.zshrc
```

**Step 5: Verify Everything Works**
```bash
dev-team doctor
```

## Usage

### Main Commands

```bash
dev-team setup      # Run interactive setup wizard
dev-team doctor     # Health check and diagnostics
dev-team status     # Show current environment status
dev-team start      # Start dev-team environment
dev-team stop       # Stop dev-team environment
dev-team upgrade    # Upgrade components
dev-team help       # Show help information
```

### Example Usage

**For iOS Development:**
```bash
# Install and select iOS team
dev-team setup  # Choose "iOS Development"

# Start iOS environment
dev-team start ios

# Use iOS agents
ios-picard      # Captain Picard - Lead Feature Developer
ios-beverly     # Dr. Crusher - Bugfix Specialist

# Manage tasks
kb-list         # List kanban items
kb-add "New feature"
```

**For Multi-Platform Development:**
```bash
# Install iOS, Android, and Firebase teams
dev-team setup  # Choose multiple teams

# Start all teams
dev-team start

# Each team has its own kanban board and agents
```

**For Multi-Machine Setup:**
```bash
# On main machine (server)
dev-team setup  # Enable "Fleet Monitor" as server

# On secondary machines (clients)
dev-team setup  # Enable "Fleet Monitor" as client

# Monitor entire fleet
open http://localhost:3000
```

## Requirements

### Required Dependencies
- **macOS** Big Sur or later
- **Homebrew** package manager
- **Python 3** (3.8 or later)
- **Node.js** (18.0 or later)
- **jq** JSON processor
- **Git** version control
- **GitHub CLI** (`gh`)
- **iTerm2** terminal emulator
- **Claude Code** AI pair programmer

The setup wizard will check for and offer to install missing dependencies.

### Optional Dependencies
- **Tailscale** - For multi-machine coordination
- **ImageMagick** - For avatar/image processing
- **tmux** - For Fleet Monitor

## Architecture

### Installation Locations

**Framework** (Homebrew-managed):
```
$(brew --prefix)/opt/dev-team/libexec/
├── bin/                    # Core executables
├── scripts/                # Automation scripts
├── config/templates/       # Configuration templates
├── docs/                   # Documentation
├── skills/                 # Claude Code skills
├── lcars-ui/              # LCARS Kanban UI
├── kanban-hooks/          # Kanban automation
└── ...
```

**Working Directory** (user-managed):
```
~/dev-team/                 # Default location
├── templates/              # Copied from framework
├── docs/                   # Copied from framework
├── skills/                 # Copied from framework
├── kanban/                 # Kanban board data
├── teams/                  # Team configurations
├── scripts/                # Generated scripts
└── .dev-team-config        # Installation metadata
```

### Two-Layer Design

1. **Framework Layer** (`$(brew --prefix)/opt/dev-team/libexec/`)
   - Installed via Homebrew
   - Read-only template files
   - Upgraded via `brew upgrade dev-team`

2. **Working Layer** (`~/dev-team` or custom location)
   - Created by `dev-team setup`
   - User-specific configuration
   - Kanban data, team configs, generated scripts
   - Preserved across framework upgrades

## Components

### LCARS Kanban System
Web-based kanban board with Star Trek LCARS interface:
- Real-time board updates
- Multi-team support
- Agent status tracking
- Calendar integration
- Health monitoring

### Team Directories
Pre-configured teams with personas:
- **Academy** - Infrastructure and tooling
- **iOS** - iOS app development
- **Android** - Android app development
- **Firebase** - Backend/cloud functions
- **Command** - Strategic planning
- **DNS** - DNS framework
- **Freelance** - Client projects
- **Legal** - Legal/compliance
- **MainEvent** - Cross-platform coordination
- **Medical** - Health/diagnostics

### Claude Code Integration
AI agents with team-specific personas:
- Automated kanban tracking
- Session management
- Tool use hooks
- Custom skills and workflows

### Fleet Monitor
Multi-machine coordination (optional):
- Monitor multiple dev-team installations
- Centralized kanban aggregation
- Cross-machine agent status
- Tailscale integration

## Configuration

### Customize Installation Location

```bash
dev-team setup --install-dir ~/my-custom-location
```

### Upgrade Existing Installation

```bash
# Upgrade framework
brew upgrade dev-team

# Upgrade working directory
dev-team setup --upgrade
```

### Uninstall

```bash
# Remove configuration (keeps framework)
dev-team setup --uninstall

# Remove framework
brew uninstall dev-team
```

## Troubleshooting

### Health Check

```bash
dev-team doctor
```

Checks:
- External dependencies
- Framework installation
- Configuration files
- Running services
- File permissions

### Verbose Diagnostics

```bash
dev-team doctor --verbose
```

### Check Specific Component

```bash
dev-team doctor --check dependencies
dev-team doctor --check services
dev-team doctor --check config
```

### Common Issues

**LCARS server not starting**
```bash
# Check port 8082 availability
lsof -i :8082

# Start manually
cd ~/dev-team/lcars-ui
python3 server.py
```

**Claude Code not authenticated**
```bash
claude auth login
```

**GitHub CLI not authenticated**
```bash
gh auth login
```

**Missing dependencies**
```bash
dev-team doctor
# Follow install instructions for missing deps
```

## Documentation

Comprehensive documentation is available in the `docs/` directory:

### Getting Started
- **[Quick Start](docs/QUICK_START.md)** - Get up and running in 5 minutes
- **[Installation Guide](docs/INSTALLATION.md)** - Complete installation instructions
- **[User Guide](docs/USER_GUIDE.md)** - Day-to-day usage and commands

### Advanced Topics
- **[Multi-Machine Setup](docs/MULTI_MACHINE.md)** - Fleet Monitor and multi-machine coordination
- **[Architecture](docs/ARCHITECTURE.md)** - Technical architecture and design
- **[Team Reference](docs/TEAM_REFERENCE.md)** - Complete team and agent reference

### Support
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** - Problem solving guide
- **[Contributing](CONTRIBUTING.md)** - How to contribute to dev-team

### Quick Reference

**After installation, docs are also available locally:**
```bash
ls ~/dev-team/docs/
cat ~/dev-team/docs/QUICK_START.md
```

## FAQ

### What is Dev-Team?

Dev-Team is a comprehensive macOS development environment that combines:
- **AI pair programming** with Claude Code agents
- **Visual task management** with LCARS Kanban
- **Multi-machine coordination** with Fleet Monitor
- **Terminal automation** with iTerm2 integration

### Do I need Claude Code?

No, it's optional. Dev-Team works standalone, but Claude Code integration provides AI-assisted development with automatic kanban tracking.

### Can I use this for team development?

Yes! Dev-Team supports both solo and team development. Fleet Monitor enables multi-machine coordination perfect for distributed teams.

### What teams are available?

Dev-Team includes 10 pre-configured teams:
- **Platform:** iOS, Android, Firebase
- **Infrastructure:** Academy, DNS Framework
- **Project-Based:** Freelance
- **Coordination:** MainEvent
- **Strategic:** Command, Legal, Medical

See [Team Reference](docs/TEAM_REFERENCE.md) for details.

### Can I add custom teams?

Yes! Teams are defined in data files, so you can add custom teams without modifying code. See [ADDING_A_TEAM](docs/ADDING_A_TEAM.md).

### How much disk space does it need?

- **Framework:** ~100 MB
- **Working directory:** ~500 MB (excluding your kanban data and worktrees)
- **Full installation:** 2-5 GB depending on how many teams you install

### Is my data safe during upgrades?

Yes! The two-layer architecture separates the framework (Homebrew-managed) from your working directory (user-managed). Upgrades never touch your kanban data or configurations.

### How do I uninstall?

```bash
dev-team uninstall     # Remove configuration
brew uninstall dev-team
brew untap DoubleNode/dev-team
```

Your `~/dev-team/` directory is preserved. Delete it manually if desired.

### What if something breaks?

Run `dev-team doctor` for diagnostics. See [Troubleshooting](docs/TROUBLESHOOTING.md) for common issues and solutions.

## Development

### Formula Development

```bash
# Clone this tap
brew tap DoubleNode/dev-team
cd $(brew --repository DoubleNode/dev-team)

# Edit formula
vim Formula/dev-team.rb

# Test formula
brew install --build-from-source dev-team
brew test dev-team
```

### Testing

```bash
# Run formula tests
brew test dev-team

# Manual testing
dev-team doctor --verbose
```

## License

MIT License - See formula for details

## Support

- **Issues**: https://github.com/DoubleNode/dev-team/issues
- **Documentation**: `~/dev-team/docs/`
- **Health Check**: `dev-team doctor`

## Version

Current version: **1.0.0**

**Development Status:** Phase 3 Complete (Interactive Setup Wizard)
- ✅ Setup wizard implemented
- ✅ LCARS-styled UI library
- 🚧 Installer modules (Phases 4-8 in progress)

```bash
dev-team --version
```
