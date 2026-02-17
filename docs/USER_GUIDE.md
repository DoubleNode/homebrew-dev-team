# User Guide

**Day-to-day usage of the Dev-Team environment**

---

## Table of Contents

- [Overview](#overview)
- [Main Commands](#main-commands)
- [Working with Teams](#working-with-teams)
- [LCARS Kanban System](#lcars-kanban-system)
- [Claude Code Agents](#claude-code-agents)
- [Git Worktrees](#git-worktrees)
- [Shell Aliases and Shortcuts](#shell-aliases-and-shortcuts)
- [Managing Services](#managing-services)
- [Upgrading and Maintenance](#upgrading-and-maintenance)

---

## Overview

Dev-Team provides a comprehensive development environment with:
- **Multiple specialized teams** (iOS, Android, Firebase, etc.)
- **LCARS Kanban system** for visual task management
- **Claude Code integration** with team-specific AI agents
- **Git worktree automation** for parallel development
- **Terminal automation** with iTerm2 integration
- **Fleet Monitor** for multi-machine coordination

---

## Main Commands

### Core Commands

```bash
dev-team setup      # Run interactive setup wizard
dev-team doctor     # Health check and diagnostics
dev-team status     # Show current environment status
dev-team start      # Start dev-team services
dev-team stop       # Stop dev-team services
dev-team restart    # Restart dev-team services
dev-team upgrade    # Upgrade dev-team components
dev-team uninstall  # Remove dev-team environment
dev-team version    # Show version information
dev-team help       # Show help message
```

### Command Details

#### dev-team setup

Run the interactive setup wizard to configure dev-team.

```bash
# Interactive setup
dev-team setup

# Non-interactive (uses existing config or defaults)
dev-team setup --non-interactive

# Preview changes without applying
dev-team setup --dry-run

# Install to custom directory
dev-team setup --install-dir /opt/dev-team
```

**Use cases:**
- Initial installation
- Adding new teams
- Enabling new features
- Reconfiguring existing setup

#### dev-team doctor

Run comprehensive health checks and diagnostics.

```bash
# Standard health check
dev-team doctor

# Verbose diagnostics
dev-team doctor --verbose

# Check specific component
dev-team doctor --check dependencies
dev-team doctor --check services
dev-team doctor --check config

# Attempt automatic fixes (future feature)
dev-team doctor --fix
```

**What it checks:**
- External dependencies (Python, Node, jq, gh, etc.)
- Framework installation
- Configuration files
- Running services (LCARS, Fleet Monitor)
- File permissions

#### dev-team status

Show current environment status.

```bash
# Full status
dev-team status

# JSON output
dev-team status --json

# Brief status
dev-team status --brief
```

**Displays:**
- Installed teams
- Running services
- Active terminals
- Current kanban status
- Fleet Monitor status (if enabled)

#### dev-team start/stop/restart

Control dev-team services and environments.

```bash
# Start all teams
dev-team start

# Start specific team
dev-team start ios
dev-team start android
dev-team start firebase

# Stop all services
dev-team stop

# Stop specific team
dev-team stop ios

# Restart everything
dev-team restart

# Restart specific service
dev-team restart lcars
dev-team restart fleet-monitor
```

---

## Working with Teams

### Available Teams

| Team | Purpose | Category |
|------|---------|----------|
| **ios** | iOS app development with Swift | Platform |
| **android** | Android app development with Kotlin | Platform |
| **firebase** | Firebase backend and cloud functions | Platform |
| **academy** | Dev-team infrastructure and tooling | Infrastructure |
| **dns** | DNS framework development | Infrastructure |
| **freelance** | Full-stack freelance projects | Project-Based |
| **mainevent** | Cross-platform coordination | Coordination |
| **command** | Strategic planning | Strategic |
| **legal** | Legal research and documentation | Strategic |
| **medical** | Medical documentation | Strategic |

### Selecting Teams

Teams are selected during initial setup via `dev-team setup`. You can add or remove teams by re-running the wizard.

```bash
# Add new teams
dev-team setup  # Re-run wizard, select additional teams
```

### Starting a Team Environment

Each team has its own startup script that configures the environment.

```bash
# Start iOS team
dev-team start ios

# Start multiple teams
dev-team start ios firebase
```

**What happens on team start:**
- Opens iTerm2 windows/tabs (if iTerm2 integration enabled)
- Loads team-specific shell configurations
- Starts team-specific services
- Initializes kanban board state
- Configures terminal badges and themes

### Switching Between Teams

```bash
# Use team-specific aliases (see Shell Aliases section)
# Each team has its own set of commands
```

### Team Directory Structure

Each team has a directory in `~/dev-team/`:

```
~/dev-team/<team-id>/
├── personas/
│   ├── agents/          # Agent persona markdown files
│   ├── avatars/         # Agent avatar images
│   └── docs/            # Team-specific documentation
├── scripts/             # Team-specific scripts
└── terminals/           # Terminal configurations
```

---

## LCARS Kanban System

The LCARS (Library Computer Access/Retrieval System) Kanban provides a Star Trek-styled visual task management interface.

### Accessing LCARS

Open in your browser:
```
http://localhost:8082
```

**Default port:** 8082 (configurable via `~/dev-team/config.json`)

### Kanban Commands

#### Shell Functions

```bash
# List kanban items
kb-list                  # List all items
kb-list ios              # List items for iOS team
kb-list --status backlog # List items in backlog

# Add new item
kb-add "Task description"
kb-add "Task" --team ios

# Update item
kb-update XIOS-0001 --status in_progress
kb-update XIOS-0001 --assignee picard

# Move item between states
kb-move XIOS-0001 in_progress
kb-move XIOS-0001 done

# Show item details
kb-show XIOS-0001

# Delete item (sets status to cancelled)
kb-cancel XIOS-0001

# Kanban status summary
kb-status
kb-status ios            # Status for specific team
```

#### Kanban States

Items progress through these states:

1. **Backlog** - Not yet started
2. **In Progress** - Actively being worked on
3. **In Review** - Awaiting code review
4. **Testing** - In QA testing
5. **Done** - Completed
6. **Cancelled** - Cancelled or deprecated

#### Working with Subitems

```bash
# Add subitem to an item
kb-sub add XIOS-0001 "Subtask description"

# List subitems
kb-sub list XIOS-0001

# Update subitem
kb-sub update XIOS-0001-001 --status done

# Start working on subitem
kb-sub start XIOS-0001-001

# Mark subitem done
kb-sub done XIOS-0001-001
```

### Kanban Backup System

Kanban boards are automatically backed up hourly.

```bash
# View backups
ls ~/dev-team/kanban-backups/

# Restore from backup
cp ~/dev-team/kanban-backups/ios-board-20260217-1400.json \
   ~/dev-team/kanban/ios-board.json
```

**Backup schedule:** Every hour (via LaunchAgent)
**Retention:** 7 days of hourly backups

---

## Claude Code Agents

If you installed Claude Code integration, you have team-specific AI agents configured.

### Agent Personas

Each team has multiple agent personas with distinct specializations:

#### iOS Team Agents
```bash
ios-picard      # Captain Picard - Lead Feature Developer
ios-beverly     # Dr. Crusher - Bugfix Specialist
ios-data        # Data - Testing & Quality Assurance
ios-geordi      # Geordi La Forge - Performance Optimization
ios-worf        # Worf - Security Specialist
ios-deanna      # Deanna Troi - UX/UI Specialist
ios-barclay     # Reginald Barclay - Documentation
```

#### Android Team Agents
```bash
android-kirk    # Captain Kirk - Lead Feature Developer
android-mccoy   # Dr. McCoy - Bugfix Specialist
android-spock   # Spock - Testing & Logic
android-scotty  # Scotty - Performance Engineer
android-uhura   # Uhura - Localization & i18n
android-sulu    # Sulu - Navigation & UI
android-chekov  # Chekov - Documentation
```

#### Firebase Team Agents
```bash
firebase-sisko     # Commander Sisko - Backend Lead
firebase-bashir    # Dr. Bashir - API Health
firebase-kira      # Major Kira - Security
firebase-odo       # Odo - Authentication
firebase-jadzia    # Jadzia Dax - Database Optimization
firebase-obrien    # Chief O'Brien - Infrastructure
firebase-weyoun    # Weyoun - Documentation
firebase-garak     # Garak - Data Migration
```

### Using Agents

```bash
# Start agent session (opens Claude Code)
ios-picard

# The agent will:
# - Load team-specific persona
# - Have access to team repositories
# - Auto-track work in kanban system
# - Follow team-specific guidelines
```

### Agent Tracking

Agents automatically track their work in the kanban system:
- Session start/stop hooks record activity
- Tool usage is logged
- Kanban items are updated automatically
- Time tracking is recorded

### Agent Configuration

Agent configurations are stored in:
```
~/dev-team/claude/agents/<Team Name>/<agent-name>/
```

Each agent has:
- `persona.md` - Agent personality and role description
- `settings.json` - Claude Code configuration
- `avatar.png` - Agent avatar image

---

## Git Worktrees

Dev-Team includes automation for git worktrees, allowing parallel development.

### Worktree Commands

```bash
# List worktrees
wt-list

# Create new worktree
wt-create feature/my-feature
wt-create bugfix/fix-crash

# Remove worktree
wt-remove feature/my-feature

# Clean up stale worktrees
wt-clean

# Switch to worktree
wt-switch feature/my-feature
```

### Worktree Workflow

```bash
# 1. Create worktree for new feature
wt-create feature/xios-0042

# 2. CD into worktree
cd ~/dev-team/worktrees/feature/xios-0042

# 3. Work on feature (separate from main repo)
# Make changes, commit, push

# 4. When done, create PR
gh pr create --base develop

# 5. After merge, clean up worktree
wt-remove feature/xios-0042
```

### Worktree Integration with Kanban

Worktrees created via `kb-run` are automatically linked to kanban items:

```bash
# Create worktree from kanban item
kb-run XIOS-0042

# This:
# 1. Creates worktree: worktrees/xios-0042
# 2. Creates branch: feature/xios-0042
# 3. Links to kanban item
# 4. Updates kanban status to "in_progress"
```

---

## Shell Aliases and Shortcuts

Dev-Team installs numerous shell aliases for common operations.

### Core Aliases

```bash
# Dev-Team commands
dt-status        # Alias for: dev-team status
dt-doctor        # Alias for: dev-team doctor
dt-start         # Alias for: dev-team start
dt-stop          # Alias for: dev-team stop

# Claude Code shortcuts
cc               # Launch Claude Code in current directory
cc-auth          # Re-authenticate Claude Code
```

### Kanban Aliases

```bash
# See LCARS Kanban System section above
kb-list, kb-add, kb-update, kb-move, kb-show, kb-status, kb-sub, etc.
```

### Worktree Aliases

```bash
# See Git Worktrees section above
wt-list, wt-create, wt-remove, wt-clean, wt-switch
```

### Git Shortcuts

```bash
# Common git operations
gs               # git status
gd               # git diff
gl               # git log --oneline
gp               # git push
gpl              # git pull
gco              # git checkout
gcb              # git checkout -b
```

### Navigation Shortcuts

```bash
# Quick navigation
cddt             # cd ~/dev-team
cdk              # cd ~/dev-team/kanban
cdl              # cd ~/dev-team/lcars-ui
cdt              # cd ~/dev-team/teams
```

### Viewing Aliases

```bash
# List all dev-team aliases
alias | grep "^dt-"
alias | grep "^kb-"
alias | grep "^wt-"
```

---

## Managing Services

### LCARS Kanban Service

```bash
# Check LCARS status
curl http://localhost:8082/health

# Start LCARS
dev-team start lcars

# Stop LCARS
dev-team stop lcars

# Restart LCARS
dev-team restart lcars

# View LCARS logs
tail -f ~/dev-team/logs/lcars.log
```

### Fleet Monitor Service (Multi-Machine Only)

```bash
# Check Fleet Monitor status
curl http://localhost:3000/api/health

# Start Fleet Monitor
dev-team start fleet-monitor

# Stop Fleet Monitor
dev-team stop fleet-monitor

# Restart Fleet Monitor
dev-team restart fleet-monitor

# View Fleet Monitor logs
tail -f ~/dev-team/logs/fleet-monitor.log
```

### LaunchAgents (Background Services)

Dev-Team installs LaunchAgents for background tasks:

```bash
# List dev-team LaunchAgents
launchctl list | grep dev-team

# View LaunchAgent status
launchctl list com.devteam.kanban-backup
launchctl list com.devteam.lcars-health

# Restart LaunchAgent
launchctl kickstart -k gui/$(id -u)/com.devteam.kanban-backup
```

**Installed LaunchAgents:**
- `com.devteam.kanban-backup` - Hourly kanban backups
- `com.devteam.lcars-health` - LCARS health monitoring

---

## Upgrading and Maintenance

### Upgrading Dev-Team

```bash
# Upgrade framework
brew upgrade dev-team

# Upgrade working directory components
dev-team upgrade
```

**What gets upgraded:**
- Core scripts and executables
- Shell helper functions
- LCARS UI components
- Fleet Monitor server
- Team configurations (templates merged with existing)

**What's preserved:**
- Kanban board data
- Custom configurations
- Team directories
- Git worktrees

### Upgrade Process

1. **Check for updates:**
   ```bash
   brew update
   brew outdated dev-team
   ```

2. **Backup current state:**
   ```bash
   tar -czf ~/dev-team-backup-$(date +%Y%m%d).tar.gz ~/dev-team/
   ```

3. **Upgrade framework:**
   ```bash
   brew upgrade dev-team
   ```

4. **Upgrade working directory:**
   ```bash
   dev-team upgrade
   ```

5. **Verify upgrade:**
   ```bash
   dev-team doctor
   dev-team --version
   ```

6. **Restart services:**
   ```bash
   dev-team restart
   ```

### Maintenance Tasks

#### Clean Up Old Worktrees

```bash
wt-clean
```

#### Clean Up Old Backups

```bash
# Backups older than 7 days are auto-deleted
# Manual cleanup:
find ~/dev-team/kanban-backups -mtime +7 -delete
```

#### Update Dependencies

```bash
# Update Homebrew packages
brew upgrade python@3 node jq gh

# Update Claude Code
npm update -g @anthropic-ai/claude-code

# Update Tailscale
brew upgrade tailscale
```

#### Repair Broken Installation

```bash
# Run diagnostics
dev-team doctor --verbose

# Attempt automatic repair
dev-team doctor --fix

# Manual repair: re-run setup
dev-team setup
```

---

## Advanced Usage

### Environment Variables

```bash
# Framework location
echo $DEV_TEAM_HOME
# Output: /opt/homebrew/opt/dev-team/libexec

# Working directory location
echo $DEV_TEAM_DIR
# Output: /Users/username/dev-team
```

### Custom Configuration

Edit `~/dev-team/config.json` to customize:
- LCARS port number
- Fleet Monitor settings
- Team-specific settings
- Service startup behavior

### Adding Custom Teams

See [ADDING_A_TEAM.md](ADDING_A_TEAM.md) for detailed instructions on creating custom teams.

### Scripting with Dev-Team

```bash
# Non-interactive operations
dev-team status --json | jq .teams

# Programmatic kanban operations
kb-add "Automated task" --team ios --status backlog

# Batch operations
for team in ios android firebase; do
  kb-status $team
done
```

---

## Tips and Best Practices

### Daily Workflow

1. **Start your team environment:**
   ```bash
   dev-team start ios
   ```

2. **Check kanban status:**
   ```bash
   kb-list --status in_progress
   ```

3. **Start working on item:**
   ```bash
   kb-run XIOS-0042  # Creates worktree and starts agent
   ```

4. **Work in worktree with agent assistance:**
   ```bash
   ios-picard  # Agent auto-tracks work
   ```

5. **Create PR when done:**
   ```bash
   gh pr create --base develop
   ```

6. **Clean up:**
   ```bash
   kb-done XIOS-0042  # Updates kanban
   wt-remove xios-0042  # Removes worktree
   ```

### Parallel Development

Use worktrees to work on multiple features simultaneously:

```bash
# Terminal 1: Feature A
kb-run XIOS-0042
cd ~/dev-team/worktrees/xios-0042
ios-picard

# Terminal 2: Feature B
kb-run XIOS-0043
cd ~/dev-team/worktrees/xios-0043
ios-beverly

# Each worktree is isolated
```

### Multi-Team Development

Work across platforms simultaneously:

```bash
# Start all relevant teams
dev-team start ios android firebase

# Work in each team's context
# Agents track work to correct team's kanban board
```

---

## Getting Help

### Built-in Help

```bash
# Command help
dev-team help
dev-team setup --help
dev-team doctor --help

# Kanban help
kb-help

# Worktree help
wt-help
```

### Documentation

```bash
# View installed documentation
ls ~/dev-team/docs/

# Key documents
cat ~/dev-team/docs/QUICK_START.md
cat ~/dev-team/docs/INSTALLATION.md
cat ~/dev-team/docs/TROUBLESHOOTING.md
```

### Diagnostics

```bash
# Full diagnostic report
dev-team doctor --verbose > ~/dev-team-diagnostic-report.txt
```

---

**Next Steps:**
- Explore [Architecture](ARCHITECTURE.md) to understand the system design
- Set up [Multi-Machine](MULTI_MACHINE.md) coordination if using multiple machines
- Check [Troubleshooting](TROUBLESHOOTING.md) for common issues
- Review [Team Reference](TEAM_REFERENCE.md) for team-specific details
