# Dev-Team Homebrew Tap - Overview

**Status:** Phase 2 Complete - Core Infrastructure Ready
**Version:** 1.0.0
**Created:** 2026-02-17

---

## What We Built

This Homebrew tap provides the packaging and distribution mechanism for the dev-team environment. It follows a **two-layer architecture**: the framework layer (managed by Homebrew) and the working layer (managed by the user).

---

## Architecture

### Two-Layer Design

**Layer 1: Framework (Homebrew-managed)**
- Location: `$(brew --prefix)/opt/dev-team/libexec/`
- Content: Read-only template files, core scripts, documentation
- Management: Installed via `brew install dev-team`, upgraded via `brew upgrade dev-team`
- Immutable by users

**Layer 2: Working Directory (User-managed)**
- Location: `~/dev-team` (or custom location)
- Content: User configurations, kanban data, generated scripts, team configs
- Management: Created by `dev-team setup`, preserved across framework upgrades
- Fully mutable by users

This separation allows:
- Clean upgrades without losing user data
- Multiple installations with different configs
- Easy rollback to previous framework versions
- Clear distinction between "product" and "data"

---

## Components

### 1. Homebrew Formula (`Formula/dev-team.rb`)

**Purpose:** Defines how to install dev-team via Homebrew

**Key Features:**
- Declares dependencies (Python, Node.js, jq, gh, Git)
- Specifies installation URL and version
- Copies framework files to libexec
- Creates bin stubs for main commands
- Includes caveats (post-install instructions)
- Provides test block for CI validation

**What it does:**
1. Checks dependencies
2. Downloads release tarball
3. Installs to `$(brew --prefix)/opt/dev-team/libexec/`
4. Creates executable stubs in `$(brew --prefix)/bin/`
5. Shows post-install instructions

**What it does NOT do:**
- Configure teams
- Set up kanban system
- Modify user shell configs
- Start services

---

### 2. Main CLI (`bin/dev-team-cli.sh`)

**Purpose:** Command dispatcher that routes subcommands to appropriate handlers

**Commands:**
```bash
dev-team setup       # Run setup wizard
dev-team doctor      # Health check
dev-team status      # Show environment status
dev-team upgrade     # Upgrade components
dev-team start       # Start environment
dev-team stop        # Stop environment
dev-team restart     # Restart environment
dev-team version     # Show version info
dev-team help        # Show help
```

**How it works:**
- Exports `DEV_TEAM_HOME` (framework location)
- Exports `DEV_TEAM_DIR` (working directory)
- Routes to appropriate script based on subcommand
- Checks if configured before allowing most commands
- Falls back to help on unknown commands

---

### 3. Setup Wizard (`bin/dev-team-setup.sh`)

**Purpose:** Interactive configuration and installation wizard

**Modes:**
- `--interactive` (default) - Interactive setup
- `--upgrade` - Upgrade existing installation
- `--uninstall` - Remove configuration
- `--non-interactive` - Scripted setup

**What it does:**
1. Shows banner and intro
2. Checks dependencies (Python, Node, iTerm2, Claude Code, etc.)
3. Offers to install missing dependencies
4. Asks for installation directory
5. Checks for existing installation
6. Copies framework files to working directory
7. Creates configuration marker
8. Shows next steps

**What it will do (future):**
- Team selection (iOS, Android, Firebase, etc.)
- LCARS Kanban setup
- Fleet Monitor configuration (optional)
- LaunchAgent installation
- Shell integration
- Claude Code agent configuration

---

### 4. Health Check (`bin/dev-team-doctor.sh`)

**Purpose:** Comprehensive diagnostics and health monitoring

**Check Categories:**
- **Dependencies** - Python, Node, jq, gh, Git, iTerm2, Claude Code, Tailscale
- **Framework** - Framework installation, core scripts, core directories
- **Config** - Working directory, configuration marker, templates
- **Services** - LCARS server, Fleet Monitor, LaunchAgents
- **Permissions** - Write access, execute permissions

