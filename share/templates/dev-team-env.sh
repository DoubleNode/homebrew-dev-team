#!/bin/zsh
# Dev-Team Environment Loader
# Sources team-specific configurations, aliases, and secrets

# Dev-Team installation directory
# This will be substituted during installation
export DEV_TEAM_DIR="{{DEV_TEAM_DIR}}"

#──────────────────────────────────────────────────────────────────────────────
# Load Shell Aliases
#──────────────────────────────────────────────────────────────────────────────

# Agent switching aliases (claude-geordi, claude-sisko, etc.)
if [ -f "$DEV_TEAM_DIR/share/aliases/agent-aliases.sh" ]; then
    source "$DEV_TEAM_DIR/share/aliases/agent-aliases.sh"
fi

# Kanban helper functions (kb-add, kb-list, kb-update, etc.)
if [ -f "$DEV_TEAM_DIR/share/aliases/kanban-aliases.sh" ]; then
    source "$DEV_TEAM_DIR/share/aliases/kanban-aliases.sh"
fi

# Worktree helper functions (wt-create, wt-list, etc.)
if [ -f "$DEV_TEAM_DIR/share/aliases/worktree-aliases.sh" ]; then
    source "$DEV_TEAM_DIR/share/aliases/worktree-aliases.sh"
fi

#──────────────────────────────────────────────────────────────────────────────
# Load Prompt Customization
#──────────────────────────────────────────────────────────────────────────────

if [ -f "$DEV_TEAM_DIR/share/dev-team-prompt.sh" ]; then
    source "$DEV_TEAM_DIR/share/dev-team-prompt.sh"
fi

#──────────────────────────────────────────────────────────────────────────────
# Load Secrets (if exists)
#──────────────────────────────────────────────────────────────────────────────

# Load secrets ONLY if file exists
# This file should NEVER be committed to git
SECRETS_FILE="$DEV_TEAM_DIR/secrets.env"
if [ -f "$SECRETS_FILE" ]; then
    # Verify file is only readable by owner
    if [[ "$(stat -f '%Lp' "$SECRETS_FILE" 2>/dev/null)" != "600" ]]; then
        echo "⚠️  Warning: $SECRETS_FILE has loose permissions. Run: chmod 600 $SECRETS_FILE"
    fi
    source "$SECRETS_FILE"
fi

#──────────────────────────────────────────────────────────────────────────────
# PATH Additions
#──────────────────────────────────────────────────────────────────────────────

# Add dev-team bin directory to PATH if it exists
if [ -d "$DEV_TEAM_DIR/bin" ]; then
    export PATH="$DEV_TEAM_DIR/bin:$PATH"
fi

#──────────────────────────────────────────────────────────────────────────────
# Team-Specific Startup Scripts
#──────────────────────────────────────────────────────────────────────────────

# If a team-specific startup script exists for this terminal, source it
# This is set by iTerm2 profiles or manual export
if [ -n "$DEV_TEAM_STARTUP" ]; then
    # Reject path traversal attempts
    if [[ "$DEV_TEAM_STARTUP" == *".."* ]]; then
        echo "⚠️  Warning: DEV_TEAM_STARTUP contains path traversal — ignoring"
    elif [ -f "$DEV_TEAM_DIR/$DEV_TEAM_STARTUP" ]; then
        source "$DEV_TEAM_DIR/$DEV_TEAM_STARTUP"
    fi
fi

#──────────────────────────────────────────────────────────────────────────────
# Quiet Success
#──────────────────────────────────────────────────────────────────────────────

# Don't spam output on every shell load
# The aliases will print their own load messages