**Output:**
- ✓ Pass (green) - Check succeeded
- ⚠ Warn (yellow) - Non-critical issue
- ✗ Fail (red) - Critical issue

**Options:**
- `--verbose` - Detailed diagnostic output
- `--fix` - Attempt automatic fixes (future)
- `--check <component>` - Check specific component only

---

### 5. Documentation

**README.md** - User-facing documentation:
- Installation instructions
- Usage examples
- Requirements
- Architecture overview
- Configuration
- Troubleshooting

**CONTRIBUTING.md** - Developer documentation:
- Development setup
- Formula development
- Testing workflow
- PR process
- Release process

**OVERVIEW.md** (this file) - Technical overview:
- Architecture decisions
- Component descriptions
- Implementation status
- Next steps

---

### 6. CI/CD (`/.github/workflows/tests.yml`)

**Purpose:** Automated testing on GitHub Actions

**Test Jobs:**
- **test-formula** - Test on Intel and ARM macOS
  - Formula audit
  - Install from source
  - Run formula tests
  - Verify installation
  - Test main commands
  - Test uninstall

- **lint-formula** - Code quality
  - brew style check
  - RuboCop linting

- **test-scripts** - Script validation
  - Syntax checking
  - ShellCheck linting
  - Permission verification

**Triggers:**
- Push to main/develop
- Pull requests
- Manual dispatch

---

## Installation Flow

### User Perspective

```bash
# 1. Add tap
brew tap DoubleNode/dev-team

# 2. Install framework
brew install dev-team

# 3. Run setup wizard
dev-team setup
  # Checks dependencies
  # Installs missing deps (if approved)
  # Chooses installation location
  # Copies framework files
  # Creates config marker
  # Shows next steps

# 4. Verify health
dev-team doctor

# 5. Use dev-team
dev-team start ios
dev-team status
```

---

## Technical Decisions

### Why Two Layers?

**Problem:** Homebrew formulas reinstall to the same location on upgrade, which would overwrite user data.

**Solution:**
- Framework layer = immutable product code
- Working layer = mutable user data
- Setup wizard bridges the two

**Benefits:**
- Clean upgrades via `brew upgrade dev-team`
- User data preserved across upgrades
- Multiple working directories possible
- Clear separation of concerns

### Why Setup Wizard?

**Problem:** Complex environment with many machine-specific settings.

**Solution:** Interactive wizard that:
- Checks dependencies first
- Guides through configuration
- Generates machine-specific files
- Validates installation

**Alternative Considered:** Post-install hook
**Why Not:** Homebrew post-install runs as root, can't easily prompt user, no interactive capabilities

### Why Doctor Command?

**Problem:** Complex installation with many failure points.

**Solution:** Comprehensive health check that:
- Validates all dependencies
- Checks framework integrity
- Verifies configuration
- Tests services
- Provides actionable feedback

**Inspiration:** `brew doctor`, `npm doctor`, `cargo doctor`

---

## File Locations

### After Installation

**Homebrew Installation:**
```
$(brew --prefix)/opt/dev-team/
├── libexec/                    # Framework files (read-only)
│   ├── bin/                   # Core scripts
│   ├── scripts/               # Automation
│   ├── config/templates/      # Templates
│   ├── docs/                  # Documentation
│   ├── skills/                # Claude Code skills
│   └── ...
└── bin -> libexec/bin/        # Symlink

$(brew --prefix)/bin/
├── dev-team                   # Stub → libexec/bin/dev-team-cli.sh
├── dev-team-setup             # Stub → libexec/bin/dev-team-setup.sh
└── dev-team-doctor            # Stub → libexec/bin/dev-team-doctor.sh
```

**Working Directory:**
```
~/dev-team/                     # User's working directory
├── .dev-team-config            # Installation metadata
├── templates/                  # Copied from framework
├── docs/                       # Copied from framework
├── skills/                     # Copied from framework
├── kanban/                     # Kanban board data
├── teams/                      # Team configurations
├── scripts/                    # Generated scripts
└── ...
```

---

## Implementation Status

### ✅ Complete (Phase 2)

- [x] Homebrew formula structure
- [x] Formula with dependencies
- [x] Main CLI dispatcher
- [x] Setup wizard skeleton
- [x] Health check/doctor
- [x] README documentation
- [x] Contributing guide
- [x] CI/CD workflow
- [x] License
- [x] .gitignore

### 🔄 In Progress (Phase 3)

- [ ] Team selection in setup wizard
- [ ] LCARS installation
- [ ] Shell integration
- [ ] LaunchAgent installation
- [ ] Claude Code agent configuration
- [ ] Fleet Monitor setup (optional)

### 📋 Planned (Future Phases)

- [ ] Upgrade workflow
- [ ] Auto-fix in doctor
- [ ] Remote machine provisioning
- [ ] Tap bottle builds (pre-compiled)
- [ ] Version compatibility checks
- [ ] Migration scripts for breaking changes

---

## Testing Strategy

### Manual Testing
1. Formula audit: `brew audit --strict Formula/dev-team.rb`
2. Install from source: `brew install --build-from-source dev-team`
3. Run formula tests: `brew test dev-team`
4. Test all commands: `dev-team --version`, `dev-team-setup --help`, etc.
5. Full integration: `dev-team setup` → configure → `dev-team doctor`

### Automated Testing (CI)
- Formula audit and lint
- Install on Intel and ARM macOS
- Test block execution
- Script syntax validation
- ShellCheck linting

### Integration Testing
- Install on fresh Mac
- Run full setup wizard
- Verify all components work
- Test upgrade path
- Test uninstall

---

## Next Steps

### Phase 3: Setup Wizard Implementation
1. Team selection UI
2. LCARS Kanban installation
3. Shell integration (.zshrc modification)
4. LaunchAgent installation
5. Claude Code agent configuration
6. Template processing

### Phase 4: Testing & Documentation
1. Multi-machine testing
2. Upgrade testing
3. Edge case handling
4. Video walkthrough
5. Troubleshooting guide
6. FAQ

### Phase 5: Distribution
1. Tag v1.0.0 release
2. Create release tarball
3. Update formula SHA256
4. Submit to Homebrew taps registry
5. Announce release
6. Monitor issues

---

## Dependencies

### Required
- **Python 3** (3.8+) - Kanban hooks, LCARS server
- **Node.js** (18.0+) - Fleet Monitor, Claude Code
- **jq** - JSON processing in shell scripts
- **GitHub CLI** (`gh`) - PR workflows, releases
- **Git** - Version control
- **iTerm2** - Terminal emulator
- **Claude Code** - AI pair programmer

### Optional
- **Tailscale** - Multi-machine networking
- **ImageMagick** - Avatar/image processing
- **tmux** - Terminal multiplexing for Fleet Monitor

---

## Maintainer Notes

### Releasing a New Version

1. Update version in `Formula/dev-team.rb`
2. Tag main dev-team repo: `git tag v1.0.0`
3. Push tag: `git push origin v1.0.0`
4. Calculate new SHA256 of release tarball
5. Update formula SHA256
6. Test installation
7. Commit formula update
8. Tag tap repo: `git tag v1.0.0`

### Testing Formula Changes

```bash
# Always test locally before pushing
brew audit --strict Formula/dev-team.rb
brew install --build-from-source dev-team
brew test dev-team

# Test uninstall/reinstall
brew uninstall dev-team
brew install dev-team
```

### Common Issues

**Formula not found:**
```bash
brew untap DoubleNode/dev-team
brew tap DoubleNode/dev-team
```

**SHA256 mismatch:**
- Download fresh tarball
- Recalculate: `shasum -a 256 file.tar.gz`
- Update formula

**Test failures:**
- Check test block in formula
- Verify files actually installed
- Check permissions

---

**Created by:** Commander Jett Reno (Academy Team)
**Date:** 2026-02-17
**Status:** Phase 2 Complete - Ready for Phase 3
