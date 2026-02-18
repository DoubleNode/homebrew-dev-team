#!/bin/zsh
# ============================================================================
# Kanban Board Helpers
# Terminal task tracking for dev-team infrastructure
# ============================================================================
# Usage: Source this file in your terminal session
#   source ~/dev-team/kanban-helpers.sh
#
# Then use the kb-* commands to update your task status
# ============================================================================

# Configuration
# Legacy centralized path (kept for reference, no longer used)
# KANBAN_DIR="${HOME}/dev-team/kanban"

# Get the kanban directory for a specific team
# Each team has their own kanban/ directory in their repository
_kb_get_kanban_dir() {
    local team="$1"

    case "$team" in
        # Main Event Teams
        academy)
            echo "${HOME}/dev-team/kanban"
            ;;
        ios)
            echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"
            ;;
        android)
            echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"
            ;;
        firebase)
            echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"
            ;;
        command)
            echo "/Users/Shared/Development/Main Event/dev-team/kanban"
            ;;
        dns)
            echo "/Users/Shared/Development/DNSFramework/kanban"
            ;;

        # Freelance Projects
        freelance-doublenode-starwords)
            echo "/Users/Shared/Development/DoubleNode/Starwords/kanban"
            ;;
        freelance-doublenode-appplanning)
            echo "/Users/Shared/Development/DoubleNode/appPlanning/kanban"
            ;;
        freelance-doublenode-workstats)
            echo "/Users/Shared/Development/DoubleNode/WorkStats/kanban"
            ;;
        freelance-doublenode-lifeboard)
            echo "/Users/Shared/Development/DoubleNode/LifeBoard/kanban"
            ;;

        # Legal Projects
        legal-coparenting)
            echo "${HOME}/legal/coparenting/kanban"
            ;;

        # Medical Projects
        medical-general)
            echo "${HOME}/medical/general/kanban"
            ;;

        # Default fallback to Academy
        *)
            echo "${HOME}/dev-team/kanban"
            ;;
    esac
}

# Get the config directory for a specific team (kanban/config/)
# Each team's config lives alongside their board data for self-containment.
# Mirrors TEAM_CONFIG_DIR in server.py and _TEAM_KANBAN_DIRS in manager.py.
_kb_get_config_dir() {
    local team="$1"
    local kanban_dir
    kanban_dir=$(_kb_get_kanban_dir "$team")
    echo "${kanban_dir}/config"
}

# ============================================================================
# Safe File Operations with Locking
# ============================================================================
# These functions use file locking to prevent race conditions with Python hooks

_kb_lock_file() {
    local board_file="$1"
    echo "${board_file}.lock"
}

# Execute a jq operation with exclusive file locking
# Usage: _kb_jq_update "board_file" "jq_filter" [jq_args...]
_kb_jq_update() {
    local board_file="$1"
    local jq_filter="$2"
    shift 2
    local jq_args=("$@")

    local lock_file="${board_file}.lock"
    local tmp_file="${board_file}.tmp"

    # Write jq filter to a temp file to avoid zsh printf '%q' escaping issues.
    # zsh's printf '%q' escapes '!' to '\!' which survives through sh -c to jq,
    # breaking any filter containing '!=' operators. Using jq -f bypasses this.
    local filter_file
    filter_file=$(mktemp "${TMPDIR:-/tmp}/kb-jq-filter.XXXXXX")
    printf '%s' "$jq_filter" > "$filter_file"

    # Create lock file if it doesn't exist
    touch "$lock_file" 2>/dev/null

    # Use Perl's flock for exclusive locking (available on macOS by default)
    # Note: bash flock syntax (200>"$file") doesn't work in zsh, so we use perl
    # SAFETY: Validate tmp file is not empty before moving (prevents 0-byte corruption)
    perl -e '
        use Fcntl qw(:flock);
        my $lock_file = $ARGV[0];
        open(my $fh, ">", $lock_file) or die "Cannot open lock file: $!";
        flock($fh, LOCK_EX) or die "Cannot lock: $!";
        my $exit_code = system(@ARGV[1..$#ARGV]);
        close($fh);
        exit($exit_code >> 8);
    ' "$lock_file" sh -c "jq $(printf '%q ' "${jq_args[@]}") -f $(printf '%q' "$filter_file") $(printf '%q' "$board_file") > $(printf '%q' "$tmp_file") && [ -s $(printf '%q' "$tmp_file") ] && mv $(printf '%q' "$tmp_file") $(printf '%q' "$board_file") || { rm -f $(printf '%q' "$tmp_file"); echo 'ERROR: jq produced empty output, aborting write' >&2; exit 1; }"

    local result=$?
    rm "$filter_file" 2>/dev/null

    # After successful board update, trigger team re-registration (background, non-blocking)
    # This keeps Fleet Monitor in sync when board data changes
    # NOTE: disown suppresses zsh's [N] job start/done notifications
    if [ $result -eq 0 ]; then
        (type _kb_register_team &>/dev/null && _kb_register_team) &
        disown 2>/dev/null
    fi

    return $result
}

# Read board file with shared locking
# Usage: _kb_jq_read "board_file" "jq_filter" [jq_args...]
_kb_jq_read() {
    local board_file="$1"
    local jq_filter="$2"
    shift 2
    local jq_args=("$@")

    local lock_file="${board_file}.lock"

    # Create lock file if it doesn't exist
    touch "$lock_file" 2>/dev/null

    # Use shared lock (LOCK_SH) to prevent reading during writes
    # This prevents race conditions where we read a 0-byte file during atomic rename
    perl -e '
        use Fcntl qw(:flock);
        my $lock_file = $ARGV[0];
        open(my $fh, "<", $lock_file) or die "Cannot open lock file: $!";
        flock($fh, LOCK_SH) or die "Cannot lock: $!";
        my $exit_code = system(@ARGV[1..$#ARGV]);
        close($fh);
        exit($exit_code >> 8);
    ' "$lock_file" jq "${jq_args[@]}" "$jq_filter" "$board_file"
}

# Detect which team, terminal, and window we're in
_kb_detect_context() {
    local session_name window_index window_name
    session_name=$(tmux display-message -p '#S' 2>/dev/null || echo "")
    window_index=$(tmux display-message -p '#I' 2>/dev/null || echo "0")
    window_name=$(tmux display-message -p '#W' 2>/dev/null || echo "main")

    if [[ -z "$session_name" ]]; then
        echo "ERROR:ERROR:0:unknown"
        return 1
    fi

    # Extract team/board-prefix and terminal from session name
    # Works for any number of segments:
    #   freelance-command → team=freelance, terminal=command
    #   freelance-doublenode-starwords-command → team=freelance-doublenode-starwords, terminal=command
    #   ios-bridge → team=ios, terminal=bridge
    local team terminal

    # Terminal is always the last segment
    terminal="${session_name##*-}"
    # Team/board-prefix is everything before the last segment
    team="${session_name%-*}"

    echo "${team}:${terminal}:${window_index}:${window_name}"
}

# Get current git worktree path
_kb_get_worktree() {
    git rev-parse --show-toplevel 2>/dev/null || echo ""
}

# Get short worktree name (just the directory name)
_kb_get_worktree_short() {
    local worktree
    worktree=$(_kb_get_worktree)
    if [[ -n "$worktree" ]]; then
        basename "$worktree"
    else
        echo ""
    fi
}

# Check if we're in the main worktree (not a secondary worktree)
# Returns 0 (true) if in main worktree, 1 (false) if in secondary worktree
_kb_is_main_worktree() {
    local git_dir common_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null)

    # If not in a git repo, return false
    [[ -z "$git_dir" ]] && return 1

    # If .git is a file (pointing to main repo), we're in a secondary worktree
    if [[ -f "$git_dir" ]]; then
        return 1
    fi

    # If git-dir equals git-common-dir, we're in the main worktree
    if [[ "$git_dir" == "$common_dir" ]]; then
        return 0
    fi

    return 1
}

# Sync an item to release manifests via LCARS server
# Usage: _kb_release_sync <item_id>
# Returns 0 (success) even if server is down - this is a best-effort sync
_kb_release_sync() {
    local item_id="$1"

    # Skip if no item_id provided
    [[ -z "$item_id" ]] && return 0

    # Try to sync with LCARS server (2 second timeout)
    # Silent by default - only warn on unexpected errors
    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        --max-time 2 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"itemId\": \"$item_id\"}" \
        "http://localhost:8080/api/releases/sync-item" 2>/dev/null)

    # Extract HTTP code from last line
    http_code=$(echo "$response" | tail -n1)

    # Silently succeed if server isn't running or sync worked
    # Only warn on unexpected HTTP codes (not 200, 404, or connection failure)
    if [[ -n "$http_code" ]] && [[ "$http_code" != "200" ]] && [[ "$http_code" != "404" ]] && [[ "$http_code" != "000" ]]; then
        echo "⚠️  Warning: Release manifest sync returned HTTP $http_code for $item_id" >&2
    fi

    # Always return success - sync is best-effort
    return 0
}

# Create a worktree for an item and cd into it
# Usage: _kb_create_item_worktree <item_id> <title>
# Returns the worktree path, or empty on failure
_kb_create_item_worktree() {
    local item_id="$1"
    local title="$2"

    local git_root worktree_dir branch_name worktree_name project_root

    # Get the main repo root (works from any worktree)
    git_root=$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname)
    if [[ -z "$git_root" ]] || [[ "$git_root" == "." ]]; then
        git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    fi

    if [[ -z "$git_root" ]]; then
        echo "Error: Not in a git repository" >&2
        return 1
    fi

    # Determine the project root for worktrees
    # If git_root is named after a common main branch (develop, main, master, DEV),
    # worktrees should be a sibling directory (one level up), not inside the checkout directory
    local git_root_name
    git_root_name=$(basename "$git_root")
    if [[ "$git_root_name" == "develop" ]] || [[ "$git_root_name" == "main" ]] || [[ "$git_root_name" == "master" ]] || [[ "$git_root_name" == "DEV" ]]; then
        project_root=$(dirname "$git_root")
    else
        project_root="$git_root"
    fi

    # Create worktree directory name from item ID (lowercase, portable)
    worktree_name=$(echo "$item_id" | tr '[:upper:]' '[:lower:]')
    worktree_dir="${project_root}/worktrees/${worktree_name}"

    # Create branch name from item ID (lowercase, portable)
    branch_name="feature/${worktree_name}"

    # Check if worktree is already tracked by git
    local existing_worktree
    existing_worktree=$(git worktree list --porcelain 2>/dev/null | grep -A2 "^worktree.*/${worktree_name}$" | head -1 | sed 's/^worktree //')

    if [[ -n "$existing_worktree" ]] && [[ -d "$existing_worktree" ]]; then
        echo "✓ Using existing worktree: $existing_worktree" >&2
        echo "$existing_worktree"
        return 0
    fi

    # Check if directory exists but git doesn't know about it (orphaned)
    if [[ -d "$worktree_dir" ]]; then
        # Check if it's a valid git worktree
        if [[ -f "$worktree_dir/.git" ]]; then
            echo "⚠️  Found orphaned worktree directory. Attempting repair..." >&2
            # Try to repair by removing and re-adding
            git worktree remove "$worktree_dir" --force 2>/dev/null
        else
            echo "⚠️  Directory exists but is not a worktree: $worktree_dir" >&2
            echo "   Removing and recreating..." >&2
            rm -rf "$worktree_dir"
        fi
    fi

    # Check if branch exists and where it's checked out
    local branch_checkout
    branch_checkout=$(git worktree list --porcelain 2>/dev/null | grep -B1 "\[${branch_name}\]" | head -1 | sed 's/^worktree //')

    if [[ -n "$branch_checkout" ]]; then
        echo "⚠️  Branch '$branch_name' is already checked out at:" >&2
        echo "   $branch_checkout" >&2
        echo "   Use that worktree or run: git worktree remove \"$branch_checkout\"" >&2
        return 1
    fi

    # Create worktrees directory if it doesn't exist
    mkdir -p "${project_root}/worktrees"

    # Create the worktree with a new branch based on current branch
    echo "Creating worktree for [$item_id]..." >&2
    echo "  Directory: $worktree_dir" >&2
    echo "  Branch: $branch_name" >&2

    local git_error
    # Try to create with new branch first
    if git_error=$(git worktree add -b "$branch_name" "$worktree_dir" 2>&1); then
        echo "✓ Created new worktree with branch $branch_name" >&2
        echo "$worktree_dir"
        return 0
    fi

    # If branch already exists, try to use it
    if echo "$git_error" | grep -q "already exists"; then
        echo "  Branch exists, attaching worktree..." >&2
        # Redirect both stdout and stderr - git outputs "HEAD is now at..." to stdout
        if git worktree add "$worktree_dir" "$branch_name" >/dev/null 2>&1; then
            echo "✓ Created worktree using existing branch $branch_name" >&2
            echo "$worktree_dir"
            return 0
        fi
    fi

    # Provide detailed error
    echo "Error: Failed to create worktree" >&2
    echo "  Git error: $git_error" >&2
    echo "  Try manually: git worktree add -b $branch_name $worktree_dir" >&2
    return 1
}

# Check if worktree is already in use by another item/subitem
# Returns: "conflict:<id>:<title>" if conflict found, empty otherwise
_kb_check_worktree_conflict() {
    local board_file="$1"
    local current_id="$2"
    local worktree="$3"

    if [[ -z "$worktree" ]]; then
        return 0
    fi

    # Check main items for worktree conflicts
    local conflict
    conflict=$(_kb_jq_read "$board_file" '
        .backlog[] |
        select(.activelyWorking == true and .worktree == $wt and .id != $cid) |
        "item:\(.id):\(.title)"
    ' --arg wt "$worktree" --arg cid "$current_id" -r | head -1)

    if [[ -n "$conflict" ]]; then
        echo "$conflict"
        return 0
    fi

    # Check subitems for worktree conflicts
    conflict=$(_kb_jq_read "$board_file" '
        .backlog[].subitems[]? |
        select(.activelyWorking == true and .worktree == $wt and .id != $cid) |
        "subitem:\(.id):\(.title)"
    ' --arg wt "$worktree" --arg cid "$current_id" -r | head -1)

    if [[ -n "$conflict" ]]; then
        echo "$conflict"
        return 0
    fi

    echo ""
}

# Display worktree conflict warning
_kb_warn_worktree_conflict() {
    local conflict="$1"
    local conflict_type="${conflict%%:*}"
    local rest="${conflict#*:}"
    local conflict_id="${rest%%:*}"
    local conflict_title="${rest#*:}"

    echo ""
    echo "⚠️  WORKTREE CONFLICT WARNING"
    echo "─────────────────────────────────────"
    echo "This worktree is already in use by:"
    if [[ "$conflict_type" == "subitem" ]]; then
        echo "  Subitem: [$conflict_id] $conflict_title"
    else
        echo "  Item: [$conflict_id] $conflict_title"
    fi
    echo ""
    echo "Working on multiple items in the same worktree can cause confusion."
    echo "Consider:"
    echo "  • Complete or stop working on the other item first"
    echo "  • Create a separate worktree for this task"
    echo ""
    echo "Proceeding anyway..."
    echo "─────────────────────────────────────"
}

_kb_get_board_file() {
    local team="$1"
    local kanban_dir
    kanban_dir=$(_kb_get_kanban_dir "$team")
    echo "${kanban_dir}/${team}-board.json"
}

_kb_ensure_jq() {
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required but not installed."
        echo "Install with: brew install jq"
        return 1
    fi
    return 0
}

_kb_get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Set the item/subitem being worked on for the current window
# Usage: _kb_set_working_on <id>
# ID can be an item (XFRE-0001) or subitem (XFRE-0001-001)
_kb_set_working_on() {
    local working_id="$1"

    local context team terminal window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    local timestamp
    timestamp=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" '
       (.activeWindows[] | select(.id == $wid)) |= . + {
           workingOnId: $workingId
       } |
       .lastUpdated = $ts
       ' \
       --arg wid "$window_id" \
       --arg workingId "$working_id" \
       --arg ts "$timestamp"
}

# Clear the working-on item for the current window
_kb_clear_working_on() {
    local context team terminal window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    local timestamp
    timestamp=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" '
       (.activeWindows[] | select(.id == $wid)) |= del(.workingOnId) |
       .lastUpdated = $ts
       ' \
       --arg wid "$window_id" \
       --arg ts "$timestamp"
}

# Extract 2-letter code from compound word (e.g., starwords→SW, appplanning→AP)
# Uses heuristic: find consonant cluster after vowel, split it to find word boundary
_kb_extract_compound_code() {
    local word
    word=$(echo "$1" | tr '[:upper:]' '[:lower:]')  # zsh-compatible lowercase
    local len=${#word}

    # Check for camelCase first (e.g., StarWords → SW)
    # Look for lowercase followed by uppercase
    local camel_match
    camel_match=$(echo "$1" | grep -oE '[a-z][A-Z]' | head -1)
    if [[ -n "$camel_match" ]]; then
        local upper_char="${camel_match:1:1}"
        upper_char=$(echo "$upper_char" | tr '[:upper:]' '[:lower:]')
        echo "${word:0:1}$upper_char"
        return
    fi

    # Heuristic for compound words:
    # Find consonant cluster of 2+ that:
    # 1. Occurs after at least one vowel (not at word start)
    # 2. Is followed by a vowel (not at word end)
    # Then split the cluster - second half starts the new word
    local vowels="aeiou"
    local best_cluster_start=-1
    local best_cluster_len=0
    local cluster_start=-1
    local cluster_len=0
    local seen_vowel=false
    local i=0

    while [[ $i -lt $len ]]; do
        local char="${word:$i:1}"

        if [[ "$vowels" == *"$char"* ]]; then
            # Vowel - mark that we've seen one, check if cluster just ended
            seen_vowel=true
            if [[ $cluster_len -ge 2 && $cluster_len -gt $best_cluster_len ]]; then
                best_cluster_start=$cluster_start
                best_cluster_len=$cluster_len
            fi
            cluster_start=-1
            cluster_len=0
        else
            # Consonant - only track clusters after we've seen a vowel
            if $seen_vowel; then
                if [[ $cluster_start -lt 0 ]]; then
                    cluster_start=$i
                fi
                cluster_len=$((cluster_len + 1))
            fi
        fi
        i=$((i + 1))
    done

    if [[ $best_cluster_start -ge 0 && $best_cluster_len -ge 2 ]]; then
        # Split the cluster - second half starts the new word
        # e.g., "rw" in starwords → split at 'w', "rkst" in workstats → split at 's'
        local split_char_pos=$((best_cluster_start + best_cluster_len / 2))
        echo "${word:0:1}${word:$split_char_pos:1}"
        return
    fi

    # Fallback: first two letters
    echo "${word:0:2}"
}

# Get 3-letter team code for JIRA-style IDs
# Format: X<TeamCode>-#### (e.g., XIOS-0001, XFRE-0042)
_kb_get_team_code() {
    local team="$1"
    case "$team" in
        ios)                               echo "IOS" ;;
        android)                           echo "AND" ;;
        firebase)                          echo "FIR" ;;
        freelance)                         echo "FRE" ;;
        freelance-doublenode-starwords)    echo "FSW" ;;
        freelance-doublenode-workstats)    echo "FWS" ;;
        freelance-doublenode-appplanning)  echo "FAP" ;;
        freelance-doublenode-lifeboard)    echo "FLB" ;;
        academy)                           echo "ACA" ;;
        dns)                               echo "DNS" ;;
        command)                           echo "CMD" ;;
        mainevent)                         echo "MEV" ;;
        legal-coparenting)                 echo "LCP" ;;
        medical-general)                   echo "MED" ;;
        *)
            # Smart fallback for multi-segment names (e.g., freelance-doublenode-newproject)
            # Uses: first letter of first segment + 2-letter code from last segment
            if [[ "$team" == *-* ]]; then
                local first_segment="${team%%-*}"   # Everything before first dash
                local last_segment="${team##*-}"    # Everything after last dash
                local code="${first_segment:0:1}"   # First letter of first segment
                code+=$(_kb_extract_compound_code "$last_segment")  # Smart 2-letter from last
                echo "${code:0:3}" | tr '[:lower:]' '[:upper:]'
            else
                # Simple single-word name: first 3 chars
                echo "${team:0:3}" | tr '[:lower:]' '[:upper:]'
            fi
            ;;
    esac
}

# Reverse lookup: get team name from 3-letter code
# Format: X<TeamCode>-#### → team name (e.g., XFSW-0013 → freelance-doublenode-starwords)
# Args: code (3-letter code like "FSW" or full ID like "XFSW-0013")
# Returns: team name or empty string if not found
_kb_get_team_from_code() {
    local input="$1"
    local code

    # Extract code from full ID if provided (XFSW-0013 → FSW)
    # Use parameter expansion instead of regex capture for zsh/bash compatibility
    if [[ "$input" =~ ^X[A-Z]{3}-[0-9]+ ]]; then
        # Extract chars 2-4 (0-indexed: positions 1,2,3) → the 3-letter code
        code="${input:1:3}"
    else
        code="$input"
    fi

    case "$code" in
        IOS) echo "ios" ;;
        AND) echo "android" ;;
        FIR) echo "firebase" ;;
        FRE) echo "freelance" ;;
        FSW) echo "freelance-doublenode-starwords" ;;
        FWS) echo "freelance-doublenode-workstats" ;;
        FAP) echo "freelance-doublenode-appplanning" ;;
        FLB) echo "freelance-doublenode-lifeboard" ;;
        ACA) echo "academy" ;;
        DNS) echo "dns" ;;
        CMD) echo "command" ;;
        MEV) echo "mainevent" ;;
        LCP) echo "legal-coparenting" ;;
        MED) echo "medical-general" ;;
        *)   echo "" ;;  # Unknown code
    esac
}

# Validate Jira ID format and optionally check existence via API
# Args: jira_id
# Returns: 0 always (warn but allow)
# Outputs warning messages to stderr if validation fails
_kb_validate_jira_id() {
    local jira_id="$1"

    # Skip validation for clear operations
    [[ "$jira_id" == "-" ]] && return 0
    [[ -z "$jira_id" ]] && return 0

    # Basic format validation: PROJECT-123 (1-10 uppercase letters + hyphen + digits)
    if [[ ! "$jira_id" =~ ^[A-Z]{1,10}-[0-9]+$ ]]; then
        echo "⚠️  Warning: '$jira_id' doesn't match standard Jira format (PROJECT-123)" >&2
        echo "   Continuing anyway - ticket may be created later" >&2
        return 0
    fi

    # Optional API validation if credentials are available
    if [[ -n "$JIRA_ENDPOINT" ]] && [[ -n "$JIRA_USER" ]] && [[ -n "$JIRA_API_TOKEN" ]]; then
        local response http_code
        response=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "${JIRA_USER}:${JIRA_API_TOKEN}" \
            "${JIRA_ENDPOINT}/rest/api/3/issue/${jira_id}?fields=summary" \
            --connect-timeout 3 --max-time 5 2>/dev/null)

        case "$response" in
            200)
                # Ticket exists - all good
                ;;
            404)
                echo "⚠️  Warning: Jira ticket '$jira_id' not found in ${JIRA_ENDPOINT}" >&2
                echo "   Continuing anyway - ticket may be created later" >&2
                ;;
            401|403)
                # Auth issues - silently skip API validation
                ;;
            000|"")
                # Network/timeout - silently skip
                ;;
            *)
                # Other errors - silently skip
                ;;
        esac
    fi

    return 0
}

# Generate next ID for a team
# Returns: X<TeamCode>-#### (e.g., XIOS-0001)
# Validate and auto-correct nextId counter to prevent duplicate IDs
# Returns the safe next ID number (validates against existing items)
_kb_validate_next_id() {
    local board_file="$1"
    local series="$2"

    # Get the current nextId from board
    local next_id
    next_id=$(_kb_jq_read "$board_file" '.nextId // 1' -r)

    # Find the highest existing ID number in backlog matching this series
    # Extract numeric portion from IDs like "XAND-0564" -> 564
    local max_existing
    max_existing=$(_kb_jq_read "$board_file" \
        '[.backlog[].id | select(startswith($series + "-")) | split("-")[1] | tonumber] | max // 0' \
        --arg series "$series" -r 2>/dev/null)

    # If max_existing is null/empty, default to 0
    if [[ -z "$max_existing" || "$max_existing" == "null" ]]; then
        max_existing=0
    fi

    # Ensure nextId is always greater than the highest existing ID
    if [[ "$next_id" -le "$max_existing" ]]; then
        local corrected_id=$((max_existing + 1))
        echo "⚠️  ID counter sync issue detected: nextId=$next_id but max existing ID=$max_existing" >&2
        echo "   Auto-correcting nextId to $corrected_id" >&2

        # Update the board with corrected nextId
        local timestamp
        timestamp=$(_kb_get_timestamp)
        _kb_jq_update "$board_file" \
            '.nextId = ($new_id | tonumber) | .lastUpdated = $ts' \
            --arg new_id "$corrected_id" --arg ts "$timestamp"

        echo "$corrected_id"
    else
        echo "$next_id"
    fi
}

_kb_generate_id() {
    local board_file="$1"
    local team="$2"

    # Priority 1: Use 'series' field from board config (single source of truth)
    local series
    series=$(_kb_jq_read "$board_file" '.series // empty' -r 2>/dev/null)

    local prefix
    if [[ -n "$series" ]]; then
        # Board has explicit series prefix (e.g., "XLCP")
        prefix="$series"
    else
        # Fallback to derived team code
        local team_code
        team_code=$(_kb_get_team_code "$team")
        prefix="X$team_code"
    fi

    # SAFEGUARD: Validate nextId against existing items to prevent duplicates
    local next_num
    next_num=$(_kb_validate_next_id "$board_file" "$prefix")

    # Format as 4-digit number with leading zeros
    printf "%s-%04d" "$prefix" "$next_num"
}

# Increment the nextId counter in the board
_kb_increment_id() {
    local board_file="$1"
    local timestamp
    timestamp=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" \
       '.nextId = ((.nextId // 1) + 1) | .lastUpdated = $ts' \
       --arg ts "$timestamp"
}

# Find item index by ID
# Returns the array index or -1 if not found
_kb_find_by_id() {
    local board_file="$1"
    local item_id="$2"

    _kb_jq_read "$board_file" \
       '.backlog | to_entries | map(select(.value.id == $id)) | .[0].key // -1' \
       --arg id "$item_id" -r
}

# Resolve selector to index - supports both ID (XIOS-0001) and numeric index
_kb_resolve_selector() {
    local board_file="$1"
    local selector="$2"

    if [[ "$selector" =~ ^X[A-Z]{3}-[0-9]+$ ]]; then
        # It's an ID - look it up
        _kb_find_by_id "$board_file" "$selector"
    elif [[ "$selector" =~ ^[0-9]+$ ]]; then
        # It's a numeric index
        echo "$selector"
    else
        echo "-1"
    fi
}

# Resolve a subitem ID (e.g., XFRE-0001-001) to "parent_idx:subitem_idx"
# Returns "-1:-1" if not found
_kb_resolve_subitem_id() {
    local board_file="$1"
    local subitem_id="$2"

    # Match pattern: XTEAM-####-### (e.g., XFRE-0001-001)
    if [[ ! "$subitem_id" =~ ^(X[A-Z]{2,4}-[0-9]+)-([0-9]+)$ ]]; then
        echo "-1:-1"
        return
    fi

    local parent_id="${match[1]}"

    # Find parent index
    local parent_idx
    parent_idx=$(_kb_find_by_id "$board_file" "$parent_id")

    if [[ "$parent_idx" == "-1" ]]; then
        echo "-1:-1"
        return
    fi

    # Find subitem by ID
    local sub_idx
    sub_idx=$(_kb_jq_read "$board_file" \
        '.backlog[$pidx].subitems // [] | to_entries[] | select(.value.id == $sid) | .key' \
        --argjson pidx "$parent_idx" --arg sid "$subitem_id" -r 2>/dev/null | head -n1)

    if [[ -z "$sub_idx" ]]; then
        echo "-1:-1"
        return
    fi

    echo "$parent_idx:$sub_idx"
}

# Check if an ID is a subitem ID (XTEAM-####-###) - XACA-0025
# Usage: _kb_is_subitem_id <id>
# Returns: 0 (true) if subitem ID, 1 (false) otherwise
_kb_is_subitem_id() {
    local id="$1"
    [[ "$id" =~ ^X[A-Z]{2,4}-[0-9]+-[0-9]+$ ]]
}

# Generate unique window ID
_kb_get_window_id() {
    local terminal="$1"
    local window_name="$2"
    echo "${terminal}:${window_name}"
}

# ============================================================================
# Core Window Management
# ============================================================================

# Update or create a window entry in activeWindows (with file locking)
_kb_update_window() {
    _kb_ensure_jq || return 1

    local task_status="$1"
    local task="$2"

    local context team terminal window_index window_name board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_index="${rest%%:*}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    local timestamp worktree window_id
    timestamp=$(_kb_get_timestamp)
    # XACA-0020 FIX: Use full worktree path for comparison with existing entry
    # Previously used _kb_get_worktree_short which never matched $existing.worktree (full path)
    worktree=$(_kb_get_worktree)
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    # Get developer info from terminals (read with locking)
    local developer color
    developer=$(_kb_jq_read "$board_file" '.terminals[$t].developer // "Unknown"' --arg t "$terminal" -r)
    color=$(_kb_jq_read "$board_file" '.terminals[$t].color // "operations"' --arg t "$terminal" -r)

    # Update or insert window in activeWindows array (with exclusive locking)
    # IMPORTANT: Preserves workingOnId and other persistent fields from existing entry
    _kb_jq_update "$board_file" '
       # Find existing entry to preserve important fields
       # NOTE: Must use [... ] | first // null to handle empty activeWindows array.
       # Using bare (.activeWindows[] | select(...)) as $existing produces ZERO results
       # when no match exists, causing the entire pipeline to emit nothing (empty output).
       ([.activeWindows[] | select(.id == $id)] | first // null) as $existing |
       # Remove existing entry with same id
       .activeWindows = [.activeWindows[] | select(.id != $id)] |
       # Add new/updated entry, preserving persistent fields from existing
       .activeWindows += [{
           id: $id,
           terminal: $terminal,
           window: $window,
           windowName: $windowName,
           status: $status,
           task: $task,
           worktree: $worktree,
           developer: $developer,
           color: $color,
           startedAt: ($existing.startedAt // $timestamp),
           statusChangedAt: (if ($existing.status // "") != $status then $timestamp else ($existing.statusChangedAt // $timestamp) end),
           statusHistory: (if ($existing.status // "") != $status and ($existing.status // "") != "" then (($existing.statusHistory // []) + [$existing.status]) else ($existing.statusHistory // []) end),
           todoProgress: $existing.todoProgress,
           lastActivity: $timestamp,
           workingOnId: ($existing.workingOnId // null),
           blockedReason: $existing.blockedReason,
           previousStatus: $existing.previousStatus,
           gitBranch: $existing.gitBranch,
           gitModified: $existing.gitModified,
           gitLines: $existing.gitLines
       } | with_entries(select(.value != null))] |
       .lastUpdated = $timestamp
       ' \
       --arg id "$window_id" \
       --arg terminal "$terminal" \
       --argjson window "$window_index" \
       --arg windowName "$window_name" \
       --arg status "$task_status" \
       --arg task "$task" \
       --arg worktree "$worktree" \
       --arg timestamp "$timestamp" \
       --arg developer "$developer" \
       --arg color "$color"
}

# Remove window from activeWindows (with file locking)
_kb_remove_window() {
    _kb_ensure_jq || return 1

    local context team terminal window_index window_name board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_index="${rest%%:*}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        return 1
    fi

    local window_id timestamp
    window_id=$(_kb_get_window_id "$terminal" "$window_name")
    timestamp=$(_kb_get_timestamp)

    # Remove with exclusive locking
    _kb_jq_update "$board_file" \
       '.activeWindows = [.activeWindows[] | select(.id != $id)] |
        .lastUpdated = $timestamp' \
       --arg id "$window_id" \
       --arg timestamp "$timestamp"
}

# ============================================================================
# Dependency Blocking Helpers (XACA-0020)
# ============================================================================

# Add a blocker to an item
# Usage: _kb_add_blocker <board_file> <item_id> <blocker_id>
# Adds blocker_id to item's blockedBy array, sets status to blocked
_kb_add_blocker() {
    local board_file="$1"
    local item_id="$2"
    local blocker_id="$3"

    local index timestamp
    index=$(_kb_find_by_id "$board_file" "$item_id")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $item_id" >&2
        return 1
    fi

    # Validate that blocker is not already resolved
    local blocker_status
    if _kb_is_subitem_id "$blocker_id"; then
        local blocker_indices
        blocker_indices=$(_kb_resolve_subitem_id "$board_file" "$blocker_id")
        if [[ "$blocker_indices" != "-1:-1" ]]; then
            local blocker_parent_idx="${blocker_indices%%:*}"
            local blocker_sub_idx="${blocker_indices##*:}"
            blocker_status=$(_kb_jq_read "$board_file" \
                ".backlog[$blocker_parent_idx].subitems[$blocker_sub_idx].status // empty" -r)
            if [[ "$blocker_status" == "completed" ]] || [[ "$blocker_status" == "cancelled" ]]; then
                echo "Error: Cannot block on already-resolved item/subitem $blocker_id (status: $blocker_status)" >&2
                return 1
            fi
        fi
    else
        blocker_status=$(_kb_jq_read "$board_file" \
            '.backlog[] | select(.id == $bid) | .status // empty' \
            --arg bid "$blocker_id" -r)
        if [[ "$blocker_status" == "completed" ]] || [[ "$blocker_status" == "cancelled" ]]; then
            echo "Error: Cannot block on already-resolved item/subitem $blocker_id (status: $blocker_status)" >&2
            return 1
        fi
    fi

    timestamp=$(_kb_get_timestamp)

    # Add blocker to blockedBy array (create if needed), set status to blocked
    _kb_jq_update "$board_file" '
        .backlog[$idx].blockedBy = ((.backlog[$idx].blockedBy // []) + [$blocker] | unique) |
        .backlog[$idx].status = "blocked" |
        .backlog[$idx].blockedAt //= $ts |
        .backlog[$idx].updatedAt = $ts |
        .lastUpdated = $ts
    ' --argjson idx "$index" \
      --arg blocker "$blocker_id" \
      --arg ts "$timestamp"
}

# Remove a blocker from an item
# Usage: _kb_remove_blocker <board_file> <item_id> <blocker_id>
# Removes blocker_id from item's blockedBy array
# If blockedBy becomes empty, sets status back to "todo"
_kb_remove_blocker() {
    local board_file="$1"
    local item_id="$2"
    local blocker_id="$3"

    local index timestamp
    index=$(_kb_find_by_id "$board_file" "$item_id")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $item_id" >&2
        return 1
    fi

    timestamp=$(_kb_get_timestamp)

    # Remove blocker from blockedBy array
    # If blockedBy becomes empty, change status from blocked to todo and clean up
    _kb_jq_update "$board_file" '
        .backlog[$idx].blockedBy = ((.backlog[$idx].blockedBy // []) - [$blocker]) |
        if (.backlog[$idx].blockedBy | length) == 0 then
            .backlog[$idx].status = "todo" |
            del(.backlog[$idx].blockedBy) |
            del(.backlog[$idx].blockedAt)
        else . end |
        .backlog[$idx].updatedAt = $ts |
        .lastUpdated = $ts
    ' --argjson idx "$index" \
      --arg blocker "$blocker_id" \
      --arg ts "$timestamp"
}

# Check and unblock dependents when an item is completed
# Usage: _kb_check_unblock_dependents <board_file> <completed_item_id>
# Finds all items blocked by the completed item and removes it from their blockedBy
_kb_check_unblock_dependents() {
    local board_file="$1"
    local resolved_id="$2"

    local timestamp unblocked_items
    timestamp=$(_kb_get_timestamp)

    # Find all items that have this resolved (completed OR cancelled) item in their blockedBy array
    # and remove it, potentially unblocking them
    unblocked_items=$(_kb_jq_update "$board_file" '
        .backlog = [.backlog[] |
            if (.blockedBy // []) | any(. == $resolvedId) then
                .blockedBy = (.blockedBy - [$resolvedId]) |
                if (.blockedBy | length) == 0 then
                    .status = "todo" |
                    del(.blockedBy) |
                    del(.blockedAt) |
                    .unblockedAt = $ts |
                    .updatedAt = $ts
                else
                    .updatedAt = $ts
                end
            else . end
        ] |
        .lastUpdated = $ts
    ' --arg resolvedId "$resolved_id" \
      --arg ts "$timestamp" 2>&1)

    # XACA-0025: Also unblock subitems that are blocked by the resolved (completed OR cancelled) item
    _kb_jq_update "$board_file" '
        .backlog = [.backlog[] |
            .subitems = [(.subitems // [])[] |
                if (.blockedBy // []) | any(. == $resolvedId) then
                    .blockedBy = (.blockedBy - [$resolvedId]) |
                    if (.blockedBy | length) == 0 then
                        .status = "todo" |
                        del(.blockedBy) |
                        del(.blockedAt) |
                        .unblockedAt = $ts |
                        .updatedAt = $ts
                    else
                        .updatedAt = $ts
                    end
                else . end
            ]
        ] |
        .lastUpdated = $ts
    ' --arg resolvedId "$resolved_id" \
      --arg ts "$timestamp" 2>&1

    # Return list of unblocked items for notification
    _kb_jq_read "$board_file" '
        [.backlog[] | select(.unblockedAt == $ts)] | map(.id) | join(", ")
    ' --arg ts "$timestamp" -r
}

# Add a blocker to a subitem (XACA-0025)
# Usage: _kb_add_subitem_blocker <board_file> <subitem_id> <blocker_id>
_kb_add_subitem_blocker() {
    local board_file="$1"
    local subitem_id="$2"
    local blocker_id="$3"

    local indices timestamp
    indices=$(_kb_resolve_subitem_id "$board_file" "$subitem_id")

    if [[ "$indices" == "-1:-1" ]]; then
        echo "Error: Subitem not found: $subitem_id" >&2
        return 1
    fi

    local parent_idx="${indices%%:*}"
    local sub_idx="${indices##*:}"

    # Validate that blocker is not already resolved
    local blocker_status
    if _kb_is_subitem_id "$blocker_id"; then
        local blocker_indices
        blocker_indices=$(_kb_resolve_subitem_id "$board_file" "$blocker_id")
        if [[ "$blocker_indices" != "-1:-1" ]]; then
            local blocker_parent_idx="${blocker_indices%%:*}"
            local blocker_sub_idx="${blocker_indices##*:}"
            blocker_status=$(_kb_jq_read "$board_file" \
                ".backlog[$blocker_parent_idx].subitems[$blocker_sub_idx].status // empty" -r)
            if [[ "$blocker_status" == "completed" ]] || [[ "$blocker_status" == "cancelled" ]]; then
                echo "Error: Cannot block on already-resolved item/subitem $blocker_id (status: $blocker_status)" >&2
                return 1
            fi
        fi
    else
        blocker_status=$(_kb_jq_read "$board_file" \
            '.backlog[] | select(.id == $bid) | .status // empty' \
            --arg bid "$blocker_id" -r)
        if [[ "$blocker_status" == "completed" ]] || [[ "$blocker_status" == "cancelled" ]]; then
            echo "Error: Cannot block on already-resolved item/subitem $blocker_id (status: $blocker_status)" >&2
            return 1
        fi
    fi

    timestamp=$(_kb_get_timestamp)

    # XACA-0029: Calculate and accumulate work time if actively working
    local work_started_at existing_time_ms total_time_ms
    work_started_at=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].workStartedAt // empty" -r)
    existing_time_ms=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].timeWorkedMs // 0")
    total_time_ms="$existing_time_ms"

    if [[ -n "$work_started_at" ]]; then
        # Calculate elapsed time in milliseconds
        local start_epoch now_epoch elapsed_ms
        # Strip Z suffix and parse as UTC (macOS date -j -f ignores timezone suffix)
        start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${work_started_at%Z}" "+%s" 2>/dev/null || echo "0")
        now_epoch=$(date -u "+%s")
        if [[ "$start_epoch" != "0" ]] && [[ "$start_epoch" -gt 0 ]]; then
            elapsed_ms=$(( (now_epoch - start_epoch) * 1000 ))
            total_time_ms=$(( existing_time_ms + elapsed_ms ))
        fi
    fi

    _kb_jq_update "$board_file" '
        .backlog[$pidx].subitems[$sidx].blockedBy = ((.backlog[$pidx].subitems[$sidx].blockedBy // []) + [$blocker] | unique) |
        .backlog[$pidx].subitems[$sidx].status = "blocked" |
        .backlog[$pidx].subitems[$sidx].blockedAt //= $ts |
        (if $timeMs != "0" then .backlog[$pidx].subitems[$sidx].timeWorkedMs = ($timeMs | tonumber) else . end) |
        del(.backlog[$pidx].subitems[$sidx].activelyWorking) |
        del(.backlog[$pidx].subitems[$sidx].workStartedAt) |
        del(.backlog[$pidx].subitems[$sidx].worktree) |
        del(.backlog[$pidx].subitems[$sidx].worktreeBranch) |
        del(.backlog[$pidx].subitems[$sidx].worktreeWindowId) |
        .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
        .backlog[$pidx].updatedAt = $ts |
        .lastUpdated = $ts
    ' --argjson pidx "$parent_idx" \
      --argjson sidx "$sub_idx" \
      --arg blocker "$blocker_id" \
      --arg ts "$timestamp" \
      --arg timeMs "$total_time_ms"
}

# Remove a blocker from a subitem (XACA-0025)
# Usage: _kb_remove_subitem_blocker <board_file> <subitem_id> <blocker_id>
# If blockedBy becomes empty, sets status back to "todo"
_kb_remove_subitem_blocker() {
    local board_file="$1"
    local subitem_id="$2"
    local blocker_id="$3"

    local indices timestamp
    indices=$(_kb_resolve_subitem_id "$board_file" "$subitem_id")

    if [[ "$indices" == "-1:-1" ]]; then
        echo "Error: Subitem not found: $subitem_id" >&2
        return 1
    fi

    local parent_idx="${indices%%:*}"
    local sub_idx="${indices##*:}"
    timestamp=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" '
        .backlog[$pidx].subitems[$sidx].blockedBy = ((.backlog[$pidx].subitems[$sidx].blockedBy // []) - [$blocker]) |
        if (.backlog[$pidx].subitems[$sidx].blockedBy | length) == 0 then
            .backlog[$pidx].subitems[$sidx].status = "todo" |
            del(.backlog[$pidx].subitems[$sidx].blockedBy) |
            del(.backlog[$pidx].subitems[$sidx].blockedAt)
        else . end |
        .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
        .backlog[$pidx].updatedAt = $ts |
        .lastUpdated = $ts
    ' --argjson pidx "$parent_idx" \
      --argjson sidx "$sub_idx" \
      --arg blocker "$blocker_id" \
      --arg ts "$timestamp"
}

# ============================================================================
# Public Commands
# ============================================================================

# Set window status
# Usage: kb-status <status>
# Status: paused | ready | planning | coding | testing | commit | pr_review
# Note: For paused status, prefer kb-pause "reason" which stores the reason and previous status
kb-status() {
    local task_status="$1"
    local valid_statuses=("paused" "ready" "planning" "coding" "testing" "commit" "pr_review")

    if [[ -z "$task_status" ]]; then
        echo "Usage: kb-status <status>"
        echo "Valid statuses: ${valid_statuses[*]}"
        return 1
    fi

    if [[ ! " ${valid_statuses[*]} " =~ " ${task_status} " ]]; then
        echo "Error: Invalid status '$task_status'"
        echo "Valid statuses: ${valid_statuses[*]}"
        return 1
    fi

    # Get current task to preserve it
    local context team terminal window_index board_file window_id current_task
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_index="${rest%%:*}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    current_task=$(_kb_jq_read "$board_file" '(.activeWindows[] | select(.id == $id) | .task) // ""' --arg id "$window_id" -r 2>/dev/null || echo "")

    _kb_update_window "$task_status" "$current_task"
    echo "Status updated to: $task_status"
}

# Set current task description
# Usage: kb-task "description"
kb-task() {
    local task="$1"

    if [[ -z "$task" ]]; then
        echo "Usage: kb-task \"task description\""
        return 1
    fi

    # Get current status to preserve it
    local context team terminal window_index window_name board_file window_id curr_status
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_index="${rest%%:*}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    curr_status=$(_kb_jq_read "$board_file" '(.activeWindows[] | select(.id == $id) | .status) // "coding"' --arg id "$window_id" -r 2>/dev/null || echo "coding")

    _kb_update_window "$curr_status" "$task"
    echo "Task set: $task"
}

# Clear window from board (removes it entirely)
# Usage: kb-clear
kb-clear() {
    _kb_remove_window
    echo "Window cleared from board"
}

# Shortcut: Start planning a task
# Usage: kb-plan "task description"
kb-plan() {
    local task="$1"
    if [[ -z "$task" ]]; then
        echo "Usage: kb-plan \"task description\""
        return 1
    fi

    _kb_update_window "planning" "$task"
    echo "Planning: $task"
}

# Shortcut: Move to coding (keeps current task)
# Usage: kb-code
kb-code() {
    kb-status "coding"
}

# Shortcut: Move to testing
# Usage: kb-test
kb-test() {
    kb-status "testing"
}

# Shortcut: Move to commit
# Usage: kb-commit
kb-commit() {
    kb-status "commit"
}

# Shortcut: Move to PR review
# Usage: kb-pr
kb-pr() {
    kb-status "pr_review"
}

# Block current task with a reason
# DEPRECATED: Use kb-pause instead
# Usage: kb-block "reason"
# Backward-compatibility alias - calls kb-pause
# Note: "blocked" is being renamed to "paused" to free up "blocked" for dependency system
kb-block() {
    echo "⚠️  DEPRECATED: kb-block is now kb-pause (blocked → paused)"
    echo "   The command still works, but please update your muscle memory!"
    echo ""
    kb-pause "$@"
}

# DEPRECATED: Use kb-resume instead
# Usage: kb-unblock
# Backward-compatibility alias - calls kb-resume
# Note: "blocked/unblock" is being renamed to "paused/resume"
kb-unblock() {
    echo "⚠️  DEPRECATED: kb-unblock is now kb-resume (unblock → resume)"
    echo "   The command still works, but please update your muscle memory!"
    echo ""
    kb-resume "$@"
}

# Pause current task with a reason (external wait - manual resume required)
# Usage: kb-pause "reason"
# Moves card to paused column, stores reason and previous status for resuming
# Also persists paused state to backlog item for survival across terminal restarts
# Note: PAUSED = external wait (manual resume). Different from future dependency-based blocking.
kb-pause() {
    local reason="$1"

    if [[ -z "$reason" ]]; then
        echo "Usage: kb-pause \"reason for pausing\""
        return 1
    fi

    local context team terminal window_index window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_index="${rest%%:*}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    # Get current status to store as previousStatus
    local current_status
    current_status=$(_kb_jq_read "$board_file" \
        '(.activeWindows[] | select(.id == $id) | .status) // "coding"' \
        --arg id "$window_id" -r 2>/dev/null || echo "coding")

    # Don't allow pausing if already paused
    if [[ "$current_status" == "paused" ]]; then
        echo "Error: Already paused. Use kb-resume first to change the reason."
        return 1
    fi

    # Get the workingOnId to update the backlog item as well
    local working_on_id
    working_on_id=$(_kb_jq_read "$board_file" \
        '(.activeWindows[] | select(.id == $id) | .workingOnId) // ""' \
        --arg id "$window_id" -r 2>/dev/null || echo "")

    local timestamp
    timestamp=$(_kb_get_timestamp)

    # Update the window AND the backlog item: set status to paused, store reason and previous status
    # Persisting to backlog item allows paused state to survive terminal restarts
    _kb_jq_update "$board_file" '
        # Update the activeWindow
        .activeWindows = [.activeWindows[] |
            if .id == $id then
                .status = "paused" |
                .pausedReason = $reason |
                .previousStatus = $prevStatus |
                .lastActivity = $timestamp
            else
                .
            end
        ] |
        # Also update the backlog item (if workingOnId is set)
        (if $workingOnId != "" then
            # Try to find and update the item or subitem
            .backlog = [.backlog[] |
                if .id == $workingOnId then
                    # Direct match on parent item
                    .pausedReason = $reason |
                    .pausedAt = $timestamp |
                    .pausedPreviousStatus = $prevStatus |
                    .updatedAt = $timestamp
                elif (.subitems // []) | any(.id == $workingOnId) then
                    # Match on a subitem - update the subitem
                    .subitems = [(.subitems // [])[] |
                        if .id == $workingOnId then
                            .pausedReason = $reason |
                            .pausedAt = $timestamp |
                            .pausedPreviousStatus = $prevStatus |
                            .updatedAt = $timestamp
                        else . end
                    ]
                else . end
            ]
        else . end) |
        .lastUpdated = $timestamp
    ' \
    --arg id "$window_id" \
    --arg reason "$reason" \
    --arg prevStatus "$current_status" \
    --arg workingOnId "$working_on_id" \
    --arg timestamp "$timestamp"

    echo "⏸️  PAUSED: $reason"
    echo "   (was: $current_status)"
    if [[ -n "$working_on_id" ]]; then
        echo "   (persisted to backlog item: $working_on_id)"
    fi
}

# Resume a paused task and return to previous status
# Usage: kb-resume
# Returns card to its previous status before pausing
# Also clears paused state from backlog item
kb-resume() {
    local context team terminal window_index window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_index="${rest%%:*}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    # Get current status and previous status
    local current_status previous_status
    current_status=$(_kb_jq_read "$board_file" \
        '(.activeWindows[] | select(.id == $id) | .status) // ""' \
        --arg id "$window_id" -r 2>/dev/null || echo "")

    if [[ "$current_status" != "paused" ]]; then
        echo "Error: Not currently paused. Nothing to resume."
        return 1
    fi

    previous_status=$(_kb_jq_read "$board_file" \
        '(.activeWindows[] | select(.id == $id) | .previousStatus) // "coding"' \
        --arg id "$window_id" -r 2>/dev/null || echo "coding")

    # Get the workingOnId to clear paused state from the backlog item as well
    local working_on_id
    working_on_id=$(_kb_jq_read "$board_file" \
        '(.activeWindows[] | select(.id == $id) | .workingOnId) // ""' \
        --arg id "$window_id" -r 2>/dev/null || echo "")

    local timestamp
    timestamp=$(_kb_get_timestamp)

    # Update the window AND backlog item: restore previous status, clear paused fields
    _kb_jq_update "$board_file" '
        # Update the activeWindow
        .activeWindows = [.activeWindows[] |
            if .id == $id then
                .status = $prevStatus |
                del(.pausedReason) |
                del(.previousStatus) |
                .lastActivity = $timestamp
            else
                .
            end
        ] |
        # Also clear paused fields from the backlog item (if workingOnId is set)
        (if $workingOnId != "" then
            .backlog = [.backlog[] |
                if .id == $workingOnId then
                    # Direct match on parent item
                    del(.pausedReason) |
                    del(.pausedAt) |
                    del(.pausedPreviousStatus) |
                    .updatedAt = $timestamp
                elif (.subitems // []) | any(.id == $workingOnId) then
                    # Match on a subitem - clear from the subitem
                    .subitems = [(.subitems // [])[] |
                        if .id == $workingOnId then
                            del(.pausedReason) |
                            del(.pausedAt) |
                            del(.pausedPreviousStatus) |
                            .updatedAt = $timestamp
                        else . end
                    ]
                else . end
            ]
        else . end) |
        .lastUpdated = $timestamp
    ' \
    --arg id "$window_id" \
    --arg prevStatus "$previous_status" \
    --arg workingOnId "$working_on_id" \
    --arg timestamp "$timestamp"

    echo "▶️  RESUMED! Returned to: $previous_status"
    if [[ -n "$working_on_id" ]]; then
        echo "   (cleared from backlog item: $working_on_id)"
    fi
}

# Shortcut: Mark as completed and remove from board
# Usage: kb-done [item-id]
# If item-id is provided, marks that item as completed
# Otherwise, marks the item currently being worked on as completed
kb-done() {
    local context team terminal window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    # Get working_id from argument or from activeWindows
    local working_id explicit_id_provided=false
    if [[ -n "$1" ]]; then
        # Use provided item ID
        working_id="$1"
        explicit_id_provided=true

        # When explicit ID is provided, derive correct board file from ID prefix
        local id_team
        id_team=$(_kb_get_team_from_code "$working_id")
        if [[ -n "$id_team" ]]; then
            board_file=$(_kb_get_board_file "$id_team")
        fi
    else
        # Get current workingOnId from activeWindows
        working_id=$(_kb_jq_read "$board_file" \
            '.activeWindows[] | select(.id == $wid) | .workingOnId // empty' \
            --arg wid "$window_id" -r)
    fi

    if [[ -z "$working_id" ]]; then
        echo "Error: No item ID provided and not currently working on any item"
        return 1
    fi

    # Check for --force flag (allows completing items with incomplete subitems)
    local force_complete=false
    if [[ "$1" == "--force" ]] || [[ "$2" == "--force" ]]; then
        force_complete=true
    fi

    local timestamp item_found=false
    timestamp=$(_kb_get_timestamp)

    # Check if it's a subitem or item and mark as completed
    if [[ "$working_id" =~ ^X[A-Z]{3}-[0-9]+-[0-9]+$ ]]; then
        # Subitem - mark completed with timestamp
        local parent_id="${working_id%-*}"
        local parent_idx
        parent_idx=$(_kb_find_by_id "$board_file" "$parent_id")
        if [[ "$parent_idx" -ge 0 ]]; then
            _kb_jq_update "$board_file" '
                .backlog[$pidx].subitems = [.backlog[$pidx].subitems[] |
                    if .id == $subId then
                        .status = "completed" |
                        .completedAt = $ts |
                        .updatedAt = $ts |
                        del(.activelyWorking, .workStartedAt, .worktree, .worktreeBranch, .worktreeWindowId)
                    else . end
                ] |
                .backlog[$pidx].updatedAt = $ts |
                .lastUpdated = $ts
            ' --argjson pidx "$parent_idx" --arg subId "$working_id" --arg ts "$timestamp"
            item_found=true
        fi
    else
        # Main item - mark completed with timestamp
        local item_idx
        item_idx=$(_kb_find_by_id "$board_file" "$working_id")
        if [[ "$item_idx" -ge 0 ]]; then
            # Check if all subitems are completed (unless --force is used)
            if [[ "$force_complete" == "false" ]]; then
                local incomplete_subitems
                incomplete_subitems=$(_kb_jq_read "$board_file" '
                    .backlog[$idx].subitems // [] |
                    map(select(.status != "completed" and .status != "cancelled")) |
                    map(.id + " - " + .title) |
                    .[]
                ' --argjson idx "$item_idx" -r 2>/dev/null)

                if [[ -n "$incomplete_subitems" ]]; then
                    echo "═══════════════════════════════════════════════════════"
                    echo "❌ Cannot complete item: Incomplete subitems found"
                    echo "═══════════════════════════════════════════════════════"
                    echo ""
                    echo "The following subitems must be completed first:"
                    echo "$incomplete_subitems" | while read -r line; do
                        echo "  • $line"
                    done
                    echo ""
                    echo "Options:"
                    echo "  1. Complete the subitems first: kb-done <subitem-id>"
                    echo "  2. Force complete anyway:       kb-done $working_id --force"
                    echo "═══════════════════════════════════════════════════════"
                    return 1
                fi
            fi

            _kb_jq_update "$board_file" \
                '.backlog[$idx].status = "completed" |
                 .backlog[$idx].completedAt = $ts |
                 .backlog[$idx].updatedAt = $ts |
                 del(.backlog[$idx].activelyWorking) |
                 del(.backlog[$idx].workStartedAt) |
                 del(.backlog[$idx].worktree) |
                 del(.backlog[$idx].worktreeBranch) |
                 del(.backlog[$idx].worktreeWindowId) |
                 .lastUpdated = $ts' \
                --argjson idx "$item_idx" --arg ts "$timestamp"
            item_found=true
        fi
    fi

    if [[ "$item_found" == "false" ]]; then
        echo "Error: Item not found: $working_id"
        return 1
    fi

    echo "Task completed!"

    # XACA-0054: Sync to release manifests via LCARS server
    _kb_release_sync "$working_id"

    # Auto-unblock dependents when a main item is completed (XACA-0020)
    if [[ ! "$working_id" =~ ^X[A-Z]{3}-[0-9]+-[0-9]+$ ]]; then
        local unblocked_items
        unblocked_items=$(_kb_check_unblock_dependents "$board_file" "$working_id")
        if [[ -n "$unblocked_items" ]]; then
            echo "─────────────────────────────────────"
            echo "🔓 Auto-unblocked items: $unblocked_items"
        fi
    fi

    _kb_remove_window
}

# Cancel the current item/subitem without completing it
# Usage: kb-cancel [item-id] [--reason "text"]
kb-cancel() {
    local context team terminal window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    # Get working_id from argument or from activeWindows
    local working_id explicit_id_provided=false reason=""
    if [[ -n "$1" ]] && [[ "$1" != "--reason" ]]; then
        # Use provided item ID
        working_id="$1"
        explicit_id_provided=true
        shift

        # When explicit ID is provided, derive correct board file from ID prefix
        local id_team
        id_team=$(_kb_get_team_from_code "$working_id")
        if [[ -n "$id_team" ]]; then
            board_file=$(_kb_get_board_file "$id_team")
        fi
    else
        # Get current workingOnId from activeWindows
        working_id=$(_kb_jq_read "$board_file" \
            '.activeWindows[] | select(.id == $wid) | .workingOnId // empty' \
            --arg wid "$window_id" -r)
    fi

    # Parse --reason flag
    if [[ "$1" == "--reason" ]]; then
        reason="$2"
    elif [[ "$2" == "--reason" ]]; then
        reason="$3"
    fi

    if [[ -z "$working_id" ]]; then
        echo "Error: No item ID provided and not currently working on any item"
        return 1
    fi

    # Check for --force flag (allows cancelling items with incomplete subitems)
    local force_cancel=false
    if [[ "$1" == "--force" ]] || [[ "$2" == "--force" ]] || [[ "$3" == "--force" ]]; then
        force_cancel=true
    fi

    local timestamp item_found=false
    timestamp=$(_kb_get_timestamp)

    # Check if it's a subitem or item and mark as cancelled
    if [[ "$working_id" =~ ^X[A-Z]{3}-[0-9]+-[0-9]+$ ]]; then
        # Subitem - mark cancelled with timestamp
        local parent_id="${working_id%-*}"
        local parent_idx
        parent_idx=$(_kb_find_by_id "$board_file" "$parent_id")
        if [[ "$parent_idx" -ge 0 ]]; then
            local update_jq='.backlog[$pidx].subitems = [.backlog[$pidx].subitems[] |
                if .id == $subId then
                    .status = "cancelled" |
                    .cancelledAt = $ts |
                    .updatedAt = $ts |
                    del(.activelyWorking, .workStartedAt, .worktree, .worktreeBranch, .worktreeWindowId)'
            if [[ -n "$reason" ]]; then
                update_jq="$update_jq | .cancelledReason = \$reason"
            fi
            update_jq="$update_jq else . end
            ] |
            .backlog[\$pidx].updatedAt = \$ts |
            .lastUpdated = \$ts"

            if [[ -n "$reason" ]]; then
                _kb_jq_update "$board_file" "$update_jq" \
                    --argjson pidx "$parent_idx" --arg subId "$working_id" \
                    --arg ts "$timestamp" --arg reason "$reason"
            else
                _kb_jq_update "$board_file" "$update_jq" \
                    --argjson pidx "$parent_idx" --arg subId "$working_id" \
                    --arg ts "$timestamp"
            fi
            item_found=true
        fi
    else
        # Main item - mark cancelled with timestamp
        local item_idx
        item_idx=$(_kb_find_by_id "$board_file" "$working_id")
        if [[ "$item_idx" -ge 0 ]]; then
            # Check if all subitems are resolved (unless --force is used)
            if [[ "$force_cancel" == "false" ]]; then
                local incomplete_subitems
                incomplete_subitems=$(_kb_jq_read "$board_file" '
                    .backlog[$idx].subitems // [] |
                    map(select(.status != "completed" and .status != "cancelled")) |
                    map(.id + " - " + .title) |
                    .[]
                ' --argjson idx "$item_idx" -r 2>/dev/null)

                if [[ -n "$incomplete_subitems" ]]; then
                    echo "═══════════════════════════════════════════════════════"
                    echo "❌ Cannot cancel item: Incomplete subitems found"
                    echo "═══════════════════════════════════════════════════════"
                    echo ""
                    echo "The following subitems must be resolved first:"
                    echo "$incomplete_subitems" | while read -r line; do
                        echo "  • $line"
                    done
                    echo ""
                    echo "Options:"
                    echo "  1. Complete/cancel subitems first: kb-done/kb-cancel <subitem-id>"
                    echo "  2. Force cancel anyway:            kb-cancel $working_id --force"
                    echo "═══════════════════════════════════════════════════════"
                    return 1
                fi
            fi

            local update_jq='.backlog[$idx].status = "cancelled" |
                .backlog[$idx].cancelledAt = $ts |
                .backlog[$idx].updatedAt = $ts |
                del(.backlog[$idx].activelyWorking) |
                del(.backlog[$idx].workStartedAt) |
                del(.backlog[$idx].worktree) |
                del(.backlog[$idx].worktreeBranch) |
                del(.backlog[$idx].worktreeWindowId)'
            if [[ -n "$reason" ]]; then
                update_jq="$update_jq | .backlog[\$idx].cancelledReason = \$reason"
            fi
            update_jq="$update_jq | .lastUpdated = \$ts"

            if [[ -n "$reason" ]]; then
                _kb_jq_update "$board_file" "$update_jq" \
                    --argjson idx "$item_idx" --arg ts "$timestamp" --arg reason "$reason"
            else
                _kb_jq_update "$board_file" "$update_jq" \
                    --argjson idx "$item_idx" --arg ts "$timestamp"
            fi
            item_found=true
        fi
    fi

    if [[ "$item_found" == "false" ]]; then
        echo "Error: Item not found: $working_id"
        return 1
    fi

    echo "Task cancelled!"

    # XACA-0054: Sync to release manifests via LCARS server
    if type _kb_release_sync >/dev/null 2>&1; then
        _kb_release_sync "$working_id"
    fi

    # Auto-unblock dependents when a main item is cancelled (XACA-0075)
    if [[ ! "$working_id" =~ ^X[A-Z]{3}-[0-9]+-[0-9]+$ ]]; then
        local unblocked_items
        unblocked_items=$(_kb_check_unblock_dependents "$board_file" "$working_id")
        if [[ -n "$unblocked_items" ]]; then
            echo "─────────────────────────────────────"
            echo "🔓 Auto-unblocked items: $unblocked_items"
        fi
    fi

    _kb_remove_window
}

# Stop working on the current item/subitem without completing it
# Usage: kb-stop-working
kb-stop-working() {
    local context team terminal window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    # Get current workingOnId
    local working_id
    working_id=$(_kb_jq_read "$board_file" \
        '.activeWindows[] | select(.id == $wid) | .workingOnId // empty' \
        --arg wid "$window_id" -r)

    if [[ -z "$working_id" ]]; then
        echo "Not currently working on any item"
        return 0
    fi

    local timestamp
    timestamp=$(_kb_get_timestamp)

    # Check if it's a subitem (format: XFRE-0001-001) or item (format: XFRE-0001)
    if [[ "$working_id" =~ ^X[A-Z]{3}-[0-9]+-[0-9]+$ ]]; then
        # It's a subitem - extract parent ID and find subitem by ID
        local parent_id="${working_id%-*}"
        local parent_idx
        parent_idx=$(_kb_find_by_id "$board_file" "$parent_id")

        if [[ "$parent_idx" -ge 0 ]]; then
            # Find subitem index by ID and clear its activelyWorking flag and worktree info
            _kb_jq_update "$board_file" '
                .backlog[$pidx].subitems = [.backlog[$pidx].subitems[] |
                    if .id == $subId then del(.activelyWorking, .workStartedAt, .worktree, .worktreeBranch, .worktreeWindowId) else . end
                ] |
                .lastUpdated = $ts
            ' --argjson pidx "$parent_idx" --arg subId "$working_id" --arg ts "$timestamp"
            echo "Cleared activelyWorking on subitem: $working_id"
        fi
    else
        # It's a main item
        local item_idx
        item_idx=$(_kb_find_by_id "$board_file" "$working_id")

        if [[ "$item_idx" -ge 0 ]]; then
            _kb_jq_update "$board_file" \
                'del(.backlog[$idx].activelyWorking) |
                 del(.backlog[$idx].workStartedAt) |
                 del(.backlog[$idx].worktree) |
                 del(.backlog[$idx].worktreeBranch) |
                 del(.backlog[$idx].worktreeWindowId) |
                 .lastUpdated = $ts' \
                --argjson idx "$item_idx" --arg ts "$timestamp"
            echo "Cleared activelyWorking on item: $working_id"
        fi
    fi

    # Clear workingOnId from window
    _kb_clear_working_on
    echo "Stopped working on: $working_id"
}

# Unified backlog management
# Usage: kb-backlog <command> [args...]
kb-backlog() {
    _kb_ensure_jq || return 1

    local cmd="$1"
    shift 2>/dev/null

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    case "$cmd" in
        add)
            local task="$1"
            local priority="${2:-medium}"
            local description="${3:-}"
            local jira_id="${4:-}"
            local os_param="${5:-}"

            # Normalize priority shortcuts
            [[ "$priority" == "med" ]] && priority="medium"
            [[ "$priority" == "crit" ]] && priority="critical"
            [[ "$priority" == "block" ]] && priority="blocked"

            # Validate priority
            local valid_priorities=("low" "medium" "high" "critical" "blocked")
            if [[ ! " ${valid_priorities[*]} " =~ " ${priority} " ]]; then
                echo "Error: Invalid priority '$priority'"
                echo "Valid priorities: ${valid_priorities[*]}"
                return 1
            fi

            # Validate and normalize OS parameter (case-insensitive)
            local normalized_os=""
            if [[ -n "$os_param" ]]; then
                local os_lower="${os_param,,}"  # Convert to lowercase
                case "$os_lower" in
                    ios) normalized_os="iOS" ;;
                    android) normalized_os="Android" ;;
                    firebase) normalized_os="Firebase" ;;
                    *)
                        echo "Error: Invalid OS '$os_param'"
                        echo "Valid OS values: iOS | Android | Firebase"
                        return 1
                        ;;
                esac
            fi

            if [[ -z "$task" ]]; then
                echo "Usage: kb-backlog add \"task\" [priority] [\"description\"] [jira-id] [os]"
                echo "Priority: low | med | medium | high | crit | critical | block | blocked"
                echo "Description: Optional multi-line description (max 5 lines displayed)"
                echo "JIRA ID: Optional JIRA ticket ID (e.g., ME-123, PROJ-456)"
                echo "OS: Optional platform - iOS | Android | Firebase"
                return 1
            fi

            local timestamp item_id
            timestamp=$(_kb_get_timestamp)
            item_id=$(_kb_generate_id "$board_file" "$team")

            # Build the backlog item with optional fields
            local jq_filter='.backlog += [{"id": $id, "title": $title, "priority": $priority, "addedAt": $timestamp'
            local jq_args=(--arg id "$item_id" --arg title "$task" --arg priority "$priority" --arg timestamp "$timestamp")

            if [[ -n "$description" ]]; then
                jq_filter+=', "description": $desc'
                jq_args+=(--arg desc "$description")
            fi

            if [[ -n "$jira_id" ]]; then
                jq_filter+=', "jiraId": $jira'
                jq_args+=(--arg jira "$jira_id")
            fi

            # Add OS as first element of tags array if specified
            if [[ -n "$normalized_os" ]]; then
                jq_filter+=', "tags": [$os]'
                jq_args+=(--arg os "$normalized_os")
            fi

            jq_filter+='}] | .lastUpdated = $timestamp'

            # Add with exclusive locking and increment ID counter
            _kb_jq_update "$board_file" "$jq_filter" "${jq_args[@]}"
            _kb_increment_id "$board_file"

            echo "✓ Added [$item_id]: $task [$priority]"
            [[ -n "$jira_id" ]] && echo "  JIRA: $jira_id"
            [[ -n "$normalized_os" ]] && echo "  OS: $normalized_os"
            [[ -n "$description" ]] && echo "  Description: ${description:0:50}..."
            ;;

        list|ls)
            local count
            count=$(_kb_jq_read "$board_file" '.backlog | length')

            echo "Backlog for ${team}: ($count items)"
            echo "─────────────────────────────────────"
            if [[ "$count" -eq 0 ]]; then
                echo "  (empty)"
            else
                _kb_jq_read "$board_file" '.backlog[] | "  [\(.id // "?")] \(.priority | ascii_upcase | .[0:3]) \(.title)"' -r
            fi
            echo "─────────────────────────────────────"
            ;;

        change|edit)
            local selector="$1"
            local arg2="$2"
            local arg3="$3"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog change <id> [\"new title\"] [priority]"
                echo "Examples:"
                echo "  kb-backlog change XFRE-0001 \"Updated title\""
                echo "  kb-backlog change XFRE-0001 high"
                echo "  kb-backlog change XFRE-0001 \"Updated title\" high"
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists (with locking)
            local current_title current_priority item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            current_priority=$(_kb_jq_read "$board_file" ".backlog[$index].priority // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local new_title="$current_title"
            local new_priority="$current_priority"

            # Detect what arg2 is (title or priority)
            if [[ -n "$arg2" ]]; then
                if [[ "$arg2" =~ ^(low|med|medium|high|crit|critical|block|blocked)$ ]]; then
                    new_priority="$arg2"
                    [[ "$new_priority" == "med" ]] && new_priority="medium"
                    [[ "$new_priority" == "crit" ]] && new_priority="critical"
                    [[ "$new_priority" == "block" ]] && new_priority="blocked"
                else
                    new_title="$arg2"
                fi
            fi

            # arg3 is always priority if provided
            if [[ -n "$arg3" ]]; then
                new_priority="$arg3"
                [[ "$new_priority" == "med" ]] && new_priority="medium"
                [[ "$new_priority" == "crit" ]] && new_priority="critical"
                [[ "$new_priority" == "block" ]] && new_priority="blocked"
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Update with exclusive locking (add updatedAt timestamp)
            _kb_jq_update "$board_file" \
               '.backlog[$idx].title = $title | .backlog[$idx].priority = $priority | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
               --argjson idx "$index" \
               --arg title "$new_title" \
               --arg priority "$new_priority" \
               --arg timestamp "$timestamp"

            echo "✓ Updated [$item_id]: $new_title [$new_priority]"

            # Sync to release manifests (best-effort)
            _kb_release_sync "$item_id"
            ;;

        remove|rm)
            local selector="$1"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog remove <id>"
                echo "Example: kb-backlog remove XFRE-0001"
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local title item_id timestamp
            title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)
            timestamp=$(_kb_get_timestamp)

            if [[ -z "$title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Remove with exclusive locking
            _kb_jq_update "$board_file" \
               'del(.backlog[$idx]) | .lastUpdated = $timestamp' \
               --argjson idx "$index" \
               --arg timestamp "$timestamp"
            echo "✓ Removed [$item_id]: $title"
            ;;

        jira)
            local selector="$1"
            local new_jira="$2"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog jira <id> <JIRA-ID>"
                echo "       kb-backlog jira <id> -        (clear JIRA ID)"
                echo ""
                echo "Set or update the JIRA ID for a backlog item."
                echo "Example: kb-backlog jira XFRE-0001 ME-123"
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Handle clearing JIRA ID with "-"
            if [[ "$new_jira" == "-" ]]; then
                _kb_jq_update "$board_file" \
                   'del(.backlog[$idx].jiraId) | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg timestamp "$timestamp"
                echo "✓ Cleared JIRA ID for [$item_id]: $current_title"
            elif [[ -n "$new_jira" ]]; then
                # Validate Jira ID (warns but allows)
                _kb_validate_jira_id "$new_jira"

                _kb_jq_update "$board_file" \
                   '.backlog[$idx].jiraId = $jira | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg jira "$new_jira" \
                   --arg timestamp "$timestamp"
                echo "✓ Set JIRA ID for [$item_id]: $current_title"
                echo "  JIRA: $new_jira"
            else
                # Show current JIRA ID
                local current_jira
                current_jira=$(_kb_jq_read "$board_file" ".backlog[$index].jiraId // empty" -r)
                echo "[$item_id] $current_title"
                if [[ -n "$current_jira" ]]; then
                    echo "  JIRA: $current_jira"
                else
                    echo "  (no JIRA ID)"
                fi
            fi
            ;;

        github|gh)
            local selector="$1"
            local new_github="$2"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog github <id> <issue-ref>"
                echo "       kb-backlog github <id> -          (clear GitHub issue)"
                echo ""
                echo "Set or update the GitHub issue for a backlog item."
                echo ""
                echo "Issue formats:"
                echo "  #123              Shorthand (uses team default repo)"
                echo "  owner/repo#123    Full format (explicit repo)"
                echo ""
                echo "Team default repos:"
                echo "  academy   -> doublenode/dev-team"
                echo "  dns       -> doublenode/dns-framework"
                echo "  freelance -> doublenode/dev-team"
                echo ""
                echo "Examples:"
                echo "  kb-backlog github XFRE-0001 #42"
                echo "  kb-backlog github XFRE-0001 anthropics/claude-code#123"
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Handle clearing GitHub issue with "-"
            if [[ "$new_github" == "-" ]]; then
                _kb_jq_update "$board_file" \
                   'del(.backlog[$idx].githubIssue) | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg timestamp "$timestamp"
                echo "✓ Cleared GitHub issue for [$item_id]: $current_title"
            elif [[ -n "$new_github" ]]; then
                _kb_jq_update "$board_file" \
                   '.backlog[$idx].githubIssue = $gh | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg gh "$new_github" \
                   --arg timestamp "$timestamp"
                echo "✓ Set GitHub issue for [$item_id]: $current_title"
                echo "  GitHub: $new_github"
            else
                # Show current GitHub issue
                local current_github
                current_github=$(_kb_jq_read "$board_file" ".backlog[$index].githubIssue // empty" -r)
                echo "[$item_id] $current_title"
                if [[ -n "$current_github" ]]; then
                    echo "  GitHub: $current_github"
                else
                    echo "  (no GitHub issue)"
                fi
            fi
            ;;

        desc|description)
            local selector="$1"
            local new_desc="$2"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog desc <id> \"description\""
                echo "       kb-backlog desc <id> -       (clear description)"
                echo ""
                echo "Set or update the description for a backlog item."
                echo "Descriptions are displayed under the title (max 5 lines)."
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Handle clearing description with "-"
            if [[ "$new_desc" == "-" ]]; then
                _kb_jq_update "$board_file" \
                   'del(.backlog[$idx].description) | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg timestamp "$timestamp"
                echo "✓ Cleared description for [$item_id]: $current_title"
            elif [[ -n "$new_desc" ]]; then
                _kb_jq_update "$board_file" \
                   '.backlog[$idx].description = $desc | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg desc "$new_desc" \
                   --arg timestamp "$timestamp"
                echo "✓ Set description for [$item_id]: $current_title"
                echo "  ${new_desc:0:60}..."
            else
                # Show current description
                local current_desc
                current_desc=$(_kb_jq_read "$board_file" ".backlog[$index].description // empty" -r)
                echo "[$item_id] $current_title"
                if [[ -n "$current_desc" ]]; then
                    echo "─────────────────────────────────────"
                    echo "$current_desc"
                else
                    echo "(no description)"
                fi
            fi
            ;;

        tag|tags)
            local selector="$1"
            shift 2>/dev/null
            local tag_args=("$@")

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog tag <id> [add|rm|clear] [tag-name...]"
                echo ""
                echo "Manage tags for a backlog item. Tags appear as clickable pills in LCARS UI."
                echo ""
                echo "Commands:"
                echo "  kb-backlog tag <id>                   View current tags"
                echo "  kb-backlog tag <id> add \"tag1\" ...   Add one or more tags"
                echo "  kb-backlog tag <id> rm \"tag1\" ...    Remove specific tags"
                echo "  kb-backlog tag <id> clear             Remove all tags"
                echo "  kb-backlog tag <id> \"tag1\" \"tag2\"    Set tags (replaces existing)"
                echo ""
                echo "Examples:"
                echo "  kb-backlog tag XFRE-0001 add iOS refactor"
                echo "  kb-backlog tag XFRE-0001 rm testing"
                echo "  kb-backlog tag XFRE-0001 feature iOS urgent"
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # No args - show current tags
            if [[ ${#tag_args[@]} -eq 0 ]]; then
                local current_tags
                current_tags=$(_kb_jq_read "$board_file" ".backlog[$index].tags // [] | join(\", \")" -r)
                echo "[$item_id] $current_title"
                if [[ -n "$current_tags" ]]; then
                    echo "  Tags: $current_tags"
                else
                    echo "  (no tags)"
                fi
                return 0
            fi

            local subcmd="${tag_args[1]}"

            case "$subcmd" in
                add)
                    # Add tags to existing array
                    shift
                    local new_tags=("${tag_args[@]:1}")
                    if [[ ${#new_tags[@]} -eq 0 ]]; then
                        echo "Usage: kb-backlog tag <id> add \"tag1\" \"tag2\" ..."
                        return 1
                    fi
                    local tags_json
                    tags_json=$(printf '%s\n' "${new_tags[@]}" | jq -R . | jq -s .)
                    _kb_jq_update "$board_file" \
                       '.backlog[$idx].tags = ((.backlog[$idx].tags // []) + $tags | unique) | .backlog[$idx].updatedAt = $ts | .lastUpdated = $ts' \
                       --argjson idx "$index" \
                       --argjson tags "$tags_json" \
                       --arg ts "$timestamp"
                    echo "✓ Added tags to [$item_id]: ${new_tags[*]}"

                    # Sync to release manifests (best-effort)
                    _kb_release_sync "$item_id"
                    ;;

                rm|remove)
                    # Remove specific tags
                    shift
                    local rm_tags=("${tag_args[@]:1}")
                    if [[ ${#rm_tags[@]} -eq 0 ]]; then
                        echo "Usage: kb-backlog tag <id> rm \"tag1\" \"tag2\" ..."
                        return 1
                    fi
                    local rm_json
                    rm_json=$(printf '%s\n' "${rm_tags[@]}" | jq -R . | jq -s .)
                    _kb_jq_update "$board_file" \
                       '.backlog[$idx].tags = ((.backlog[$idx].tags // []) - $tags) | .backlog[$idx].updatedAt = $ts | .lastUpdated = $ts' \
                       --argjson idx "$index" \
                       --argjson tags "$rm_json" \
                       --arg ts "$timestamp"
                    echo "✓ Removed tags from [$item_id]: ${rm_tags[*]}"

                    # Sync to release manifests (best-effort)
                    _kb_release_sync "$item_id"
                    ;;

                clear)
                    # Remove all tags
                    _kb_jq_update "$board_file" \
                       'del(.backlog[$idx].tags) | .backlog[$idx].updatedAt = $ts | .lastUpdated = $ts' \
                       --argjson idx "$index" \
                       --arg ts "$timestamp"
                    echo "✓ Cleared all tags from [$item_id]: $current_title"

                    # Sync to release manifests (best-effort)
                    _kb_release_sync "$item_id"
                    ;;

                *)
                    # Set tags directly (replaces existing)
                    local set_tags=("${tag_args[@]}")
                    local set_json
                    set_json=$(printf '%s\n' "${set_tags[@]}" | jq -R . | jq -s .)
                    _kb_jq_update "$board_file" \
                       '.backlog[$idx].tags = $tags | .backlog[$idx].updatedAt = $ts | .lastUpdated = $ts' \
                       --argjson idx "$index" \
                       --argjson tags "$set_json" \
                       --arg ts "$timestamp"
                    echo "✓ Set tags for [$item_id]: ${set_tags[*]}"

                    # Sync to release manifests (best-effort)
                    _kb_release_sync "$item_id"
                    ;;
            esac
            ;;

        priority|pri)
            local selector="$1"
            local new_priority="$2"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog priority <id> [priority]"
                echo "       kb-backlog priority <id> -        (clear/reset to medium)"
                echo ""
                echo "Set, view, or reset the priority for a backlog item."
                echo ""
                echo "Valid priorities:"
                echo "  critical (crit) - Urgent, needs immediate attention"
                echo "  high            - Important, prioritize soon"
                echo "  medium (med)    - Normal priority (default)"
                echo "  low             - Can wait, lower importance"
                echo "  blocked (block) - Waiting on external dependency"
                echo ""
                echo "Example: kb-backlog priority XFRE-0001 high"
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id current_priority
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)
            current_priority=$(_kb_jq_read "$board_file" ".backlog[$index].priority // \"medium\"" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Handle clearing/resetting priority with "-"
            if [[ "$new_priority" == "-" ]]; then
                _kb_jq_update "$board_file" \
                   '.backlog[$idx].priority = "medium" | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg timestamp "$timestamp"
                echo "✓ Reset priority to medium for [$item_id]: $current_title"

                # Sync to release manifests (best-effort)
                _kb_release_sync "$item_id"
            elif [[ -n "$new_priority" ]]; then
                # Normalize priority aliases
                case "$new_priority" in
                    med) new_priority="medium" ;;
                    crit) new_priority="critical" ;;
                    block) new_priority="blocked" ;;
                esac

                # Validate priority
                if [[ ! "$new_priority" =~ ^(low|medium|high|critical|blocked)$ ]]; then
                    echo "Error: Invalid priority. Use: low, medium (med), high, critical (crit), or blocked (block)"
                    return 1
                fi

                _kb_jq_update "$board_file" \
                   '.backlog[$idx].priority = $priority | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg priority "$new_priority" \
                   --arg timestamp "$timestamp"
                echo "✓ Set priority for [$item_id]: $current_title"
                echo "  Priority: $new_priority"

                # Sync to release manifests (best-effort)
                _kb_release_sync "$item_id"
            else
                # Show current priority
                echo "[$item_id] $current_title"
                echo "  Priority: $current_priority"
            fi
            ;;

        due|deadline)
            local selector="$1"
            local new_due="$2"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog due <id> <YYYY-MM-DD>"
                echo "       kb-backlog due <id> -        (clear due date)"
                echo ""
                echo "Set or clear the due date for a backlog item."
                echo "Due dates appear as colored pills in LCARS UI."
                echo ""
                echo "Color coding:"
                echo "  Overdue: Red (pulsing)"
                echo "  Today: Orange"
                echo "  1-7 days: Green→Orange gradient"
                echo "  8+ days: Dark green"
                echo ""
                echo "Example: kb-backlog due XFRE-0001 2026-01-20"
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Handle clearing due date with "-"
            if [[ "$new_due" == "-" ]]; then
                _kb_jq_update "$board_file" \
                   'del(.backlog[$idx].dueDate) | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg timestamp "$timestamp"
                echo "✓ Cleared due date for [$item_id]: $current_title"
            elif [[ -n "$new_due" ]]; then
                # Validate date format (YYYY-MM-DD)
                if [[ ! "$new_due" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                    echo "Error: Invalid date format. Use YYYY-MM-DD (e.g., 2026-01-20)"
                    return 1
                fi
                _kb_jq_update "$board_file" \
                   '.backlog[$idx].dueDate = $due | .backlog[$idx].updatedAt = $timestamp | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg due "$new_due" \
                   --arg timestamp "$timestamp"
                echo "✓ Set due date for [$item_id]: $current_title"
                echo "  Due: $new_due"
            else
                # Show current due date
                local current_due
                current_due=$(_kb_jq_read "$board_file" ".backlog[$index].dueDate // empty" -r)
                echo "[$item_id] $current_title"
                if [[ -n "$current_due" ]]; then
                    echo "  Due: $current_due"
                else
                    echo "  (no due date)"
                fi
            fi
            ;;

        toggle)
            local selector="$1"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog toggle <id>"
                echo "Toggle collapsed state for a backlog item with subitems."
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp current_collapsed
            timestamp=$(_kb_get_timestamp)
            # Note: Can't use // true because jq treats false the same as null
            current_collapsed=$(_kb_jq_read "$board_file" "if .backlog[$index].collapsed == null then true else .backlog[$index].collapsed end" -r)

            if [[ "$current_collapsed" == "true" ]]; then
                _kb_jq_update "$board_file" \
                   '.backlog[$idx].collapsed = false | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg timestamp "$timestamp"
                echo "✓ Expanded [$item_id]: $current_title"
            else
                _kb_jq_update "$board_file" \
                   '.backlog[$idx].collapsed = true | .lastUpdated = $timestamp' \
                   --argjson idx "$index" \
                   --arg timestamp "$timestamp"
                echo "✓ Collapsed [$item_id]: $current_title"
            fi
            ;;

        unpick)
            local selector="$1"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog unpick <id>"
                echo "Clears the actively working flag on a backlog item."
                return 1
            fi

            # Resolve selector to index
            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            # Check if item exists
            local current_title item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Clear activelyWorking flag and worktree info
            _kb_jq_update "$board_file" \
               'del(.backlog[$idx].activelyWorking) |
                del(.backlog[$idx].workStartedAt) |
                del(.backlog[$idx].worktree) |
                del(.backlog[$idx].worktreeBranch) |
                del(.backlog[$idx].worktreeWindowId) |
                .lastUpdated = $timestamp' \
               --argjson idx "$index" \
               --arg timestamp "$timestamp"

            echo "✓ Stopped working on [$item_id]: $current_title"
            ;;

        sub|subitem)
            local subcmd="$1"
            shift 2>/dev/null

            case "$subcmd" in
                add)
                    local parent_selector="$1"
                    local sub_title="$2"
                    local sub_jira="$3"
                    local sub_os_param="$4"

                    if [[ -z "$parent_selector" ]] || [[ -z "$sub_title" ]]; then
                        echo "Usage: kb-backlog sub add <parent-id> \"title\" [jira-id] [os]"
                        echo "OS: Optional platform - iOS | Android | Firebase"
                        return 1
                    fi

                    # Validate and normalize OS parameter (case-insensitive)
                    local sub_normalized_os=""
                    if [[ -n "$sub_os_param" ]]; then
                        local sub_os_lower="${sub_os_param,,}"  # Convert to lowercase
                        case "$sub_os_lower" in
                            ios) sub_normalized_os="iOS" ;;
                            android) sub_normalized_os="Android" ;;
                            firebase) sub_normalized_os="Firebase" ;;
                            *)
                                echo "Error: Invalid OS '$sub_os_param'"
                                echo "Valid OS values: iOS | Android | Firebase"
                                return 1
                                ;;
                        esac
                    fi

                    # Resolve parent selector
                    local parent_idx
                    parent_idx=$(_kb_resolve_selector "$board_file" "$parent_selector")

                    if [[ "$parent_idx" == "-1" ]]; then
                        echo "Error: Parent item not found: $parent_selector"
                        return 1
                    fi

                    # Check parent exists
                    local parent_title parent_id
                    parent_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].title // empty" -r)
                    parent_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].id // empty" -r)
                    if [[ -z "$parent_title" ]]; then
                        echo "Error: Parent item not found: $parent_selector"
                        return 1
                    fi

                    local timestamp sub_id sub_count
                    timestamp=$(_kb_get_timestamp)
                    # Generate subitem ID: <parent-id>-### (3 digits starting at 001)
                    sub_count=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems // [] | length" -r)
                    sub_id=$(printf "%s-%03d" "$parent_id" "$((sub_count + 1))")

                    # Build subitem with optional JIRA and OS
                    local jq_filter='.backlog[$idx].subitems = ((.backlog[$idx].subitems // []) + [{"id": $subid, "title": $title, "status": "todo", "addedAt": $ts'
                    local jq_args=(--argjson idx "$parent_idx" --arg subid "$sub_id" --arg title "$sub_title" --arg ts "$timestamp")

                    if [[ -n "$sub_jira" ]]; then
                        jq_filter+=', "jiraKey": $jira'
                        jq_args+=(--arg jira "$sub_jira")
                    fi

                    # Add OS as first element of tags array if specified
                    if [[ -n "$sub_normalized_os" ]]; then
                        jq_filter+=', "tags": [$os]'
                        jq_args+=(--arg os "$sub_normalized_os")
                    fi

                    jq_filter+='}]) | .lastUpdated = $ts'

                    _kb_jq_update "$board_file" "$jq_filter" "${jq_args[@]}"
                    echo "✓ Added subitem to [$parent_id]: $sub_title"
                    [[ -n "$sub_normalized_os" ]] && echo "  OS: $sub_normalized_os"
                    ;;

                list|ls)
                    local parent_idx="$1"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub list <parent-index>"
                        return 1
                    fi

                    local parent_title
                    parent_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].title // empty" -r)
                    if [[ -z "$parent_title" ]]; then
                        echo "Error: No item at index $parent_idx"
                        return 1
                    fi

                    local sub_count
                    sub_count=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems // [] | length" -r)

                    echo "[$parent_idx] $parent_title"
                    echo "─────────────────────────────────────"
                    if [[ "$sub_count" -eq 0 ]]; then
                        echo "  (no subitems)"
                    else
                        _kb_jq_read "$board_file" ".backlog[$parent_idx].subitems | to_entries[] | \"  [\(.key)] [\(.value.status | ascii_upcase | .[0:4])] \(.value.title)\(if .value.jiraKey then \" (\(.value.jiraKey))\" else \"\" end)\"" --argjson idx "$parent_idx" -r
                    fi
                    ;;

                remove|rm)
                    local parent_idx="$1"
                    local sub_idx="$2"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub remove <parent-index> <subitem-index>"
                        return 1
                    fi

                    local sub_title
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    _kb_jq_update "$board_file" \
                       'del(.backlog[$pidx].subitems[$sidx]) | .lastUpdated = $ts' \
                       --argjson pidx "$parent_idx" \
                       --argjson sidx "$sub_idx" \
                       --arg ts "$timestamp"
                    echo "✓ Removed subitem: $sub_title"
                    ;;

                done)
                    local arg1="$1"
                    local arg2="$2"
                    local parent_idx sub_idx

                    if [[ -z "$arg1" ]]; then
                        echo "Usage: kb-backlog sub done <subitem-id>"
                        echo "   or: kb-backlog sub done <parent-id> <subitem-index>"
                        echo "Marks subitem as completed."
                        return 1
                    fi

                    # Check if it's a single subitem ID (e.g., XFRE-0001-001)
                    if [[ -z "$arg2" ]] && [[ "$arg1" =~ ^X[A-Z]{2,4}-[0-9]+-[0-9]+$ ]]; then
                        # Single argument: subitem ID
                        local resolved
                        resolved=$(_kb_resolve_subitem_id "$board_file" "$arg1")
                        parent_idx="${resolved%%:*}"
                        sub_idx="${resolved##*:}"

                        if [[ "$parent_idx" == "-1" ]]; then
                            echo "Error: Subitem not found: $arg1"
                            return 1
                        fi
                    elif [[ -n "$arg2" ]] && [[ "$arg2" =~ ^[0-9]+$ ]]; then
                        # Two arguments: parent selector + subitem index
                        parent_idx=$(_kb_resolve_selector "$board_file" "$arg1")
                        sub_idx="$arg2"

                        if [[ "$parent_idx" == "-1" ]]; then
                            echo "Error: Parent item not found: $arg1"
                            return 1
                        fi
                    else
                        echo "Usage: kb-backlog sub done <subitem-id>"
                        echo "   or: kb-backlog sub done <parent-id> <subitem-index>"
                        return 1
                    fi

                    local sub_title sub_id
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    sub_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].id // empty" -r)

                    if [[ -z "$sub_title" ]]; then
                        echo "Error: Subitem not found at index $sub_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    # XACA-0029: Calculate and accumulate work time
                    local work_started_at existing_time_ms total_time_ms
                    work_started_at=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].workStartedAt // empty" -r)
                    existing_time_ms=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].timeWorkedMs // 0")
                    total_time_ms="$existing_time_ms"

                    if [[ -n "$work_started_at" ]]; then
                        # Calculate elapsed time in milliseconds
                        local start_epoch now_epoch elapsed_ms
                        # Strip Z suffix and parse as UTC (macOS date -j -f ignores timezone suffix)
                        start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${work_started_at%Z}" "+%s" 2>/dev/null || echo "0")
                        now_epoch=$(date -u "+%s")
                        if [[ "$start_epoch" != "0" ]] && [[ "$start_epoch" -gt 0 ]]; then
                            elapsed_ms=$(( (now_epoch - start_epoch) * 1000 ))
                            total_time_ms=$(( existing_time_ms + elapsed_ms ))
                        fi
                    fi

                    _kb_jq_update "$board_file" \
                       '.backlog[$pidx].subitems[$sidx].status = "completed" |
                        .backlog[$pidx].subitems[$sidx].completedAt = $ts |
                        .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
                        .backlog[$pidx].subitems[$sidx].timeWorkedMs = ($timeMs | tonumber) |
                        .backlog[$pidx].updatedAt = $ts |
                        del(.backlog[$pidx].subitems[$sidx].activelyWorking) |
                        del(.backlog[$pidx].subitems[$sidx].workStartedAt) |
                        del(.backlog[$pidx].subitems[$sidx].worktree) |
                        del(.backlog[$pidx].subitems[$sidx].worktreeBranch) |
                        del(.backlog[$pidx].subitems[$sidx].worktreeWindowId) |
                        .lastUpdated = $ts' \
                       --argjson pidx "$parent_idx" \
                       --argjson sidx "$sub_idx" \
                       --arg ts "$timestamp" \
                       --arg timeMs "$total_time_ms"
                    echo "✓ Completed [$sub_id]: $sub_title"

                    # XACA-0054: Sync to release manifests via LCARS server
                    _kb_release_sync "$sub_id"

                    # Clear working-on state since subitem is done
                    _kb_clear_working_on

                    # XACA-0025: Trigger auto-unblock for items blocked by this subitem
                    if [[ -n "$sub_id" ]]; then
                        _kb_check_unblock_dependents "$board_file" "$sub_id"
                    fi
                    ;;

                cancel)
                    local arg1="$1"
                    local arg2="$2"
                    local arg3="$3"
                    local parent_idx sub_idx reason=""

                    # Parse --reason flag
                    if [[ "$arg1" == "--reason" ]]; then
                        reason="$arg2"
                        arg1="$arg3"
                        arg2=""
                    elif [[ "$arg2" == "--reason" ]]; then
                        reason="$arg3"
                        arg2=""
                    fi

                    if [[ -z "$arg1" ]]; then
                        echo "Usage: kb-backlog sub cancel <subitem-id> [--reason \"text\"]"
                        echo "Marks subitem as cancelled."
                        return 1
                    fi

                    # Check if it's a single subitem ID (e.g., XFRE-0001-001)
                    if [[ -z "$arg2" ]] && [[ "$arg1" =~ ^X[A-Z]{2,4}-[0-9]+-[0-9]+$ ]]; then
                        # Single argument: subitem ID
                        local resolved
                        resolved=$(_kb_resolve_subitem_id "$board_file" "$arg1")
                        parent_idx="${resolved%%:*}"
                        sub_idx="${resolved##*:}"

                        if [[ "$parent_idx" == "-1" ]]; then
                            echo "Error: Subitem not found: $arg1"
                            return 1
                        fi
                    else
                        echo "Usage: kb-backlog sub cancel <subitem-id> [--reason \"text\"]"
                        return 1
                    fi

                    local sub_title sub_id
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    sub_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].id // empty" -r)

                    if [[ -z "$sub_title" ]]; then
                        echo "Error: Subitem not found at index $sub_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    local update_jq='.backlog[$pidx].subitems[$sidx].status = "cancelled" |
                       .backlog[$pidx].subitems[$sidx].cancelledAt = $ts |
                       .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
                       .backlog[$pidx].updatedAt = $ts |
                       del(.backlog[$pidx].subitems[$sidx].activelyWorking) |
                       del(.backlog[$pidx].subitems[$sidx].workStartedAt) |
                       del(.backlog[$pidx].subitems[$sidx].worktree) |
                       del(.backlog[$pidx].subitems[$sidx].worktreeBranch) |
                       del(.backlog[$pidx].subitems[$sidx].worktreeWindowId)'
                    if [[ -n "$reason" ]]; then
                        update_jq="$update_jq | .backlog[\$pidx].subitems[\$sidx].cancelledReason = \$reason"
                    fi
                    update_jq="$update_jq | .lastUpdated = \$ts"

                    if [[ -n "$reason" ]]; then
                        _kb_jq_update "$board_file" "$update_jq" \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg ts "$timestamp" \
                           --arg reason "$reason"
                    else
                        _kb_jq_update "$board_file" "$update_jq" \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg ts "$timestamp"
                    fi
                    echo "✓ Cancelled [$sub_id]: $sub_title"

                    # XACA-0054: Sync to release manifests via LCARS server
                    if type _kb_release_sync >/dev/null 2>&1; then
                        _kb_release_sync "$sub_id"
                    fi

                    # Clear working-on state since subitem is cancelled
                    _kb_clear_working_on

                    # XACA-0075: Trigger auto-unblock for items blocked by this subitem
                    if [[ -n "$sub_id" ]]; then
                        _kb_check_unblock_dependents "$board_file" "$sub_id"
                    fi
                    ;;

                todo)
                    local parent_idx="$1"
                    local sub_idx="$2"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub todo <parent-index> <subitem-index>"
                        return 1
                    fi

                    local sub_title
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    # XACA-0029: Calculate and accumulate work time if actively working
                    local work_started_at existing_time_ms total_time_ms
                    work_started_at=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].workStartedAt // empty" -r)
                    existing_time_ms=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].timeWorkedMs // 0")
                    total_time_ms="$existing_time_ms"

                    if [[ -n "$work_started_at" ]]; then
                        # Calculate elapsed time in milliseconds
                        local start_epoch now_epoch elapsed_ms
                        # Strip Z suffix and parse as UTC (macOS date -j -f ignores timezone suffix)
                        start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${work_started_at%Z}" "+%s" 2>/dev/null || echo "0")
                        now_epoch=$(date -u "+%s")
                        if [[ "$start_epoch" != "0" ]] && [[ "$start_epoch" -gt 0 ]]; then
                            elapsed_ms=$(( (now_epoch - start_epoch) * 1000 ))
                            total_time_ms=$(( existing_time_ms + elapsed_ms ))
                        fi
                    fi

                    _kb_jq_update "$board_file" \
                       '.backlog[$pidx].subitems[$sidx].status = "todo" |
                        .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
                        (if $timeMs != "0" then .backlog[$pidx].subitems[$sidx].timeWorkedMs = ($timeMs | tonumber) else . end) |
                        del(.backlog[$pidx].subitems[$sidx].activelyWorking) |
                        del(.backlog[$pidx].subitems[$sidx].workStartedAt) |
                        del(.backlog[$pidx].subitems[$sidx].worktree) |
                        del(.backlog[$pidx].subitems[$sidx].worktreeBranch) |
                        del(.backlog[$pidx].subitems[$sidx].worktreeWindowId) |
                        .lastUpdated = $ts' \
                       --argjson pidx "$parent_idx" \
                       --argjson sidx "$sub_idx" \
                       --arg ts "$timestamp" \
                       --arg timeMs "$total_time_ms"
                    echo "✓ Reset to todo: $sub_title"
                    ;;

                jira)
                    local parent_idx="$1"
                    local sub_idx="$2"
                    local jira_id="$3"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub jira <parent-index> <subitem-index> <JIRA-ID>"
                        echo "       kb-backlog sub jira <parent-index> <subitem-index> -  (clear)"
                        return 1
                    fi

                    local sub_title
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    if [[ "$jira_id" == "-" ]]; then
                        _kb_jq_update "$board_file" \
                           'del(.backlog[$pidx].subitems[$sidx].jiraKey) | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg ts "$timestamp"
                        echo "✓ Cleared JIRA ID for: $sub_title"
                    elif [[ -n "$jira_id" ]]; then
                        # Validate Jira ID (warns but allows)
                        _kb_validate_jira_id "$jira_id"

                        _kb_jq_update "$board_file" \
                           '.backlog[$pidx].subitems[$sidx].jiraKey = $jira | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg jira "$jira_id" \
                           --arg ts "$timestamp"
                        echo "✓ Set JIRA ID for: $sub_title -> $jira_id"
                    else
                        local current_jira
                        current_jira=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].jiraKey // empty" -r)
                        echo "Subitem: $sub_title"
                        if [[ -n "$current_jira" ]]; then
                            echo "  JIRA: $current_jira"
                        else
                            echo "  (no JIRA ID)"
                        fi
                    fi
                    ;;

                github|gh)
                    local parent_idx="$1"
                    local sub_idx="$2"
                    local gh_issue="$3"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub github <parent-index> <subitem-index> <issue-ref>"
                        echo "       kb-backlog sub github <parent-index> <subitem-index> -  (clear)"
                        return 1
                    fi

                    local sub_title
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    if [[ "$gh_issue" == "-" ]]; then
                        _kb_jq_update "$board_file" \
                           'del(.backlog[$pidx].subitems[$sidx].githubIssue) | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg ts "$timestamp"
                        echo "✓ Cleared GitHub issue for: $sub_title"
                    elif [[ -n "$gh_issue" ]]; then
                        _kb_jq_update "$board_file" \
                           '.backlog[$pidx].subitems[$sidx].githubIssue = $gh | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg gh "$gh_issue" \
                           --arg ts "$timestamp"
                        echo "✓ Set GitHub issue for: $sub_title -> $gh_issue"
                    else
                        local current_gh
                        current_gh=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].githubIssue // empty" -r)
                        echo "Subitem: $sub_title"
                        if [[ -n "$current_gh" ]]; then
                            echo "  GitHub: $current_gh"
                        else
                            echo "  (no GitHub issue)"
                        fi
                    fi
                    ;;

                start)
                    local arg1="$1"
                    local arg2="$2"
                    local parent_idx sub_idx

                    if [[ -z "$arg1" ]]; then
                        echo "Usage: kb-backlog sub start <subitem-id>"
                        echo "   or: kb-backlog sub start <parent-id> <subitem-index>"
                        echo "Marks subitem as in_progress and sets it as actively working."
                        return 1
                    fi

                    # Check if it's a single subitem ID (e.g., XFRE-0001-001)
                    if [[ -z "$arg2" ]] && [[ "$arg1" =~ ^X[A-Z]{2,4}-[0-9]+-[0-9]+$ ]]; then
                        # Single argument: subitem ID
                        local resolved
                        resolved=$(_kb_resolve_subitem_id "$board_file" "$arg1")
                        parent_idx="${resolved%%:*}"
                        sub_idx="${resolved##*:}"

                        if [[ "$parent_idx" == "-1" ]]; then
                            echo "Error: Subitem not found: $arg1"
                            return 1
                        fi
                    elif [[ -n "$arg2" ]] && [[ "$arg2" =~ ^[0-9]+$ ]]; then
                        # Two arguments: parent selector + subitem index
                        parent_idx=$(_kb_resolve_selector "$board_file" "$arg1")
                        sub_idx="$arg2"

                        if [[ "$parent_idx" == "-1" ]]; then
                            echo "Error: Parent item not found: $arg1"
                            return 1
                        fi
                    else
                        echo "Usage: kb-backlog sub start <subitem-id>"
                        echo "   or: kb-backlog sub start <parent-id> <subitem-index>"
                        return 1
                    fi

                    local sub_title sub_id
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    sub_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].id // empty" -r)

                    if [[ -z "$sub_title" ]]; then
                        echo "Error: Subitem not found at index $sub_idx"
                        return 1
                    fi

                    local timestamp worktree worktree_branch window_id
                    timestamp=$(_kb_get_timestamp)
                    worktree=$(_kb_get_worktree)
                    worktree_branch=$(git branch --show-current 2>/dev/null || echo "")

                    # Get window ID for linking
                    local wt_context wt_rest wt_terminal wt_window_name
                    wt_context=$(_kb_detect_context)
                    wt_rest="${wt_context#*:}"
                    wt_terminal="${wt_rest%%:*}"
                    wt_rest="${wt_rest#*:}"
                    wt_window_name="${wt_rest#*:}"
                    window_id=$(_kb_get_window_id "$wt_terminal" "$wt_window_name")

                    # Check for worktree conflicts before starting
                    if [[ -n "$worktree" ]]; then
                        local conflict
                        conflict=$(_kb_check_worktree_conflict "$board_file" "$sub_id" "$worktree")
                        if [[ -n "$conflict" ]]; then
                            _kb_warn_worktree_conflict "$conflict"
                        fi
                    fi

                    # Mark subitem as in_progress and actively working with worktree info
                    _kb_jq_update "$board_file" \
                       '.backlog[$pidx].subitems[$sidx].status = "in_progress" |
                        .backlog[$pidx].subitems[$sidx].activelyWorking = true |
                        .backlog[$pidx].subitems[$sidx].workStartedAt = $ts |
                        .backlog[$pidx].subitems[$sidx].startedAt //= $ts |
                        .backlog[$pidx].subitems[$sidx].worktree = $wt |
                        .backlog[$pidx].subitems[$sidx].worktreeBranch = $wtb |
                        .backlog[$pidx].subitems[$sidx].worktreeWindowId = $wid |
                        .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
                        .backlog[$pidx].updatedAt = $ts |
                        .lastUpdated = $ts' \
                       --argjson pidx "$parent_idx" \
                       --argjson sidx "$sub_idx" \
                       --arg ts "$timestamp" \
                       --arg wt "$worktree" \
                       --arg wtb "$worktree_branch" \
                       --arg wid "$window_id"

                    # Start planning with this task and set working item (use subitem ID)
                    kb-plan "$sub_title"
                    _kb_set_working_on "$sub_id"
                    echo "✓ Started subitem [$sub_id]: $sub_title"
                    ;;

                stop)
                    local parent_idx="$1"
                    local sub_idx="$2"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub stop <parent-index> <subitem-index>"
                        echo "Clears the actively working flag on a subitem."
                        return 1
                    fi

                    local sub_title
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    # XACA-0029: Calculate and accumulate work time
                    local work_started_at existing_time_ms total_time_ms
                    work_started_at=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].workStartedAt // empty" -r)
                    existing_time_ms=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].timeWorkedMs // 0")
                    total_time_ms="$existing_time_ms"

                    if [[ -n "$work_started_at" ]]; then
                        # Calculate elapsed time in milliseconds
                        local start_epoch now_epoch elapsed_ms
                        # Strip Z suffix and parse as UTC (macOS date -j -f ignores timezone suffix)
                        start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${work_started_at%Z}" "+%s" 2>/dev/null || echo "0")
                        now_epoch=$(date -u "+%s")
                        if [[ "$start_epoch" != "0" ]] && [[ "$start_epoch" -gt 0 ]]; then
                            elapsed_ms=$(( (now_epoch - start_epoch) * 1000 ))
                            total_time_ms=$(( existing_time_ms + elapsed_ms ))
                        fi
                    fi

                    # Clear activelyWorking flag and worktree info, accumulate time
                    _kb_jq_update "$board_file" \
                       '(if $timeMs != "0" then .backlog[$pidx].subitems[$sidx].timeWorkedMs = ($timeMs | tonumber) else . end) |
                        .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
                        del(.backlog[$pidx].subitems[$sidx].activelyWorking) |
                        del(.backlog[$pidx].subitems[$sidx].workStartedAt) |
                        del(.backlog[$pidx].subitems[$sidx].worktree) |
                        del(.backlog[$pidx].subitems[$sidx].worktreeBranch) |
                        del(.backlog[$pidx].subitems[$sidx].worktreeWindowId) |
                        .lastUpdated = $ts' \
                       --argjson pidx "$parent_idx" \
                       --argjson sidx "$sub_idx" \
                       --arg ts "$timestamp" \
                       --arg timeMs "$total_time_ms"

                    echo "✓ Stopped working on: $sub_title"
                    ;;

                tag|tags)
                    local parent_idx="$1"
                    local sub_idx="$2"
                    shift 2 2>/dev/null
                    local tag_args=("$@")

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub tag <parent-idx> <sub-idx> [add|rm|clear] [tags...]"
                        echo ""
                        echo "Manage tags for a subitem. Tags appear as clickable pills in LCARS UI."
                        echo ""
                        echo "Commands:"
                        echo "  kb-backlog sub tag <p> <s>                View current tags"
                        echo "  kb-backlog sub tag <p> <s> add tag1 ...   Add tags"
                        echo "  kb-backlog sub tag <p> <s> rm tag1 ...    Remove tags"
                        echo "  kb-backlog sub tag <p> <s> clear          Clear all tags"
                        echo "  kb-backlog sub tag <p> <s> tag1 tag2      Set tags (replaces)"
                        return 1
                    fi

                    local sub_title parent_item_id
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    parent_item_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].id // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    # No args - show current tags
                    if [[ ${#tag_args[@]} -eq 0 ]]; then
                        local current_tags
                        current_tags=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].tags // [] | join(\", \")" -r)
                        echo "[$parent_idx.$sub_idx] $sub_title"
                        if [[ -n "$current_tags" ]]; then
                            echo "  Tags: $current_tags"
                        else
                            echo "  (no tags)"
                        fi
                        return 0
                    fi

                    local tag_subcmd="${tag_args[1]}"

                    case "$tag_subcmd" in
                        add)
                            local new_tags=("${tag_args[@]:1}")
                            if [[ ${#new_tags[@]} -eq 0 ]]; then
                                echo "Usage: kb-backlog sub tag <p> <s> add tag1 tag2 ..."
                                return 1
                            fi
                            local tags_json
                            tags_json=$(printf '%s\n' "${new_tags[@]}" | jq -R . | jq -s .)
                            _kb_jq_update "$board_file" \
                               '.backlog[$pidx].subitems[$sidx].tags = ((.backlog[$pidx].subitems[$sidx].tags // []) + $tags | unique) | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                               --argjson pidx "$parent_idx" \
                               --argjson sidx "$sub_idx" \
                               --argjson tags "$tags_json" \
                               --arg ts "$timestamp"
                            echo "✓ Added tags to [$parent_idx.$sub_idx]: ${new_tags[*]}"

                            # Sync parent item to release manifests (best-effort)
                            _kb_release_sync "$parent_item_id"
                            ;;

                        rm|remove)
                            local rm_tags=("${tag_args[@]:1}")
                            if [[ ${#rm_tags[@]} -eq 0 ]]; then
                                echo "Usage: kb-backlog sub tag <p> <s> rm tag1 tag2 ..."
                                return 1
                            fi
                            local rm_json
                            rm_json=$(printf '%s\n' "${rm_tags[@]}" | jq -R . | jq -s .)
                            _kb_jq_update "$board_file" \
                               '.backlog[$pidx].subitems[$sidx].tags = ((.backlog[$pidx].subitems[$sidx].tags // []) - $tags) | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                               --argjson pidx "$parent_idx" \
                               --argjson sidx "$sub_idx" \
                               --argjson tags "$rm_json" \
                               --arg ts "$timestamp"
                            echo "✓ Removed tags from [$parent_idx.$sub_idx]: ${rm_tags[*]}"

                            # Sync parent item to release manifests (best-effort)
                            _kb_release_sync "$parent_item_id"
                            ;;

                        clear)
                            _kb_jq_update "$board_file" \
                               'del(.backlog[$pidx].subitems[$sidx].tags) | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                               --argjson pidx "$parent_idx" \
                               --argjson sidx "$sub_idx" \
                               --arg ts "$timestamp"
                            echo "✓ Cleared all tags from [$parent_idx.$sub_idx]: $sub_title"

                            # Sync parent item to release manifests (best-effort)
                            _kb_release_sync "$parent_item_id"
                            ;;

                        *)
                            # Set tags directly (replaces existing)
                            local set_tags=("${tag_args[@]}")
                            local set_json
                            set_json=$(printf '%s\n' "${set_tags[@]}" | jq -R . | jq -s .)
                            _kb_jq_update "$board_file" \
                               '.backlog[$pidx].subitems[$sidx].tags = $tags | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                               --argjson pidx "$parent_idx" \
                               --argjson sidx "$sub_idx" \
                               --argjson tags "$set_json" \
                               --arg ts "$timestamp"
                            echo "✓ Set tags for [$parent_idx.$sub_idx]: ${set_tags[*]}"

                            # Sync parent item to release manifests (best-effort)
                            _kb_release_sync "$parent_item_id"
                            ;;
                    esac
                    ;;

                priority|pri)
                    local parent_idx="$1"
                    local sub_idx="$2"
                    local new_priority="$3"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub priority <parent-idx> <sub-idx> [priority]"
                        echo "       kb-backlog sub priority <parent-idx> <sub-idx> -  (reset to medium)"
                        echo ""
                        echo "Valid priorities: low, medium (med), high, critical (crit), blocked (block)"
                        return 1
                    fi

                    local sub_title current_priority parent_item_id
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    current_priority=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].priority // \"medium\"" -r)
                    parent_item_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].id // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    if [[ "$new_priority" == "-" ]]; then
                        _kb_jq_update "$board_file" \
                           '.backlog[$pidx].subitems[$sidx].priority = "medium" | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg ts "$timestamp"
                        echo "✓ Reset priority to medium for: $sub_title"

                        # Sync parent item to release manifests (best-effort)
                        _kb_release_sync "$parent_item_id"
                    elif [[ -n "$new_priority" ]]; then
                        # Normalize priority aliases
                        case "$new_priority" in
                            med) new_priority="medium" ;;
                            crit) new_priority="critical" ;;
                            block) new_priority="blocked" ;;
                        esac

                        # Validate priority
                        if [[ ! "$new_priority" =~ ^(low|medium|high|critical|blocked)$ ]]; then
                            echo "Error: Invalid priority. Use: low, medium (med), high, critical (crit), or blocked (block)"
                            return 1
                        fi
                        _kb_jq_update "$board_file" \
                           '.backlog[$pidx].subitems[$sidx].priority = $priority | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg priority "$new_priority" \
                           --arg ts "$timestamp"
                        echo "✓ Set priority for: $sub_title -> $new_priority"

                        # Sync parent item to release manifests (best-effort)
                        _kb_release_sync "$parent_item_id"
                    else
                        echo "[$parent_idx.$sub_idx] $sub_title"
                        echo "  Priority: $current_priority"
                    fi
                    ;;

                due|deadline)
                    local parent_idx="$1"
                    local sub_idx="$2"
                    local new_due="$3"

                    if [[ -z "$parent_idx" ]] || [[ ! "$parent_idx" =~ ^[0-9]+$ ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub due <parent-idx> <sub-idx> <YYYY-MM-DD>"
                        echo "       kb-backlog sub due <parent-idx> <sub-idx> -  (clear)"
                        return 1
                    fi

                    local sub_title
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx in item $parent_idx"
                        return 1
                    fi

                    local timestamp
                    timestamp=$(_kb_get_timestamp)

                    if [[ "$new_due" == "-" ]]; then
                        _kb_jq_update "$board_file" \
                           'del(.backlog[$pidx].subitems[$sidx].dueDate) | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg ts "$timestamp"
                        echo "✓ Cleared due date for: $sub_title"
                    elif [[ -n "$new_due" ]]; then
                        # Validate date format (YYYY-MM-DD)
                        if [[ ! "$new_due" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                            echo "Error: Invalid date format. Use YYYY-MM-DD (e.g., 2026-01-20)"
                            return 1
                        fi
                        _kb_jq_update "$board_file" \
                           '.backlog[$pidx].subitems[$sidx].dueDate = $due | .backlog[$pidx].subitems[$sidx].updatedAt = $ts | .backlog[$pidx].updatedAt = $ts | .lastUpdated = $ts' \
                           --argjson pidx "$parent_idx" \
                           --argjson sidx "$sub_idx" \
                           --arg due "$new_due" \
                           --arg ts "$timestamp"
                        echo "✓ Set due date for: $sub_title -> $new_due"
                    else
                        local current_due
                        current_due=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].dueDate // empty" -r)
                        echo "[$parent_idx.$sub_idx] $sub_title"
                        if [[ -n "$current_due" ]]; then
                            echo "  Due: $current_due"
                        else
                            echo "  (no due date)"
                        fi
                    fi
                    ;;

                *)
                    echo "Usage: kb-backlog sub <command> [args...]"
                    echo ""
                    echo "Subitem Commands:"
                    echo "  add <parent-idx> \"title\" [jira] [os]  Add subitem to backlog item"
                    echo "  list <parent-idx>                   List subitems"
                    echo "  remove <parent-idx> <sub-idx>       Remove subitem"
                    echo "  done <parent-idx> <sub-idx>         Mark subitem completed"
                    echo "  todo <parent-idx> <sub-idx>         Reset subitem to todo"
                    echo "  jira <parent-idx> <sub-idx> [id]    Set/view/clear JIRA ID"
                    echo "  github <parent-idx> <sub-idx> [ref] Set/view/clear GitHub issue"
                    echo "  tag <parent-idx> <sub-idx> [...]    Manage subitem tags"
                    echo "  priority <parent-idx> <sub-idx> [p] Set/view/reset priority"
                    echo "  due <parent-idx> <sub-idx> [date]   Set/view/clear due date"
                    echo "  start <parent-idx> <sub-idx>        Start working on subitem"
                    echo "  stop <parent-idx> <sub-idx>         Clear actively working flag"
                    echo ""
                    echo "OS: Optional platform - iOS | Android | Firebase"
                    echo ""
                    echo "Examples:"
                    echo "  kb-backlog sub add 0 \"Implement login\""
                    echo "  kb-backlog sub add 0 \"Fix logout\" ME-456"
                    echo "  kb-backlog sub add 0 \"iOS fix\" ME-789 iOS"
                    echo "  kb-backlog sub list 0"
                    echo "  kb-backlog sub done 0 1"
                    echo "  kb-backlog sub tag 0 1 iOS testing"
                    echo "  kb-backlog sub due 0 1 2026-01-20"
                    echo "  kb-backlog sub start 0 0"
                    echo "  kb-backlog sub stop 0 0"
                    return 1
                    ;;
            esac
            ;;

        cleanup)
            # Clear orphaned activelyWorking/worktree fields from items
            # that reference windows that no longer exist
            local window_id
            local terminal window_name

            # Parse current context
            local context_full
            context_full=$(_kb_detect_context)
            terminal="${context_full#*:}"
            terminal="${terminal%%:*}"
            window_name="${context_full##*:}"
            window_id="${terminal}:${window_name}"

            echo "Cleaning orphaned items for window: $window_id"

            # Call Python cleanup function
            python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('kanban_stop', '$HOME/dev-team/kanban-hooks/kanban-stop.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
result = mod.clear_orphaned_item_fields('$team', '$terminal', '$window_name')
if result:
    print('✓ Cleanup complete')
else:
    print('No orphaned items found (or no changes needed)')
" 2>/dev/null

            ;;

        cleanup-all)
            # Clear ALL orphaned activelyWorking/worktree fields from items
            # regardless of which window they reference
            echo "Cleaning ALL orphaned items..."

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Find and clear all items with worktreeWindowId that don't have matching active windows
            _kb_jq_update "$board_file" '
                .activeWindows as $windows |
                ($windows | map(.id) | unique) as $active_ids |
                .backlog = [.backlog[] |
                    if (.worktreeWindowId != null) and ((.worktreeWindowId | IN($active_ids[])) | not) then
                        del(.activelyWorking, .worktree, .worktreeBranch, .worktreeWindowId) | .updatedAt = $ts
                    else . end |
                    .subitems = ((.subitems // []) | [.[] |
                        if (.worktreeWindowId != null) and ((.worktreeWindowId | IN($active_ids[])) | not) then
                            del(.activelyWorking, .worktree, .worktreeBranch, .worktreeWindowId) | .updatedAt = $ts
                        else . end
                    ])
                ] |
                .lastUpdated = $ts
            ' --arg ts "$timestamp"

            echo "✓ Cleanup complete"
            ;;

        block)
            # Block an item or subitem by one or more other items/subitems (XACA-0025)
            local target_id="$1"
            shift 2>/dev/null
            local blocker_ids=("$@")

            if [[ -z "$target_id" ]] || [[ ${#blocker_ids[@]} -eq 0 ]]; then
                echo "Usage: kb-backlog block <item-id|subitem-id> <blocker-id> [blocker-id2...]"
                echo ""
                echo "Mark an item or subitem as blocked by one or more other items/subitems."
                echo "The target will not be workable until all blockers are completed."
                echo ""
                echo "Examples:"
                echo "  kb-backlog block XACA-0016 XACA-0017           # Item blocked by item"
                echo "  kb-backlog block XACA-0016-001 XACA-0016-002   # Subitem blocked by subitem"
                echo "  kb-backlog block XACA-0016-003 XACA-0017       # Subitem blocked by item"
                return 1
            fi

            # Determine if target is a subitem (XACA-0025)
            if _kb_is_subitem_id "$target_id"; then
                # Target is a subitem - use subitem blocker functions
                for blocker_id in "${blocker_ids[@]}"; do
                    if _kb_add_subitem_blocker "$board_file" "$target_id" "$blocker_id"; then
                        echo "✓ $target_id blocked by $blocker_id"
                    fi
                done
            else
                # Existing parent item logic
                # Resolve target
                local target_index
                target_index=$(_kb_resolve_selector "$board_file" "$target_id")
                if [[ "$target_index" == "-1" ]]; then
                    echo "Error: Target item not found: $target_id"
                    return 1
                fi

                # Get the actual item ID (in case selector was an index)
                local actual_target_id
                actual_target_id=$(_kb_jq_read "$board_file" ".backlog[$target_index].id // empty" -r)

                # Add each blocker
                for blocker_id in "${blocker_ids[@]}"; do
                    # Validate blocker exists (same board or cross-board)
                    local blocker_board blocker_team
                    blocker_team=$(_kb_get_team_from_code "$blocker_id")
                    if [[ -n "$blocker_team" ]]; then
                        blocker_board=$(_kb_get_board_file "$blocker_team")
                    else
                        blocker_board="$board_file"
                    fi

                    local blocker_index
                    blocker_index=$(_kb_find_by_id "$blocker_board" "$blocker_id")
                    if [[ "$blocker_index" == "-1" ]]; then
                        echo "Warning: Blocker not found: $blocker_id (skipping)"
                        continue
                    fi

                    _kb_add_blocker "$board_file" "$actual_target_id" "$blocker_id"
                    echo "✓ $actual_target_id blocked by $blocker_id"
                done
            fi
            ;;

        unblock)
            # Remove blocker(s) from an item or subitem (XACA-0025)
            local target_id="$1"
            local blocker_id="$2"

            if [[ -z "$target_id" ]]; then
                echo "Usage: kb-backlog unblock <item-id|subitem-id> [blocker-id]"
                echo ""
                echo "Remove a specific blocker, or all blockers if none specified."
                echo ""
                echo "Examples:"
                echo "  kb-backlog unblock XACA-0016 XACA-0017       # Remove specific blocker from item"
                echo "  kb-backlog unblock XACA-0016                 # Remove all blockers from item"
                echo "  kb-backlog unblock XACA-0016-001 XACA-0016-002  # Remove blocker from subitem"
                echo "  kb-backlog unblock XACA-0016-001             # Remove all blockers from subitem"
                return 1
            fi

            # Determine if target is a subitem (XACA-0025)
            if _kb_is_subitem_id "$target_id"; then
                # Target is a subitem
                local indices
                indices=$(_kb_resolve_subitem_id "$board_file" "$target_id")
                if [[ "$indices" == "-1:-1" ]]; then
                    echo "Error: Subitem not found: $target_id"
                    return 1
                fi

                local parent_idx="${indices%%:*}"
                local sub_idx="${indices##*:}"
                local current_blockers
                current_blockers=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].blockedBy // [] | join(\", \")" -r)

                if [[ -z "$current_blockers" ]]; then
                    echo "Subitem $target_id is not blocked by anything"
                    return 0
                fi

                local timestamp
                timestamp=$(_kb_get_timestamp)

                if [[ -z "$blocker_id" ]]; then
                    # Remove all blockers from subitem
                    _kb_jq_update "$board_file" '
                        .backlog[$pidx].subitems[$sidx].status = "todo" |
                        del(.backlog[$pidx].subitems[$sidx].blockedBy) |
                        del(.backlog[$pidx].subitems[$sidx].blockedAt) |
                        .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
                        .backlog[$pidx].updatedAt = $ts |
                        .lastUpdated = $ts
                    ' --argjson pidx "$parent_idx" --argjson sidx "$sub_idx" --arg ts "$timestamp"
                    echo "✓ Removed all blockers from $target_id"
                    echo "  Was blocked by: $current_blockers"
                else
                    # Remove specific blocker from subitem
                    _kb_remove_subitem_blocker "$board_file" "$target_id" "$blocker_id"
                    echo "✓ Removed blocker $blocker_id from $target_id"
                fi
            else
                # Existing parent item logic
                # Resolve target
                local target_index
                target_index=$(_kb_resolve_selector "$board_file" "$target_id")
                if [[ "$target_index" == "-1" ]]; then
                    echo "Error: Item not found: $target_id"
                    return 1
                fi

                local actual_target_id current_blockers
                actual_target_id=$(_kb_jq_read "$board_file" ".backlog[$target_index].id // empty" -r)
                current_blockers=$(_kb_jq_read "$board_file" ".backlog[$target_index].blockedBy // [] | join(\", \")" -r)

                if [[ -z "$current_blockers" ]]; then
                    echo "Item $actual_target_id is not blocked by anything"
                    return 0
                fi

                local timestamp
                timestamp=$(_kb_get_timestamp)

                if [[ -z "$blocker_id" ]]; then
                    # Remove all blockers
                    _kb_jq_update "$board_file" '
                        .backlog[$idx].status = "todo" |
                        del(.backlog[$idx].blockedBy) |
                        del(.backlog[$idx].blockedAt) |
                        .backlog[$idx].updatedAt = $ts |
                        .lastUpdated = $ts
                    ' --argjson idx "$target_index" --arg ts "$timestamp"
                    echo "✓ Removed all blockers from $actual_target_id"
                    echo "  Was blocked by: $current_blockers"

                    # XACA-0054: Sync to release manifests via LCARS server
                    _kb_release_sync "$actual_target_id"
                else
                    # Remove specific blocker
                    _kb_remove_blocker "$board_file" "$actual_target_id" "$blocker_id"
                    echo "✓ Removed blocker $blocker_id from $actual_target_id"

                    # XACA-0054: Sync to release manifests via LCARS server
                    _kb_release_sync "$actual_target_id"
                fi
            fi
            ;;

        blocked)
            # List all blocked items
            local blocked_count
            blocked_count=$(_kb_jq_read "$board_file" '[.backlog[] | select(.status == "blocked")] | length')

            echo "Blocked items for ${team}: ($blocked_count items)"
            echo "─────────────────────────────────────"

            if [[ "$blocked_count" -eq 0 ]]; then
                echo "  (no blocked items)"
            else
                _kb_jq_read "$board_file" '
                    .backlog[] | select(.status == "blocked") |
                    "  [\(.id)] \(.title)\n    Blocked by: \((.blockedBy // []) | join(", "))"
                ' -r
            fi
            echo "─────────────────────────────────────"
            ;;

        deps)
            # Show dependency tree
            local target_id="$1"

            if [[ -n "$target_id" ]]; then
                # Show deps for specific item
                local target_index
                target_index=$(_kb_resolve_selector "$board_file" "$target_id")
                if [[ "$target_index" == "-1" ]]; then
                    echo "Error: Item not found: $target_id"
                    return 1
                fi

                local actual_id item_title blockers dependents
                actual_id=$(_kb_jq_read "$board_file" ".backlog[$target_index].id // empty" -r)
                item_title=$(_kb_jq_read "$board_file" ".backlog[$target_index].title // empty" -r)
                blockers=$(_kb_jq_read "$board_file" ".backlog[$target_index].blockedBy // [] | join(\", \")" -r)

                # Find items blocked by this item
                dependents=$(_kb_jq_read "$board_file" '
                    [.backlog[] | select((.blockedBy // []) | any(. == $id))] | map(.id) | join(", ")
                ' --arg id "$actual_id" -r)

                echo "Dependency Tree for [$actual_id]: $item_title"
                echo "─────────────────────────────────────"
                if [[ -n "$blockers" ]]; then
                    echo "  Blocked by:"
                    for blocker in $(echo "$blockers" | tr ',' '\n'); do
                        local blocker_trim="${blocker## }"
                        blocker_trim="${blocker_trim%% }"
                        local blocker_title
                        blocker_title=$(_kb_jq_read "$board_file" '.backlog[] | select(.id == $id) | .title' --arg id "$blocker_trim" -r 2>/dev/null || echo "")
                        echo "    ↑ [$blocker_trim] $blocker_title"
                    done
                else
                    echo "  Blocked by: (none)"
                fi
                if [[ -n "$dependents" ]]; then
                    echo "  Blocks:"
                    for dep in $(echo "$dependents" | tr ',' '\n'); do
                        local dep_trim="${dep## }"
                        dep_trim="${dep_trim%% }"
                        local dep_title
                        dep_title=$(_kb_jq_read "$board_file" '.backlog[] | select(.id == $id) | .title' --arg id "$dep_trim" -r 2>/dev/null || echo "")
                        echo "    ↓ [$dep_trim] $dep_title"
                    done
                else
                    echo "  Blocks: (none)"
                fi
            else
                # Show all dependencies as a tree
                echo "Dependency Tree for ${team}:"
                echo "─────────────────────────────────────"

                # Items with no blockers that block others (roots)
                echo "Root items (no blockers, but blocking others):"
                _kb_jq_read "$board_file" '
                    .backlog[] |
                    select((.blockedBy // []) | length == 0) |
                    select(.id as $id | any(..; .blockedBy? // [] | any(. == $id))) |
                    "  [\(.id)] \(.title)"
                ' -r 2>/dev/null | head -20

                echo ""
                echo "Blocked items:"
                _kb_jq_read "$board_file" '
                    .backlog[] | select(.status == "blocked") |
                    "  [\(.id)] ← \((.blockedBy // []) | join(\", \"))"
                ' -r 2>/dev/null
                echo "─────────────────────────────────────"
            fi
            ;;

        *)
            echo "Usage: kb-backlog <command> [args...]"
            echo ""
            echo "Commands:"
            echo "  add \"task\" [pri] [\"desc\"] [jira] [os]  Add task with optional fields"
            echo "  list                               List all backlog items"
            echo "  change <i> [\"title\"] [priority]   Update item title and/or priority"
            echo "  desc <i> [\"description\"]          Set/view/clear item description"
            echo "  jira <i> [JIRA-ID]                 Set/view/clear JIRA ticket ID"
            echo "  github <i> [issue-ref]             Set/view/clear GitHub issue"
            echo "  tag <i> [add|rm|clear] [tags...]   Manage tags (clickable in LCARS)"
            echo "  due <i> [YYYY-MM-DD]               Set/view/clear due date"
            echo "  remove <index>                     Remove item by index"
            echo "  unpick <index>                     Clear actively working flag"
            echo "  cleanup                            Clear orphaned items for current window"
            echo "  cleanup-all                        Clear ALL orphaned items"
            echo "  sub <cmd> [args...]                Manage subitems"
            echo ""
            echo "Dependency Commands:"
            echo "  block <id> <blocker-id>...         Mark item as blocked by another"
            echo "  unblock <id> [blocker-id]          Remove blocker(s) from item"
            echo "  blocked                            List all blocked items"
            echo "  deps [id]                          Show dependency tree"
            echo ""
            echo "Priority: low | med | high | crit | critical | block | blocked"
            echo "  - critical: Urgent issues requiring immediate attention"
            echo "  - blocked: Items waiting on external dependencies"
            echo ""
            echo "OS: iOS | Android | Firebase (platform-specific tasks)"
            echo ""
            echo "Issue Tracking:"
            echo "  JIRA:   ME-123, PROJ-456"
            echo "  GitHub: #123 (team default) or owner/repo#123 (explicit)"
            echo ""
            echo "Tags:"
            echo "  Tags appear as clickable pills in LCARS UI. Click to filter."
            echo "  kb-backlog tag 0 iOS refactor      # Set tags"
            echo "  kb-backlog tag 0 add testing       # Add tag"
            echo "  kb-backlog tag 0 rm testing        # Remove tag"
            echo ""
            echo "Examples:"
            echo "  kb-backlog add \"Fix login bug\" high"
            echo "  kb-backlog add \"Critical crash\" crit \"\" ME-123"
            echo "  kb-backlog add \"Update docs\" med \"Review API docs\""
            echo "  kb-backlog add \"iOS payment fix\" high \"\" ME-456 iOS"
            echo "  kb-backlog list"
            echo "  kb-backlog change 0 \"New title\" high"
            echo "  kb-backlog tag 0 iOS feature urgent"
            echo "  kb-backlog jira 0 ME-456"
            echo "  kb-backlog remove 0"
            return 1
            ;;
    esac
}

# Aliases for convenience
alias kb-backlog-list='kb-backlog list'
alias kb-backlog-remove='kb-backlog remove'

# Import external issues from JIRA, GitHub, Monday.com
kb-import() {
    local external_id="$1"
    shift

    # Default options
    local preview_only=false
    local skip_confirm=false
    local include_children=true
    local target_team=""
    local integration=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --preview|-p)
                preview_only=true
                ;;
            --yes|-y)
                skip_confirm=true
                ;;
            --no-children)
                include_children=false
                ;;
            --team|-t)
                target_team="$2"
                shift
                ;;
            --integration|-i)
                integration="$2"
                shift
                ;;
            --help|-h)
                external_id=""
                break
                ;;
            *)
                echo "Unknown option: $1"
                external_id=""
                break
                ;;
        esac
        shift
    done

    # Show usage if no ID provided
    if [[ -z "$external_id" ]]; then
        echo "Usage: kb-import <external-id> [options]"
        echo ""
        echo "Import issues from external systems (JIRA, GitHub, Monday.com)"
        echo "into the kanban backlog with automatic ticket linking."
        echo ""
        echo "Arguments:"
        echo "  <external-id>  External ticket ID to import"
        echo "                 Examples: ME-123, gh:owner/repo#123, mon:1234567"
        echo ""
        echo "Options:"
        echo "  --preview, -p      Show preview only, don't import"
        echo "  --yes, -y          Skip confirmation prompt"
        echo "  --team, -t <team>  Target team (default: from context)"
        echo "  --integration, -i  Integration ID (default: auto-detect)"
        echo "  --no-children      Don't import subtasks/children"
        echo "  --help, -h         Show this help"
        echo ""
        echo "Provider Detection:"
        echo "  ME-123, MEM-456     → JIRA (PROJECT-NUMBER pattern)"
        echo "  gh:owner/repo#123   → GitHub"
        echo "  github:repo#123     → GitHub"
        echo "  mon:1234567890      → Monday.com"
        echo "  MON-1234567890      → Monday.com"
        echo ""
        echo "Examples:"
        echo "  kb-import ME-123                    # Import JIRA issue"
        echo "  kb-import ME-123 --preview          # Preview without importing"
        echo "  kb-import gh:lcars-ui#42            # Import GitHub issue"
        echo "  kb-import ME-123 --team iOS         # Import to iOS board"
        echo "  kb-import ME-123 --yes              # Import without confirmation"
        echo "  kb-import ME-123 --no-children      # Don't import subtasks"
        return 1
    fi

    # Detect team from context if not specified
    if [[ -z "$target_team" ]]; then
        local context
        context=$(_kb_detect_context 2>/dev/null || echo "academy:unknown")
        target_team="${context%%:*}"
    fi

    # Find the LCARS UI directory
    local lcars_ui_dir="${LCARS_UI_DIR:-$HOME/dev-team/lcars-ui}"

    # Check if the import script exists
    local import_script="$lcars_ui_dir/integrations/import_issue.py"
    if [[ ! -f "$import_script" ]]; then
        echo "Error: Import script not found: $import_script"
        echo "Make sure LCARS UI is installed correctly."
        return 1
    fi

    # Build command arguments
    local cmd_args=("--id" "$external_id" "--team" "$target_team")

    if [[ "$preview_only" == "true" ]]; then
        cmd_args+=("--preview")
    elif [[ "$skip_confirm" == "true" ]]; then
        cmd_args+=("--execute")
    fi

    if [[ "$include_children" == "false" ]]; then
        cmd_args+=("--no-children")
    fi

    if [[ -n "$integration" ]]; then
        cmd_args+=("--integration" "$integration")
    fi

    # Run the import script
    python3 "$import_script" "${cmd_args[@]}"
}

# Pick a task from backlog and mark it as active (simple assignment)
kb-pick() {
    _kb_ensure_jq || return 1

    local selector="$1"

    if [[ -z "$selector" ]]; then
        echo "Usage: kb-pick <id>"
        echo "Marks an item as actively being worked on."
        echo "Use 'kb-backlog list' to see available items"
        echo "Example: kb-pick XFRE-0001"
        echo ""
        echo "For full Claude Code launch with worktree setup, use: kb-run <id>"
        return 1
    fi

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Resolve selector to index
    local index
    index=$(_kb_resolve_selector "$board_file" "$selector")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Read the item
    local item_json item_id title
    item_json=$(_kb_jq_read "$board_file" ".backlog[$index] // empty")
    item_id=$(echo "$item_json" | jq -r '.id // empty')
    title=$(echo "$item_json" | jq -r '.title // empty')

    if [[ -z "$item_id" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Check if item is blocked (XACA-0020)
    local item_status blocked_by
    item_status=$(echo "$item_json" | jq -r '.status // "todo"')
    blocked_by=$(echo "$item_json" | jq -r '(.blockedBy // []) | join(", ")')
    if [[ "$item_status" == "blocked" ]] || [[ -n "$blocked_by" ]]; then
        echo "─────────────────────────────────────"
        echo "⚠️  Cannot pick [$item_id]: Item is blocked"
        echo "   Blocked by: $blocked_by"
        echo "─────────────────────────────────────"
        echo "Complete the blocking items first, or use:"
        echo "  kb-backlog unblock $item_id"
        return 1
    fi

    # Mark item as actively being worked on
    local timestamp
    timestamp=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" \
       '.backlog[$idx].activelyWorking = true |
        .backlog[$idx].status = "in_progress" |
        .backlog[$idx].workStartedAt = $ts |
        .backlog[$idx].startedAt //= $ts |
        .backlog[$idx].updatedAt = $ts |
        .lastUpdated = $ts' \
       --argjson idx "$index" \
       --arg ts "$timestamp"

    # XACA-0054: Sync to release manifests via LCARS server
    _kb_release_sync "$item_id"

    # Register window in activeWindows (required before _kb_set_working_on)
    _kb_update_window "coding" "$title"

    # Set as current working item
    _kb_set_working_on "$item_id"

    echo "─────────────────────────────────────"
    echo "✓ Picked: [$item_id] $title"
    echo "  Status: in_progress (actively working)"
    echo "─────────────────────────────────────"
    echo ""
    echo "To launch Claude Code with this task: kb-run $item_id"
}

# Get persona-to-subagent_type delegation guide for a team
# Used by kb-run and kb-work to inject persona selection into delegation prompts
_kb_get_persona_delegation_guide() {
    local team="$1"
    local guide=""

    case "$team" in
        ios)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Feature Development | captain | Picard |\n"
            guide+="| Refactoring / Optimization | data | Data |\n"
            guide+="| Testing / QA | worf | Worf |\n"
            guide+="| UI/UX / Accessibility | wesley | Wesley |\n"
            guide+="| Documentation | counselor | Deanna Troi |\n"
            guide+="| Release / CI/CD | geordi | Geordi |"
            ;;
        android)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Feature Development | kirk | Kirk |\n"
            guide+="| Refactoring / Optimization | spock | Spock |\n"
            guide+="| Bug Fixing | mccoy | McCoy |\n"
            guide+="| Testing / QA | chekov | Chekov |\n"
            guide+="| UI/UX / Accessibility | uhura | Uhura |\n"
            guide+="| Documentation | sulu | Sulu |\n"
            guide+="| Release / CI/CD | scotty | Scotty |"
            ;;
        firebase)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Feature Development | sisko | Sisko |\n"
            guide+="| Bug Fixing | kira | Kira |\n"
            guide+="| Testing / QA | odo | Odo |\n"
            guide+="| Refactoring / Optimization | dax | Dax |\n"
            guide+="| Documentation | bashir | Bashir |\n"
            guide+="| Release / CI/CD | obrien | O'Brien |\n"
            guide+="| UX / Developer Experience | quark | Quark |"
            ;;
        mainevent)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Feature Development / Strategy | janeway | Janeway |\n"
            guide+="| Bug Fixing | doctor | The Doctor |\n"
            guide+="| Refactoring / Optimization | seven | Seven |\n"
            guide+="| Security / Testing | tuvok | Tuvok |\n"
            guide+="| Documentation | kim | Kim |\n"
            guide+="| Release / CI/CD | torres | Torres |\n"
            guide+="| Communications / UX | paris | Paris |"
            ;;
        dns|dns-framework)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Feature Development | mariner | Mariner |\n"
            guide+="| Bug Fixing | tana | Tana |\n"
            guide+="| Testing / QA | shaxs | Shaxs |\n"
            guide+="| Refactoring / Optimization | tendi | Tendi |\n"
            guide+="| API Design / DX | boimler | Boimler |\n"
            guide+="| Documentation | ransom | Ransom |\n"
            guide+="| Release / CI/CD | rutherford | Rutherford |"
            ;;
        freelance*)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Feature Development | archer | Archer |\n"
            guide+="| Bug Fixing | phlox | Phlox |\n"
            guide+="| Refactoring / Optimization | tpol | T'Pol |\n"
            guide+="| Security / Testing | reed | Reed |\n"
            guide+="| UI/UX | mayweather | Mayweather |\n"
            guide+="| Documentation | sato | Sato |\n"
            guide+="| Release / CI/CD | tucker | Tucker |"
            ;;
        academy)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Strategic / Architecture | nahla | Captain Ake |\n"
            guide+="| Engineering / Infrastructure | reno | Reno |\n"
            guide+="| Testing / QA | thok | Thok |\n"
            guide+="| Documentation / Training | emh | EMH |"
            ;;
        command)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Strategic Command | vance | Vance |\n"
            guide+="| Operations / Release | ross | Ross |\n"
            guide+="| Intelligence / Security | nechayev | Nechayev |\n"
            guide+="| Strategic Planning | janeway | Janeway |\n"
            guide+="| Communications | paris | Paris |"
            ;;
        legal)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Case Strategy / Legal Arguments | advocate | Lead Counsel |\n"
            guide+="| Deadlines / Calendar | casemanager | Timeline Coordinator |\n"
            guide+="| Court Documents / Motions | courtclerk | Filing Specialist |\n"
            guide+="| Legal Research / Precedent | lawclerk | Legal Researcher |\n"
            guide+="| Settlement / Negotiation | mediator | Mediation Specialist |\n"
            guide+="| Evidence / Investigation | paralegal | Discovery Specialist |"
            ;;
        medical*)
            guide+="| Work Type | subagent_type | Persona |\n"
            guide+="|---|---|---|\n"
            guide+="| Feature Development | house | House |\n"
            guide+="| Bug Fixing | chase | Chase |\n"
            guide+="| Testing / QA | cameron | Cameron |\n"
            guide+="| Refactoring / Optimization | foreman | Foreman |\n"
            guide+="| Documentation | wilson | Wilson |\n"
            guide+="| Release / CI/CD | cuddy | Cuddy |"
            ;;
        *)
            guide+="| Work Type | subagent_type |\n"
            guide+="|---|---|\n"
            guide+="| General Tasks | general-purpose |\n"
            guide+="| Code Exploration | Explore |\n"
            guide+="| Shell Commands | Bash |"
            ;;
    esac

    echo "$guide"
}

# Run a task from backlog - launch Claude Code with todo plan and worktree setup
kb-run() {
    _kb_ensure_jq || return 1

    local selector="$1"

    if [[ -z "$selector" ]]; then
        echo "Usage: kb-run <id>"
        echo "Launches Claude Code with task details and auto-creates worktree."
        echo "Use 'kb-backlog list' to see available items"
        echo "Example: kb-run XFRE-0001"
        echo ""
        echo "For simple assignment without Claude, use: kb-pick <id>"
        return 1
    fi

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Resolve selector to index
    local index
    index=$(_kb_resolve_selector "$board_file" "$selector")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Read the full backlog item
    local item_json
    item_json=$(_kb_jq_read "$board_file" ".backlog[$index] // empty")

    if [[ -z "$item_json" ]] || [[ "$item_json" == "null" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Extract item details
    local item_id title description jira_id github_issue priority item_status due_date tags
    item_id=$(echo "$item_json" | jq -r '.id // empty')
    title=$(echo "$item_json" | jq -r '.title // empty')
    description=$(echo "$item_json" | jq -r '.description // empty')
    jira_id=$(echo "$item_json" | jq -r '.jiraId // empty')
    github_issue=$(echo "$item_json" | jq -r '.githubIssue // empty')
    priority=$(echo "$item_json" | jq -r '.priority // "medium"')
    item_status=$(echo "$item_json" | jq -r '.status // "todo"')
    due_date=$(echo "$item_json" | jq -r '.dueDate // empty')
    tags=$(echo "$item_json" | jq -r '(.tags // []) | join(", ")')

    # Check if item is blocked (XACA-0020)
    # Check status, priority, AND blockedBy array - any of these can indicate blocked state
    local blocked_by
    blocked_by=$(echo "$item_json" | jq -r '(.blockedBy // []) | join(", ")')
    if [[ "$item_status" == "blocked" ]] || [[ "$priority" == "blocked" ]] || [[ -n "$blocked_by" ]]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║                     ⚠️  ITEM BLOCKED  ⚠️                           ║"
        echo "╠══════════════════════════════════════════════════════════════════╣"
        echo "║"
        echo "║  ID:       $item_id"
        echo "║  Title:    $title"
        echo "║"
        echo "║  This item cannot be started because it is blocked by:"
        for blocker in $(echo "$blocked_by" | tr ',' '\n'); do
            local blocker_trim="${blocker## }"
            blocker_trim="${blocker_trim%% }"
            if [[ -n "$blocker_trim" ]]; then
                local blocker_title
                blocker_title=$(_kb_jq_read "$board_file" '.backlog[] | select(.id == $id) | .title' --arg id "$blocker_trim" -r 2>/dev/null || echo "")
                echo "║    → [$blocker_trim] $blocker_title"
            fi
        done
        echo "║"
        echo "║  Complete the blocking items first, or use:"
        echo "║    kb-backlog unblock $item_id"
        echo "║  to remove the blockers."
        echo "║"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        return 1
    fi

    # Get subitem count and details
    local subitem_count
    subitem_count=$(echo "$item_json" | jq '.subitems // [] | length')

    # Display item details for confirmation
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                     KANBAN ITEM DETAILS                          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║"
    echo "║  ID:       $item_id"
    echo "║  Title:    $title"
    echo "║"
    echo "║  Priority: $(printf '%-12s' "$priority" | tr '[:lower:]' '[:upper:]')  Status: $item_status"
    if [[ -n "$due_date" ]]; then
        echo "║  Due Date: $due_date"
    fi
    if [[ -n "$tags" ]]; then
        echo "║  Tags:     $tags"
    fi
    echo "║"

    # Show description if present
    if [[ -n "$description" ]]; then
        echo "║  Description:"
        echo "$description" | fold -w 60 -s | while IFS= read -r line; do
            echo "║    $line"
        done
        echo "║"
    fi

    # Show external links
    if [[ -n "$jira_id" ]] || [[ -n "$github_issue" ]]; then
        echo "║  Links:"
        [[ -n "$jira_id" ]] && echo "║    JIRA:   $jira_id"
        [[ -n "$github_issue" ]] && echo "║    GitHub: $github_issue"
        echo "║"
    fi

    # Show subitems summary
    if [[ "$subitem_count" -gt 0 ]]; then
        local completed_count in_progress_count todo_count
        completed_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "completed")] | length')
        in_progress_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "in_progress")] | length')
        todo_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "todo")] | length')

        cancelled_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "cancelled")] | length')
        if [[ "$cancelled_count" -gt 0 ]]; then
            echo "║  Subitems: $subitem_count total ($completed_count done, $cancelled_count cancelled, $in_progress_count in progress, $todo_count todo)"
        else
            echo "║  Subitems: $subitem_count total ($completed_count done, $in_progress_count in progress, $todo_count todo)"
        fi
        echo "║"
        echo "$item_json" | jq -r '.subitems[] | "║    [\(.status | if . == "completed" then "✓" elif . == "cancelled" then "✗" elif . == "in_progress" then "●" else "○" end)] \(.id): \(.title)"'
        echo "║"
    fi

    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check if item is blocked by incomplete items
    local blocked_by_ids incomplete_blockers
    blocked_by_ids=$(echo "$item_json" | jq -r '(.blockedBy // []) | .[]' 2>/dev/null)

    if [[ -n "$blocked_by_ids" ]]; then
        incomplete_blockers=""
        while IFS= read -r blocker_id; do
            [[ -z "$blocker_id" ]] && continue
            # Check if blocker exists and is not completed
            local blocker_status
            blocker_status=$(_kb_jq_read "$board_file" \
                '.backlog[] | select(.id == $bid) | .status // "unknown"' \
                --arg bid "$blocker_id" -r 2>/dev/null)

            if [[ -n "$blocker_status" ]] && [[ "$blocker_status" != "completed" ]] && [[ "$blocker_status" != "cancelled" ]]; then
                local blocker_title
                blocker_title=$(_kb_jq_read "$board_file" \
                    '.backlog[] | select(.id == $bid) | .title // "Unknown"' \
                    --arg bid "$blocker_id" -r 2>/dev/null)
                incomplete_blockers+="    ⛔ $blocker_id: $blocker_title [$blocker_status]\n"
            fi
        done <<< "$blocked_by_ids"

        if [[ -n "$incomplete_blockers" ]]; then
            echo "╔══════════════════════════════════════════════════════════════════╗"
            echo "║  ⛔ BLOCKED: Cannot start - dependencies not complete            ║"
            echo "╠══════════════════════════════════════════════════════════════════╣"
            echo "║  Blocked by:                                                     ║"
            echo -e "$incomplete_blockers"
            echo "╠══════════════════════════════════════════════════════════════════╣"
            echo "║  To proceed, either:                                             ║"
            echo "║    1. Complete the blocking item(s) listed above                 ║"
            echo "║    2. Remove a blocker: kb-backlog unblock $item_id <blocker-id> ║"
            echo "╚══════════════════════════════════════════════════════════════════╝"
            return 1
        fi
    fi

    # Confirmation prompt
    local confirm
    printf "Start working on this item? [Y/n]: "
    read -r confirm

    # Default to yes if empty, check for explicit no
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Cancelled. Item not started."
        return 0
    fi

    echo ""

    # Check if we're in the main worktree - if so, create/use a worktree for this item
    if _kb_is_main_worktree; then
        echo "─────────────────────────────────────"
        echo "📁 You're in the main repository."
        echo "   Setting up worktree for isolated work..."
        echo "─────────────────────────────────────"

        local new_worktree
        new_worktree=$(_kb_create_item_worktree "$item_id" "$title")

        if [[ -n "$new_worktree" ]] && [[ -d "$new_worktree" ]]; then
            echo "─────────────────────────────────────"
            cd "$new_worktree" || {
                echo "Error: Failed to cd into worktree"
                return 1
            }

            # Link worktree to kanban item so kb-run-review and other tools can find it
            local wt_branch wt_timestamp
            wt_branch=$(git branch --show-current 2>/dev/null || echo "")
            wt_timestamp=$(_kb_get_timestamp)
            _kb_jq_update "$board_file" \
                '.backlog[$idx].worktree = $wt |
                 .backlog[$idx].worktreeBranch = $wtb |
                 .backlog[$idx].worktreeLinkedAt = $ts |
                 .lastUpdated = $ts' \
                --argjson idx "$index" \
                --arg wt "$new_worktree" \
                --arg wtb "$wt_branch" \
                --arg ts "$wt_timestamp"
            echo "✓ Linked worktree to [$item_id]"
        else
            echo ""
            echo "─────────────────────────────────────"
            echo "⚠️  Worktree setup failed. Continuing in main repo."
            echo "   You can work here, but consider using a dedicated worktree."
            echo "─────────────────────────────────────"
        fi
    fi

    # Build the prompt
    local prompt="Build a todo list to accomplish this task:\n\n"
    prompt+="## Task ID: $item_id\n"
    prompt+="## Main Task\n$title\n"

    if [[ -n "$description" ]]; then
        prompt+="\n## Description\n$description\n"
    fi

    if [[ -n "$jira_id" ]]; then
        prompt+="\n## JIRA: $jira_id"
    fi

    if [[ -n "$github_issue" ]]; then
        prompt+="\n## GitHub: $github_issue"
    fi

    # Add subitems if present (subitem_count already computed above)
    if [[ "$subitem_count" -gt 0 ]]; then
        prompt+="\n\n## Subitems\n"
        local subitems
        # Include subitem ID in the output
        subitems=$(echo "$item_json" | jq -r '.subitems[] | "- **\(.id)**: [\(.status)] \(.title)\(if .jiraKey then " (\(.jiraKey))" else "" end)"')
        prompt+="$subitems\n"

        prompt+="\n## CRITICAL: Subitem Delegation Requirements\n"
        prompt+="**Subitems are designed for parallel execution by DIFFERENT subagents.**\n"
        prompt+="You (the primary agent) should DELEGATE each subitem to a separate subagent using the Task tool.\n\n"
        prompt+="### Subitem Tracking Commands (for subagents)\n"
        prompt+="Each subagent MUST run these bash commands:\n\n"
        prompt+="**Before Starting Work:**\n"
        prompt+="\`\`\`bash\n"
        prompt+="source ~/dev-team/kanban-helpers.sh && kb-backlog sub start ${item_id}-001\n"
        prompt+="\`\`\`\n\n"
        prompt+="**After Completing Work:**\n"
        prompt+="\`\`\`bash\n"
        prompt+="source ~/dev-team/kanban-helpers.sh && kb-backlog sub done ${item_id}-001\n"
        prompt+="\`\`\`\n\n"
        prompt+="### Delegation Workflow\n"
        prompt+="1. Review all subitems and understand the overall scope\n"
        prompt+="2. For each subitem with status [todo], spawn a subagent using the Task tool\n"
        prompt+="3. Include in each subagent prompt:\n"
        prompt+="   - The subitem ID and description\n"
        prompt+="   - The tracking commands above (sub start/sub done)\n"
        prompt+="   - Context about the parent task as needed\n"
        prompt+="4. Monitor subagent progress or run them in parallel\n"
        prompt+="5. Verify all subitems are marked [completed]\n"
        prompt+="6. **IMPORTANT:** When ALL subitems are complete, run \`source ~/dev-team/kanban-helpers.sh && kb-done\` to mark the parent task as completed\n\n"

        # Inject persona selection guide for this team
        local persona_guide
        persona_guide=$(_kb_get_persona_delegation_guide "$team")
        if [[ -n "$persona_guide" ]]; then
            prompt+="### Subagent Persona Selection\n"
            prompt+="**REQUIRED:** When delegating subitems via the Task tool, set the \`subagent_type\` parameter to the persona matching the work type.\n\n"
            prompt+="$persona_guide\n\n"
            prompt+="Choose the persona whose role best matches the subitem's work. For research/exploration, use \`Explore\`. For simple shell commands, use \`Bash\`.\n\n"
        fi

        prompt+="**DO NOT complete all subitems yourself.** Delegate to subagents for parallel execution.\n"
        prompt+="**DO NOT skip tracking steps.** They update the kanban board so progress is visible in the Fleet Monitor.\n"
        prompt+="**DO NOT directly edit the board JSON files.** Always use the commands above.\n"
        prompt+="**DO NOT close the terminal without running kb-done.** This clears the task from the workflow board.\n"
    fi

    prompt+="\n\nReview the task and subitems above, then wait for approval before delegating work.\n"
    prompt+="When approved, DELEGATE each subitem to a separate subagent using the Task tool.\n"
    prompt+="When ALL subitems are complete, run \`kb-done\` to mark the task as completed before closing the terminal."

    # Check for worktree conflicts before starting
    local worktree_path conflict
    worktree_path=$(_kb_get_worktree)
    if [[ -n "$worktree_path" ]]; then
        conflict=$(_kb_check_worktree_conflict "$board_file" "$item_id" "$worktree_path")
        if [[ -n "$conflict" ]]; then
            _kb_warn_worktree_conflict "$conflict"
        fi
    fi

    echo "Launching Claude Code with task [$item_id]: $title"
    echo "─────────────────────────────────────"

    # Mark item as actively being worked on with worktree info
    local timestamp worktree worktree_branch window_id
    timestamp=$(_kb_get_timestamp)
    worktree=$(_kb_get_worktree)
    worktree_branch=$(git branch --show-current 2>/dev/null || echo "")

    # Get window ID for linking
    local rest="${context#*:}"
    local terminal="${rest%%:*}"
    rest="${rest#*:}"
    local window_name="${rest#*:}"
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    if ! _kb_jq_update "$board_file" \
       '.backlog[$idx].activelyWorking = true |
        .backlog[$idx].workStartedAt = $ts |
        .backlog[$idx].startedAt //= $ts |
        .backlog[$idx].worktree = $wt |
        .backlog[$idx].worktreeBranch = $wtb |
        .backlog[$idx].worktreeWindowId = $wid |
        .backlog[$idx].updatedAt = $ts |
        .lastUpdated = $ts' \
       --argjson idx "$index" \
       --arg ts "$timestamp" \
       --arg wt "$worktree" \
       --arg wtb "$worktree_branch" \
       --arg wid "$window_id"; then
        echo "Warning: Failed to update board file. Debug info:" >&2
        echo "  board_file=$board_file" >&2
        echo "  index=$index, timestamp=$timestamp" >&2
        echo "  worktree=$worktree, branch=$worktree_branch" >&2
        echo "  window_id=$window_id" >&2
    fi

    # Update window status to planning and set working item
    kb-plan "$title"
    _kb_set_working_on "$item_id"

    # Launch cc with the prompt
    echo -e "$prompt" | cc
}

# Work on a task without creating a worktree - for when you're already in the right place
# Usage: kb-work <id>
# Like kb-run but doesn't create worktree/branch - works in current directory
kb-work() {
    _kb_ensure_jq || return 1

    local selector="$1"

    if [[ -z "$selector" ]]; then
        echo "Usage: kb-work <id>"
        echo "Launches Claude Code with task details WITHOUT creating worktree."
        echo "Use when you're already in the correct directory/worktree."
        echo "Use 'kb-backlog list' to see available items"
        echo "Example: kb-work XFRE-0001"
        echo ""
        echo "For automatic worktree setup, use: kb-run <id>"
        return 1
    fi

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Resolve selector to index
    local index
    index=$(_kb_resolve_selector "$board_file" "$selector")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Read the full backlog item
    local item_json
    item_json=$(_kb_jq_read "$board_file" ".backlog[$index] // empty")

    if [[ -z "$item_json" ]] || [[ "$item_json" == "null" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Extract item details
    local item_id title description jira_id github_issue priority item_status due_date tags
    item_id=$(echo "$item_json" | jq -r '.id // empty')
    title=$(echo "$item_json" | jq -r '.title // empty')
    description=$(echo "$item_json" | jq -r '.description // empty')
    jira_id=$(echo "$item_json" | jq -r '.jiraId // empty')
    github_issue=$(echo "$item_json" | jq -r '.githubIssue // empty')
    priority=$(echo "$item_json" | jq -r '.priority // "medium"')
    item_status=$(echo "$item_json" | jq -r '.status // "todo"')
    due_date=$(echo "$item_json" | jq -r '.dueDate // empty')
    tags=$(echo "$item_json" | jq -r '(.tags // []) | join(", ")')

    # Check if item is blocked
    local blocked_by
    blocked_by=$(echo "$item_json" | jq -r '(.blockedBy // []) | join(", ")')
    if [[ "$item_status" == "blocked" ]] || [[ "$priority" == "blocked" ]] || [[ -n "$blocked_by" ]]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║                     ⚠️  ITEM BLOCKED  ⚠️                           ║"
        echo "╠══════════════════════════════════════════════════════════════════╣"
        echo "║"
        echo "║  ID:       $item_id"
        echo "║  Title:    $title"
        echo "║"
        echo "║  This item cannot be started because it is blocked by:"
        for blocker in $(echo "$blocked_by" | tr ',' '\n'); do
            local blocker_trim="${blocker## }"
            blocker_trim="${blocker_trim%% }"
            if [[ -n "$blocker_trim" ]]; then
                local blocker_title
                blocker_title=$(_kb_jq_read "$board_file" '.backlog[] | select(.id == $id) | .title' --arg id "$blocker_trim" -r 2>/dev/null || echo "")
                echo "║    → [$blocker_trim] $blocker_title"
            fi
        done
        echo "║"
        echo "║  Complete the blocking items first, or use:"
        echo "║    kb-backlog unblock $item_id"
        echo "║  to remove the blockers."
        echo "║"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        return 1
    fi

    # Get subitem count and details
    local subitem_count
    subitem_count=$(echo "$item_json" | jq '.subitems // [] | length')

    # Display item details for confirmation
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                     KANBAN ITEM DETAILS                          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║"
    echo "║  ID:       $item_id"
    echo "║  Title:    $title"
    echo "║"
    echo "║  Priority: $(printf '%-12s' "$priority" | tr '[:lower:]' '[:upper:]')  Status: $item_status"
    if [[ -n "$due_date" ]]; then
        echo "║  Due Date: $due_date"
    fi
    if [[ -n "$tags" ]]; then
        echo "║  Tags:     $tags"
    fi
    echo "║"

    # Show description if present
    if [[ -n "$description" ]]; then
        echo "║  Description:"
        echo "$description" | fold -w 60 -s | while IFS= read -r line; do
            echo "║    $line"
        done
        echo "║"
    fi

    # Show external links
    if [[ -n "$jira_id" ]] || [[ -n "$github_issue" ]]; then
        echo "║  Links:"
        [[ -n "$jira_id" ]] && echo "║    JIRA:   $jira_id"
        [[ -n "$github_issue" ]] && echo "║    GitHub: $github_issue"
        echo "║"
    fi

    # Show subitems summary
    if [[ "$subitem_count" -gt 0 ]]; then
        local completed_count in_progress_count todo_count
        completed_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "completed")] | length')
        in_progress_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "in_progress")] | length')
        todo_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "todo")] | length')

        cancelled_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "cancelled")] | length')
        if [[ "$cancelled_count" -gt 0 ]]; then
            echo "║  Subitems: $subitem_count total ($completed_count done, $cancelled_count cancelled, $in_progress_count in progress, $todo_count todo)"
        else
            echo "║  Subitems: $subitem_count total ($completed_count done, $in_progress_count in progress, $todo_count todo)"
        fi
        echo "║"
        echo "$item_json" | jq -r '.subitems[] | "║    [\(.status | if . == "completed" then "✓" elif . == "cancelled" then "✗" elif . == "in_progress" then "●" else "○" end)] \(.id): \(.title)"'
        echo "║"
    fi

    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check if item is blocked by incomplete items
    local blocked_by_ids incomplete_blockers
    blocked_by_ids=$(echo "$item_json" | jq -r '(.blockedBy // []) | .[]' 2>/dev/null)

    if [[ -n "$blocked_by_ids" ]]; then
        incomplete_blockers=""
        while IFS= read -r blocker_id; do
            [[ -z "$blocker_id" ]] && continue
            local blocker_status
            blocker_status=$(_kb_jq_read "$board_file" \
                '.backlog[] | select(.id == $bid) | .status // "unknown"' \
                --arg bid "$blocker_id" -r 2>/dev/null)

            if [[ -n "$blocker_status" ]] && [[ "$blocker_status" != "completed" ]] && [[ "$blocker_status" != "cancelled" ]]; then
                local blocker_title
                blocker_title=$(_kb_jq_read "$board_file" \
                    '.backlog[] | select(.id == $bid) | .title // "Unknown"' \
                    --arg bid "$blocker_id" -r 2>/dev/null)
                incomplete_blockers+="    ⛔ $blocker_id: $blocker_title [$blocker_status]\n"
            fi
        done <<< "$blocked_by_ids"

        if [[ -n "$incomplete_blockers" ]]; then
            echo "╔══════════════════════════════════════════════════════════════════╗"
            echo "║  ⛔ BLOCKED: Cannot start - dependencies not complete            ║"
            echo "╠══════════════════════════════════════════════════════════════════╣"
            echo "║  Blocked by:                                                     ║"
            echo -e "$incomplete_blockers"
            echo "╠══════════════════════════════════════════════════════════════════╣"
            echo "║  To proceed, either:                                             ║"
            echo "║    1. Complete the blocking item(s) listed above                 ║"
            echo "║    2. Remove a blocker: kb-backlog unblock $item_id <blocker-id> ║"
            echo "╚══════════════════════════════════════════════════════════════════╝"
            return 1
        fi
    fi

    # Confirmation prompt - note we're NOT creating a worktree
    local confirm
    echo "📁 Working in current directory: $(pwd)"
    echo "   (No worktree will be created)"
    echo ""
    printf "Start working on this item? [Y/n]: "
    read -r confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Cancelled. Item not started."
        return 0
    fi

    echo ""

    # Build the prompt (same as kb-run)
    local prompt="Build a todo list to accomplish this task:\n\n"
    prompt+="## Task ID: $item_id\n"
    prompt+="## Main Task\n$title\n"

    if [[ -n "$description" ]]; then
        prompt+="\n## Description\n$description\n"
    fi

    if [[ -n "$jira_id" ]]; then
        prompt+="\n## JIRA: $jira_id"
    fi

    if [[ -n "$github_issue" ]]; then
        prompt+="\n## GitHub: $github_issue"
    fi

    # Add subitems if present
    if [[ "$subitem_count" -gt 0 ]]; then
        prompt+="\n\n## Subitems\n"
        local subitems
        subitems=$(echo "$item_json" | jq -r '.subitems[] | "- **\(.id)**: [\(.status)] \(.title)\(if .jiraKey then " (\(.jiraKey))" else "" end)"')
        prompt+="$subitems\n"

        prompt+="\n## CRITICAL: Subitem Delegation Requirements\n"
        prompt+="**Subitems are designed for parallel execution by DIFFERENT subagents.**\n"
        prompt+="You (the primary agent) should DELEGATE each subitem to a separate subagent using the Task tool.\n\n"
        prompt+="### Subitem Tracking Commands (for subagents)\n"
        prompt+="Each subagent MUST run these bash commands:\n\n"
        prompt+="**Before Starting Work:**\n"
        prompt+="\`\`\`bash\n"
        prompt+="source ~/dev-team/kanban-helpers.sh && kb-backlog sub start ${item_id}-001\n"
        prompt+="\`\`\`\n\n"
        prompt+="**After Completing Work:**\n"
        prompt+="\`\`\`bash\n"
        prompt+="source ~/dev-team/kanban-helpers.sh && kb-backlog sub done ${item_id}-001\n"
        prompt+="\`\`\`\n\n"
        prompt+="### Delegation Workflow\n"
        prompt+="1. Review all subitems and understand the overall scope\n"
        prompt+="2. For each subitem with status [todo], spawn a subagent using the Task tool\n"
        prompt+="3. Include in each subagent prompt:\n"
        prompt+="   - The subitem ID and description\n"
        prompt+="   - The tracking commands above (sub start/sub done)\n"
        prompt+="   - Context about the parent task as needed\n"
        prompt+="4. Monitor subagent progress or run them in parallel\n"
        prompt+="5. Verify all subitems are marked [completed]\n"
        prompt+="6. **IMPORTANT:** When ALL subitems are complete, run \`source ~/dev-team/kanban-helpers.sh && kb-done\` to mark the parent task as completed\n\n"

        # Inject persona selection guide for this team
        local persona_guide
        persona_guide=$(_kb_get_persona_delegation_guide "$team")
        if [[ -n "$persona_guide" ]]; then
            prompt+="### Subagent Persona Selection\n"
            prompt+="**REQUIRED:** When delegating subitems via the Task tool, set the \`subagent_type\` parameter to the persona matching the work type.\n\n"
            prompt+="$persona_guide\n\n"
            prompt+="Choose the persona whose role best matches the subitem's work. For research/exploration, use \`Explore\`. For simple shell commands, use \`Bash\`.\n\n"
        fi

        prompt+="**DO NOT complete all subitems yourself.** Delegate to subagents for parallel execution.\n"
        prompt+="**DO NOT skip tracking steps.** They update the kanban board so progress is visible in the Fleet Monitor.\n"
        prompt+="**DO NOT directly edit the board JSON files.** Always use the commands above.\n"
        prompt+="**DO NOT close the terminal without running kb-done.** This clears the task from the workflow board.\n"
    fi

    prompt+="\n\nReview the task and subitems above, then wait for approval before delegating work.\n"
    prompt+="When approved, DELEGATE each subitem to a separate subagent using the Task tool.\n"
    prompt+="When ALL subitems are complete, run \`kb-done\` to mark the task as completed before closing the terminal."

    # Check for worktree conflicts before starting
    local worktree_path conflict
    worktree_path=$(_kb_get_worktree)
    if [[ -n "$worktree_path" ]]; then
        conflict=$(_kb_check_worktree_conflict "$board_file" "$item_id" "$worktree_path")
        if [[ -n "$conflict" ]]; then
            _kb_warn_worktree_conflict "$conflict"
        fi
    fi

    echo "Launching Claude Code with task [$item_id]: $title"
    echo "─────────────────────────────────────"

    # Mark item as actively being worked on with worktree info
    local timestamp worktree worktree_branch window_id
    timestamp=$(_kb_get_timestamp)
    worktree=$(_kb_get_worktree)
    worktree_branch=$(git branch --show-current 2>/dev/null || echo "")

    # Get window ID for linking
    local rest="${context#*:}"
    local terminal="${rest%%:*}"
    rest="${rest#*:}"
    local window_name="${rest#*:}"
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    if ! _kb_jq_update "$board_file" \
       '.backlog[$idx].activelyWorking = true |
        .backlog[$idx].workStartedAt = $ts |
        .backlog[$idx].startedAt //= $ts |
        .backlog[$idx].worktree = $wt |
        .backlog[$idx].worktreeBranch = $wtb |
        .backlog[$idx].worktreeWindowId = $wid |
        .backlog[$idx].updatedAt = $ts |
        .lastUpdated = $ts' \
       --argjson idx "$index" \
       --arg ts "$timestamp" \
       --arg wt "$worktree" \
       --arg wtb "$worktree_branch" \
       --arg wid "$window_id"; then
        echo "Warning: Failed to update board file. Debug info:" >&2
        echo "  board_file=$board_file" >&2
        echo "  index=$index, timestamp=$timestamp" >&2
        echo "  worktree=$worktree, branch=$worktree_branch" >&2
        echo "  window_id=$window_id" >&2
    fi

    # Update window status to planning and set working item
    kb-plan "$title"
    _kb_set_working_on "$item_id"

    # Launch cc with the prompt
    echo -e "$prompt" | cc
}

# Review a PR for a kanban item by switching to its worktree
# Usage: kb-run-review <id>
# Like kb-run but launches Claude Code with a PR review prompt instead of an implementation prompt
kb-run-review() {
    _kb_ensure_jq || return 1

    local selector="$1"

    if [[ -z "$selector" ]]; then
        echo "Usage: kb-run-review <id>"
        echo "Switches to item's worktree and launches Claude Code to review the related PR."
        echo "Use 'kb-backlog list' to see available items"
        echo "Example: kb-run-review XFRE-0001"
        echo ""
        echo "To review without switching worktree, use: kb-work-review <id>"
        return 1
    fi

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Resolve selector to index
    local index
    index=$(_kb_resolve_selector "$board_file" "$selector")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Read the full backlog item
    local item_json
    item_json=$(_kb_jq_read "$board_file" ".backlog[$index] // empty")

    if [[ -z "$item_json" ]] || [[ "$item_json" == "null" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Extract item details
    local item_id title description jira_id github_issue priority item_status due_date tags
    item_id=$(echo "$item_json" | jq -r '.id // empty')
    title=$(echo "$item_json" | jq -r '.title // empty')
    description=$(echo "$item_json" | jq -r '.description // empty')
    jira_id=$(echo "$item_json" | jq -r '.jiraId // empty')
    github_issue=$(echo "$item_json" | jq -r '.githubIssue // empty')
    priority=$(echo "$item_json" | jq -r '.priority // "medium"')
    item_status=$(echo "$item_json" | jq -r '.status // "todo"')
    due_date=$(echo "$item_json" | jq -r '.dueDate // empty')
    tags=$(echo "$item_json" | jq -r '(.tags // []) | join(", ")')

    # Get subitem count
    local subitem_count
    subitem_count=$(echo "$item_json" | jq '.subitems // [] | length')

    # Get worktree info from the item (if it has one)
    local item_worktree item_worktree_branch
    item_worktree=$(echo "$item_json" | jq -r '.worktree // empty')
    item_worktree_branch=$(echo "$item_json" | jq -r '.worktreeBranch // empty')

    # Display item details for review confirmation
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                     PR REVIEW REQUEST                            ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║"
    echo "║  ID:       $item_id"
    echo "║  Title:    $title"
    echo "║"
    echo "║  Priority: $(printf '%-12s' "$priority" | tr '[:lower:]' '[:upper:]')  Status: $item_status"
    if [[ -n "$due_date" ]]; then
        echo "║  Due Date: $due_date"
    fi
    if [[ -n "$tags" ]]; then
        echo "║  Tags:     $tags"
    fi
    echo "║"

    if [[ -n "$description" ]]; then
        echo "║  Description:"
        echo "$description" | fold -w 60 -s | while IFS= read -r line; do
            echo "║    $line"
        done
        echo "║"
    fi

    if [[ -n "$jira_id" ]] || [[ -n "$github_issue" ]]; then
        echo "║  Links:"
        [[ -n "$jira_id" ]] && echo "║    JIRA:   $jira_id"
        [[ -n "$github_issue" ]] && echo "║    GitHub: $github_issue"
        echo "║"
    fi

    if [[ -n "$item_worktree" ]]; then
        echo "║  Worktree: $item_worktree"
    fi
    if [[ -n "$item_worktree_branch" ]]; then
        echo "║  Branch:   $item_worktree_branch"
    fi
    echo "║"

    if [[ "$subitem_count" -gt 0 ]]; then
        local completed_count in_progress_count todo_count
        completed_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "completed")] | length')
        in_progress_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "in_progress")] | length')
        todo_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "todo")] | length')

        cancelled_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "cancelled")] | length')
        if [[ "$cancelled_count" -gt 0 ]]; then
            echo "║  Subitems: $subitem_count total ($completed_count done, $cancelled_count cancelled, $in_progress_count in progress, $todo_count todo)"
        else
            echo "║  Subitems: $subitem_count total ($completed_count done, $in_progress_count in progress, $todo_count todo)"
        fi
        echo "║"
    fi

    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Confirmation prompt
    local confirm
    printf "Start reviewing this item's PR? [Y/n]: "
    read -r confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Cancelled. Review not started."
        return 0
    fi

    echo ""

    # Switch to worktree if we're in the main repo and the item has a worktree
    if _kb_is_main_worktree; then
        if [[ -n "$item_worktree" ]] && [[ -d "$item_worktree" ]]; then
            echo "─────────────────────────────────────"
            echo "📁 Switching to item's worktree..."
            echo "   $item_worktree"
            echo "─────────────────────────────────────"
            cd "$item_worktree" || {
                echo "Error: Failed to cd into worktree: $item_worktree"
                return 1
            }
        else
            echo "─────────────────────────────────────"
            echo "⚠️  No worktree found for this item."
            echo "   Staying in current directory: $(pwd)"
            echo "─────────────────────────────────────"
        fi
    fi

    # Build the review prompt
    local prompt="You are reviewing a Pull Request for kanban item [$item_id].\n\n"
    prompt+="## Task Being Reviewed\n"
    prompt+="**ID:** $item_id\n"
    prompt+="**Title:** $title\n"

    if [[ -n "$description" ]]; then
        prompt+="\n**Description:** $description\n"
    fi

    if [[ -n "$item_worktree_branch" ]]; then
        prompt+="\n**Branch:** $item_worktree_branch\n"
    fi

    prompt+="\n## Your Mission\n"
    prompt+="1. **Find the open PR** for this item. Try these approaches:\n"
    prompt+="   - Run: \`gh pr list --head $item_worktree_branch\` (if branch is known)\n"
    prompt+="   - Run: \`gh pr list --search \"$item_id\" --state open\`\n"
    prompt+="   - Run: \`gh pr list --state open\` and look for a matching PR\n"
    prompt+="\n2. **Review the PR** using the standard checklist:\n"
    prompt+="   - **Security**: No hardcoded secrets, no injection vulnerabilities, proper input validation\n"
    prompt+="   - **Architecture**: Follows existing patterns, appropriate separation of concerns, no unnecessary coupling\n"
    prompt+="   - **Code Quality**: No force unwraps without justification, proper error handling, no commented-out code\n"
    prompt+="   - **Performance**: Weak self in closures, no memory leaks, efficient algorithms\n"
    prompt+="   - **Testing**: Changes are testable, edge cases considered, error paths handled\n"
    prompt+="\n3. **Check the diff thoroughly:**\n"
    prompt+="   \`\`\`bash\n"
    prompt+="   gh pr diff <number>\n"
    prompt+="   \`\`\`\n"
    prompt+="\n4. **Submit your review** using gh-bot-review (NOT gh pr review):\n"
    prompt+="   \`\`\`bash\n"
    prompt+="   # To approve:\n"
    prompt+="   gh-bot-review --pr <number> --event APPROVE --body \"LGTM - <summary of why it's good>\"\n"
    prompt+="\n"
    prompt+="   # To request changes:\n"
    prompt+="   gh-bot-review --pr <number> --event REQUEST_CHANGES --body \"<specific feedback>\"\n"
    prompt+="\n"
    prompt+="   # For detailed reviews, write to a temp file first:\n"
    prompt+="   # Write feedback to /tmp/review-<number>.md, then:\n"
    prompt+="   gh-bot-review --pr <number> --event REQUEST_CHANGES --body-file /tmp/review-<number>.md\n"
    prompt+="   \`\`\`\n"
    prompt+="\n## CRITICAL Rules\n"
    prompt+="- **USE gh-bot-review** for submitting reviews, NOT \`gh pr review\` (same-account restriction)\n"
    prompt+="- **DO NOT MERGE** the PR — the creating agent's monitoring loop handles merge after bot approval\n"
    prompt+="- Be specific about what needs to change and why\n"
    prompt+="- Distinguish between blocking issues and suggestions (use \"nit:\" prefix for minor style suggestions)\n"
    prompt+="- Provide code examples when suggesting alternatives\n"

    echo "Launching Claude Code for PR review of [$item_id]: $title"
    echo "─────────────────────────────────────"

    # Update window status
    kb-plan "Review: $title"
    _kb_set_working_on "$item_id"

    # Launch cc with the review prompt
    echo -e "$prompt" | cc
}

# Review a PR for a kanban item in the current directory (no worktree switch)
# Usage: kb-work-review <id>
# Like kb-work but launches Claude Code with a PR review prompt instead of an implementation prompt
kb-work-review() {
    _kb_ensure_jq || return 1

    local selector="$1"

    if [[ -z "$selector" ]]; then
        echo "Usage: kb-work-review <id>"
        echo "Launches Claude Code to review the related PR WITHOUT switching worktree."
        echo "Use when you're already in the correct directory/worktree."
        echo "Use 'kb-backlog list' to see available items"
        echo "Example: kb-work-review XFRE-0001"
        echo ""
        echo "For automatic worktree switch, use: kb-run-review <id>"
        return 1
    fi

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Resolve selector to index
    local index
    index=$(_kb_resolve_selector "$board_file" "$selector")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Read the full backlog item
    local item_json
    item_json=$(_kb_jq_read "$board_file" ".backlog[$index] // empty")

    if [[ -z "$item_json" ]] || [[ "$item_json" == "null" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Extract item details
    local item_id title description jira_id github_issue priority item_status due_date tags
    item_id=$(echo "$item_json" | jq -r '.id // empty')
    title=$(echo "$item_json" | jq -r '.title // empty')
    description=$(echo "$item_json" | jq -r '.description // empty')
    jira_id=$(echo "$item_json" | jq -r '.jiraId // empty')
    github_issue=$(echo "$item_json" | jq -r '.githubIssue // empty')
    priority=$(echo "$item_json" | jq -r '.priority // "medium"')
    item_status=$(echo "$item_json" | jq -r '.status // "todo"')
    due_date=$(echo "$item_json" | jq -r '.dueDate // empty')
    tags=$(echo "$item_json" | jq -r '(.tags // []) | join(", ")')

    # Get subitem count
    local subitem_count
    subitem_count=$(echo "$item_json" | jq '.subitems // [] | length')

    # Get worktree info from the item (for branch name in the review prompt)
    local item_worktree item_worktree_branch
    item_worktree=$(echo "$item_json" | jq -r '.worktree // empty')
    item_worktree_branch=$(echo "$item_json" | jq -r '.worktreeBranch // empty')

    # Display item details for review confirmation
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                     PR REVIEW REQUEST                            ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║"
    echo "║  ID:       $item_id"
    echo "║  Title:    $title"
    echo "║"
    echo "║  Priority: $(printf '%-12s' "$priority" | tr '[:lower:]' '[:upper:]')  Status: $item_status"
    if [[ -n "$due_date" ]]; then
        echo "║  Due Date: $due_date"
    fi
    if [[ -n "$tags" ]]; then
        echo "║  Tags:     $tags"
    fi
    echo "║"

    if [[ -n "$description" ]]; then
        echo "║  Description:"
        echo "$description" | fold -w 60 -s | while IFS= read -r line; do
            echo "║    $line"
        done
        echo "║"
    fi

    if [[ -n "$jira_id" ]] || [[ -n "$github_issue" ]]; then
        echo "║  Links:"
        [[ -n "$jira_id" ]] && echo "║    JIRA:   $jira_id"
        [[ -n "$github_issue" ]] && echo "║    GitHub: $github_issue"
        echo "║"
    fi

    if [[ -n "$item_worktree_branch" ]]; then
        echo "║  Branch:   $item_worktree_branch"
    fi
    echo "║"

    if [[ "$subitem_count" -gt 0 ]]; then
        local completed_count in_progress_count todo_count
        completed_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "completed")] | length')
        in_progress_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "in_progress")] | length')
        todo_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "todo")] | length')

        cancelled_count=$(echo "$item_json" | jq '[.subitems[] | select(.status == "cancelled")] | length')
        if [[ "$cancelled_count" -gt 0 ]]; then
            echo "║  Subitems: $subitem_count total ($completed_count done, $cancelled_count cancelled, $in_progress_count in progress, $todo_count todo)"
        else
            echo "║  Subitems: $subitem_count total ($completed_count done, $in_progress_count in progress, $todo_count todo)"
        fi
        echo "║"
    fi

    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Confirmation prompt
    local confirm
    echo "📁 Reviewing in current directory: $(pwd)"
    echo "   (No worktree switch will be made)"
    echo ""
    printf "Start reviewing this item's PR? [Y/n]: "
    read -r confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Cancelled. Review not started."
        return 0
    fi

    echo ""

    # Build the review prompt
    local prompt="You are reviewing a Pull Request for kanban item [$item_id].\n\n"
    prompt+="## Task Being Reviewed\n"
    prompt+="**ID:** $item_id\n"
    prompt+="**Title:** $title\n"

    if [[ -n "$description" ]]; then
        prompt+="\n**Description:** $description\n"
    fi

    if [[ -n "$item_worktree_branch" ]]; then
        prompt+="\n**Branch:** $item_worktree_branch\n"
    fi

    prompt+="\n## Your Mission\n"
    prompt+="1. **Find the open PR** for this item. Try these approaches:\n"
    prompt+="   - Run: \`gh pr list --head $item_worktree_branch\` (if branch is known)\n"
    prompt+="   - Run: \`gh pr list --search \"$item_id\" --state open\`\n"
    prompt+="   - Run: \`gh pr list --state open\` and look for a matching PR\n"
    prompt+="\n2. **Review the PR** using the standard checklist:\n"
    prompt+="   - **Security**: No hardcoded secrets, no injection vulnerabilities, proper input validation\n"
    prompt+="   - **Architecture**: Follows existing patterns, appropriate separation of concerns, no unnecessary coupling\n"
    prompt+="   - **Code Quality**: No force unwraps without justification, proper error handling, no commented-out code\n"
    prompt+="   - **Performance**: Weak self in closures, no memory leaks, efficient algorithms\n"
    prompt+="   - **Testing**: Changes are testable, edge cases considered, error paths handled\n"
    prompt+="\n3. **Check the diff thoroughly:**\n"
    prompt+="   \`\`\`bash\n"
    prompt+="   gh pr diff <number>\n"
    prompt+="   \`\`\`\n"
    prompt+="\n4. **Submit your review** using gh-bot-review (NOT gh pr review):\n"
    prompt+="   \`\`\`bash\n"
    prompt+="   # To approve:\n"
    prompt+="   gh-bot-review --pr <number> --event APPROVE --body \"LGTM - <summary of why it's good>\"\n"
    prompt+="\n"
    prompt+="   # To request changes:\n"
    prompt+="   gh-bot-review --pr <number> --event REQUEST_CHANGES --body \"<specific feedback>\"\n"
    prompt+="\n"
    prompt+="   # For detailed reviews, write to a temp file first:\n"
    prompt+="   # Write feedback to /tmp/review-<number>.md, then:\n"
    prompt+="   gh-bot-review --pr <number> --event REQUEST_CHANGES --body-file /tmp/review-<number>.md\n"
    prompt+="   \`\`\`\n"
    prompt+="\n## CRITICAL Rules\n"
    prompt+="- **USE gh-bot-review** for submitting reviews, NOT \`gh pr review\` (same-account restriction)\n"
    prompt+="- **DO NOT MERGE** the PR — the creating agent's monitoring loop handles merge after bot approval\n"
    prompt+="- Be specific about what needs to change and why\n"
    prompt+="- Distinguish between blocking issues and suggestions (use \"nit:\" prefix for minor style suggestions)\n"
    prompt+="- Provide code examples when suggesting alternatives\n"

    echo "Launching Claude Code for PR review of [$item_id]: $title"
    echo "─────────────────────────────────────"

    # Update window status
    kb-plan "Review: $title"
    _kb_set_working_on "$item_id"

    # Launch cc with the review prompt
    echo -e "$prompt" | cc
}

# Show current window's status
kb-my-status() {
    _kb_ensure_jq || return 1

    local context team terminal window_index window_name board_file window_id
    context=$(_kb_detect_context)
    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"
    rest="${rest#*:}"
    window_index="${rest%%:*}"
    window_name="${rest#*:}"
    board_file=$(_kb_get_board_file "$team")
    window_id=$(_kb_get_window_id "$terminal" "$window_name")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    echo "Window: $terminal:$window_name"
    echo "Worktree: $(_kb_get_worktree_short)"
    echo "─────────────────────────────────────"

    # Get window info from activeWindows
    local window_info
    window_info=$(_kb_jq_read "$board_file" '.activeWindows[] | select(.id == $id)' --arg id "$window_id" 2>/dev/null)

    if [[ -z "$window_info" ]] || [[ "$window_info" == "null" ]]; then
        echo "Window not active on board"
        echo "─────────────────────────────────────"
        return 0
    fi

    # Extract basic info (using win_ prefix to avoid readonly variable conflicts)
    local win_status win_task win_working_on win_started
    win_status=$(echo "$window_info" | jq -r '.status // "unknown"')
    win_task=$(echo "$window_info" | jq -r '.task // "None"')
    win_working_on=$(echo "$window_info" | jq -r '.workingOnId // empty')
    win_started=$(echo "$window_info" | jq -r '.startedAt // "N/A"')

    echo "Status: $win_status"
    echo "Task: $win_task"

    # Show working item/subitem details
    if [[ -n "$win_working_on" ]]; then
        local item_title
        # Check if it's a subitem (format: XXXX-####-###) or item (format: XXXX-####)
        if [[ "$win_working_on" =~ ^X[A-Z]{3}-[0-9]+-[0-9]+$ ]]; then
            # Subitem - extract parent and subitem index
            local parent_id="${win_working_on%-*}"
            local sub_num="${win_working_on##*-}"
            local sub_idx=$((10#$sub_num - 1))
            item_title=$(_kb_jq_read "$board_file" \
                '.backlog[] | select(.id == $pid) | .subitems[$idx].title // empty' \
                --arg pid "$parent_id" --argjson idx "$sub_idx" -r 2>/dev/null)
            if [[ -n "$item_title" ]]; then
                echo "Working On: [$win_working_on] $item_title (subitem)"
            else
                echo "Working On: $win_working_on"
            fi
        else
            # Regular item
            item_title=$(_kb_jq_read "$board_file" \
                '.backlog[] | select(.id == $id) | .title // empty' \
                --arg id "$win_working_on" -r 2>/dev/null)
            if [[ -n "$item_title" ]]; then
                echo "Working On: [$win_working_on] $item_title"
            else
                echo "Working On: $win_working_on"
            fi
        fi
    fi

    echo "Started: $win_started"

    # Show paused info if paused
    if [[ "$win_status" == "paused" ]]; then
        local win_paused_reason win_prev_status
        win_paused_reason=$(echo "$window_info" | jq -r '.pausedReason // "No reason given"')
        win_prev_status=$(echo "$window_info" | jq -r '.previousStatus // "unknown"')
        echo "─────────────────────────────────────"
        echo "⏸️  PAUSED: $win_paused_reason"
        echo "   (was: $win_prev_status)"
    fi

    echo "─────────────────────────────────────"
}

# Show the full kanban board
kb-show() {
    _kb_ensure_jq || return 1

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  KANBAN BOARD: ${team} - $(_kb_jq_read "$board_file" '.ship' -r)"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    local statuses=("planning" "coding" "testing" "commit")

    for status in "${statuses[@]}"; do
        local count
        count=$(_kb_jq_read "$board_file" '[.activeWindows[] | select(.status == $s)] | length' --arg s "$status" -r)

        if [[ "$count" -gt 0 ]]; then
            echo "[$status]"
            _kb_jq_read "$board_file" '.activeWindows[] | select(.status == $s) |
                "  \(.terminal):\(.windowName) [\(.worktree // "?")] - \(.task // "No task")"' --arg s "$status" -r
            echo ""
        fi
    done

    local backlog_count
    backlog_count=$(_kb_jq_read "$board_file" '.backlog | length' -r)
    echo "Active Windows: $(_kb_jq_read "$board_file" '.activeWindows | length' -r)"
    echo "Backlog: $backlog_count items"
    echo ""
}

# Watch the kanban board with auto-refresh
kb-watch() {
    local interval="${1:-5}"
    echo "Watching kanban board (refresh every ${interval}s)"
    echo "Press Ctrl+C to stop"

    while true; do
        clear
        kb-show
        sleep "$interval"
    done
}

# Link current worktree to a backlog item (without starting work)
# Usage: kb-link-worktree <item-id>
# This is useful for git-worktree skill integration
kb-link-worktree() {
    _kb_ensure_jq || return 1

    local selector="$1"

    if [[ -z "$selector" ]]; then
        echo "Usage: kb-link-worktree <item-id>"
        echo "Links the current worktree to a backlog item without starting work."
        echo ""
        echo "This is useful when:"
        echo "  - Creating a worktree for future work on an item"
        echo "  - Setting up worktree associations for the git-worktree skill"
        echo ""
        echo "Example: kb-link-worktree XFRE-0001"
        return 1
    fi

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Resolve selector to index
    local index
    index=$(_kb_resolve_selector "$board_file" "$selector")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    # Get current worktree info
    local worktree worktree_branch item_id title
    worktree=$(_kb_get_worktree)
    worktree_branch=$(git branch --show-current 2>/dev/null || echo "")
    item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)
    title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)

    if [[ -z "$worktree" ]]; then
        echo "Error: Not in a git repository/worktree"
        return 1
    fi

    # Check for conflicts
    local conflict
    conflict=$(_kb_check_worktree_conflict "$board_file" "$item_id" "$worktree")
    if [[ -n "$conflict" ]]; then
        _kb_warn_worktree_conflict "$conflict"
    fi

    local timestamp
    timestamp=$(_kb_get_timestamp)

    # Update item with worktree info (but don't mark as actively working)
    _kb_jq_update "$board_file" \
       '.backlog[$idx].worktree = $wt |
        .backlog[$idx].worktreeBranch = $wtb |
        .backlog[$idx].worktreeLinkedAt = $ts |
        .lastUpdated = $ts' \
       --argjson idx "$index" \
       --arg wt "$worktree" \
       --arg wtb "$worktree_branch" \
       --arg ts "$timestamp"

    echo "✓ Linked worktree to [$item_id]: $title"
    echo "  Worktree: $(_kb_get_worktree_short)"
    echo "  Branch: $worktree_branch"
    echo ""
    echo "Use 'kb-pick $item_id' to start working on this item."
}

# Unlink worktree from a backlog item
# Usage: kb-unlink-worktree <item-id>
kb-unlink-worktree() {
    _kb_ensure_jq || return 1

    local selector="$1"

    if [[ -z "$selector" ]]; then
        echo "Usage: kb-unlink-worktree <item-id>"
        echo "Removes worktree association from a backlog item."
        return 1
    fi

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Resolve selector to index
    local index
    index=$(_kb_resolve_selector "$board_file" "$selector")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $selector"
        return 1
    fi

    local item_id title
    item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)
    title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)

    local timestamp
    timestamp=$(_kb_get_timestamp)

    # Clear worktree info
    _kb_jq_update "$board_file" \
       'del(.backlog[$idx].worktree) |
        del(.backlog[$idx].worktreeBranch) |
        del(.backlog[$idx].worktreeLinkedAt) |
        del(.backlog[$idx].worktreeWindowId) |
        .lastUpdated = $ts' \
       --argjson idx "$index" \
       --arg ts "$timestamp"

    echo "✓ Unlinked worktree from [$item_id]: $title"
}

# Launch the LCARS graphical web interface
kb-ui() {
    local port="${1:-8080}"
    local ui_dir="${HOME}/dev-team/lcars-ui"

    if [[ -f "${ui_dir}/server.py" ]]; then
        echo "Launching LCARS on port $port..."
        python3 "${ui_dir}/server.py" "$port" &
        sleep 2
        open "http://localhost:$port"
    else
        echo "Error: LCARS UI not found at ${ui_dir}"
        return 1
    fi
}

# Open LCARS in browser
kb-browser() {
    local port="${1:-8080}"
    local ui_dir="${HOME}/dev-team/lcars-ui"

    if ! curl -s "http://localhost:$port/api/status" > /dev/null 2>&1; then
        echo "Starting LCARS server on port $port..."
        python3 "${ui_dir}/server.py" "$port" > /dev/null 2>&1 &
        sleep 2
    fi

    open "http://localhost:$port"
}

# ============================================================================
# LCARS Health Check Functions
# ============================================================================

# Check LCARS server health (status only, no restart)
lcars-status() {
    local script="${HOME}/dev-team/lcars-health-check.sh"
    if [[ -x "$script" ]]; then
        "$script" --status
    else
        echo "Error: Health check script not found or not executable: $script"
        return 1
    fi
}

# Check and auto-restart unhealthy LCARS servers
lcars-health() {
    local script="${HOME}/dev-team/lcars-health-check.sh"
    if [[ -x "$script" ]]; then
        "$script"
    else
        echo "Error: Health check script not found or not executable: $script"
        return 1
    fi
}

# Start LCARS health daemon (continuous monitoring)
lcars-daemon() {
    local script="${HOME}/dev-team/lcars-health-check.sh"
    if [[ -x "$script" ]]; then
        echo "Starting LCARS health daemon..."
        echo "Press Ctrl+C to stop"
        "$script" --daemon
    else
        echo "Error: Health check script not found or not executable: $script"
        return 1
    fi
}

# View recent health check logs
lcars-logs() {
    local lines="${1:-50}"
    local log_file="/tmp/lcars-health.log"
    if [[ -f "$log_file" ]]; then
        tail -n "$lines" "$log_file"
    else
        echo "No health check logs found at $log_file"
        return 1
    fi
}

# Force restart ALL LCARS servers (regardless of health)
# Detects running servers and restarts them with their original LCARS_TEAM config
lcars-restart() {
    local DEV_TEAM_DIR="$HOME/dev-team"
    local LCARS_UI_DIR="$DEV_TEAM_DIR/lcars-ui"

    echo "═══════════════════════════════════════════════════════"
    echo "LCARS Server Restart - ALL Servers"
    echo "═══════════════════════════════════════════════════════"

    # Step 1: Detect running servers and their configurations
    echo ""
    echo "Phase 1: Detecting running servers..."
    echo "───────────────────────────────────────────────────────"

    local -a SERVERS=()
    local server_info

    # Get all running server.py processes with their ports
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local port=$(echo "$line" | grep -oE 'server\.py [0-9]+' | awk '{print $2}')
            if [[ -n "$port" ]]; then
                # Query the running server to get its team config
                local server_status=$(curl -s --max-time 2 "http://localhost:$port/api/status" 2>/dev/null)
                if [[ -n "$server_status" ]]; then
                    local team=$(echo "$server_status" | jq -r '.team // empty' 2>/dev/null)
                    local session=$(echo "$server_status" | jq -r '.session_name // empty' 2>/dev/null)
                    if [[ -n "$team" ]]; then
                        echo "  Found: $team on port $port"
                        SERVERS+=("$port:$team:$session")
                    fi
                fi
            fi
        fi
    done < <(ps aux | grep "[s]erver.py")

    if [[ ${#SERVERS[@]} -eq 0 ]]; then
        echo "  No running LCARS servers found."
        echo "  Use team-specific startup scripts to start servers."
        return 0
    fi

    echo "  Detected ${#SERVERS[@]} server(s)"

    local stopped=0
    local started=0
    local failed=0

    # Step 2: Stop all detected servers
    echo ""
    echo "Phase 2: Stopping servers..."
    echo "───────────────────────────────────────────────────────"
    for config in "${SERVERS[@]}"; do
        IFS=':' read -r port team session <<< "$config"
        echo "  Stopping $team (port $port)..."
        pkill -f "server.py.*$port" 2>/dev/null
        ((stopped++))
    done

    echo "  Waiting for processes to terminate..."
    sleep 2
    echo "  ✓ Stopped $stopped server(s)"

    # Step 3: Start all servers with original configs
    echo ""
    echo "Phase 3: Starting servers..."
    echo "───────────────────────────────────────────────────────"
    for config in "${SERVERS[@]}"; do
        IFS=':' read -r port team session <<< "$config"

        echo "  Starting $team (port $port)..."
        cd "$LCARS_UI_DIR" && \
            LCARS_TEAM="$team" \
            LCARS_SESSION_NAME="$session" \
            nohup python3 server.py "$port" > /tmp/lcars-$team-$port.log 2>&1 &
    done

    # Step 4: Wait for servers to come up
    echo ""
    echo "Phase 4: Verifying servers..."
    echo "───────────────────────────────────────────────────────"
    sleep 2

    for config in "${SERVERS[@]}"; do
        IFS=':' read -r port team session <<< "$config"

        local attempts=0
        local healthy=false
        while [[ $attempts -lt 5 ]]; do
            if curl -s --max-time 2 "http://localhost:$port/api/status" > /dev/null 2>&1; then
                healthy=true
                break
            fi
            sleep 1
            ((attempts++))
        done

        if [[ "$healthy" == "true" ]]; then
            echo "  ✅ $team:$port - healthy"
            ((started++))
        else
            echo "  ❌ $team:$port - FAILED"
            ((failed++))
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "Summary: $started healthy, $failed failed"
    echo "═══════════════════════════════════════════════════════"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Restart LCARS kanban server for the current team
kb-restart() {
    local DEV_TEAM_DIR="$HOME/dev-team"
    local LCARS_UI_DIR="$DEV_TEAM_DIR/lcars-ui"

    # Port mapping: team -> local_port
    # Format matches lcars-health-check.sh LCARS_SERVERS array
    declare -A TEAM_PORTS=(
        ["ios"]="8260"
        ["android"]="8280"
        ["firebase"]="8240"
        ["academy"]="8203"
        ["dns"]="8180"
        ["freelance"]="8505"
        ["freelance-doublenode-starwords"]="8505"
        ["freelance-doublenode-workstats"]="8505"
        ["freelance-doublenode-appplanning"]="8505"
        ["command"]="8234"
        ["mainevent"]="8234"
    )

    # Detect current team from tmux session
    local context team terminal
    context=$(_kb_detect_context)

    if [[ "$context" == "ERROR:"* ]]; then
        echo "Error: Not running inside a tmux session"
        echo "kb-restart must be run from a team terminal"
        return 1
    fi

    team="${context%%:*}"
    local rest="${context#*:}"
    terminal="${rest%%:*}"

    # Get port for this team
    local local_port="${TEAM_PORTS[$team]}"

    if [[ -z "$local_port" ]]; then
        echo "Error: Unknown team '$team'"
        echo "Known teams: ${(k)TEAM_PORTS[@]}"
        return 1
    fi

    echo "═══════════════════════════════════════════════════════"
    echo "LCARS Kanban Server Restart"
    echo "═══════════════════════════════════════════════════════"
    echo "  Team:     $team"
    echo "  Terminal: $terminal"
    echo "  Port:     $local_port"
    echo "───────────────────────────────────────────────────────"

    # Step 1: Kill existing server process
    echo "Stopping existing server..."
    if pgrep -f "server.py.*$local_port" > /dev/null 2>&1; then
        pkill -f "server.py.*$local_port" 2>/dev/null
        sleep 2
        # Force kill if still running
        if pgrep -f "server.py.*$local_port" > /dev/null 2>&1; then
            pkill -9 -f "server.py.*$local_port" 2>/dev/null
            sleep 1
        fi
        echo "  ✓ Server stopped"
    else
        echo "  ⏭ No server running on port $local_port"
    fi

    # Step 2: Start new server
    echo "Starting new server..."
    local session_name="${team}-lcars"

    cd "$LCARS_UI_DIR" && \
        LCARS_TEAM="$team" \
        LCARS_SESSION_NAME="$session_name" \
        nohup python3 server.py "$local_port" > /tmp/lcars-$team-$local_port.log 2>&1 &

    # Step 3: Wait for server to come up
    echo "Waiting for server to become healthy..."
    local attempts=0
    local max_attempts=15
    while [[ $attempts -lt $max_attempts ]]; do
        if curl -s --max-time 2 "http://localhost:$local_port/api/status" > /dev/null 2>&1; then
            echo "  ✓ Server healthy on port $local_port"
            echo "───────────────────────────────────────────────────────"
            echo "✅ LCARS server restarted successfully!"
            echo "   Log: /tmp/lcars-$team-$local_port.log"
            echo "═══════════════════════════════════════════════════════"
            return 0
        fi
        sleep 1
        ((attempts++))
        echo "  ... attempt $attempts/$max_attempts"
    done

    echo "───────────────────────────────────────────────────────"
    echo "❌ Server failed to start"
    echo "   Check log: /tmp/lcars-$team-$local_port.log"
    echo "═══════════════════════════════════════════════════════"
    return 1
}

# ============================================================================
# Release Management Functions
# ============================================================================
# These functions integrate with the Release Tracking System (XACA-0023)
# Releases are stored in the kanban board file's .releases array (same as epics)
# NOTE: Release metadata lives in board JSON, but physical release manifests and
#       documentation are stored in team-specific repositories.

# Legacy variable - kept for backward compatibility
# Use _kb_get_releases_dir() for team-aware paths
RELEASES_DIR="${HOME}/dev-team/releases"

# Helper: Get team-specific releases directory path
# Returns the physical directory where release manifests/docs are stored
_kb_get_releases_dir() {
    local team="${1:-$LCARS_TEAM}"
    team=$(echo "$team" | tr '[:upper:]' '[:lower:]')

    case "$team" in
        academy)
            echo "${HOME}/dev-team/kanban/releases"
            ;;
        ios)
            echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/DEV/dev-team/kanban/releases"
            ;;
        android)
            echo "/Users/Shared/Development/Main Event/MainEventApp-Android/develop/dev-team/kanban/releases"
            ;;
        firebase)
            echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/develop/dev-team/kanban/releases"
            ;;
        *)
            # Default to legacy location for unknown teams
            echo "${HOME}/dev-team/releases"
            ;;
    esac
}

# Helper: Load releases from board file for current team
_kb_load_releases() {
    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ -f "$board_file" ]]; then
        # Return a structure compatible with the old format
        jq '{
            releases: (.releases // []),
            nextId: (.nextReleaseId // 1),
            releaseConfig: (.releaseConfig // {})
        }' "$board_file"
    else
        echo '{"releases":[], "nextId": 1}'
    fi
}

# Helper: Get release name by ID
_kb_release_name() {
    local release_id="$1"
    _kb_load_releases | jq -r --arg id "$release_id" '.releases[] | select(.id == $id) | .name // empty'
}

# Create a new release
# Usage: kb-release-create <name> [--type feature|bugfix|hotfix|maintenance] [--platforms ios,android,firebase] [--project name] [--target-date YYYY-MM-DD] [--short-title title]
kb-release-create() {
    local name=""
    local rel_type="feature"
    local platforms="ios,android"
    local project=""
    local target_date=""
    local short_title=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                rel_type="$2"
                shift 2
                ;;
            --platforms)
                platforms="$2"
                shift 2
                ;;
            --project)
                project="$2"
                shift 2
                ;;
            --target-date)
                target_date="$2"
                shift 2
                ;;
            --short-title)
                short_title="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: kb-release create <name> [options]"
                echo ""
                echo "Options:"
                echo "  --type <type>          Release type: feature, bugfix, hotfix, maintenance (default: feature)"
                echo "  --platforms <list>     Comma-separated platforms: ios,android,firebase (default: ios,android)"
                echo "  --project <name>       Project name (e.g., Starwords, MainEvent)"
                echo "  --target-date <date>   Target date (YYYY-MM-DD)"
                echo "  --short-title <title>  Short display name for LCARS UI"
                echo ""
                echo "Examples:"
                echo "  kb-release create 'Q1 2026 Feature Release'"
                echo "  kb-release create 'iOS Hotfix 2.8.1' --type hotfix --platforms ios"
                echo "  kb-release create 'March Update' --platforms ios,android,firebase --target-date 2026-03-15"
                return 0
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    echo "Error: Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        echo "Error: Release name is required"
        echo "Usage: kb-release create <name> [--type feature|bugfix|hotfix|maintenance] [--platforms ios,android]"
        return 1
    fi

    # Validate release type
    case "$rel_type" in
        feature|bugfix|hotfix|maintenance) ;;
        *)
            echo "Error: Invalid release type: $rel_type"
            echo "  Valid types: feature, bugfix, hotfix, maintenance"
            return 1
            ;;
    esac

    # Build JSON payload
    local json_payload
    json_payload=$(jq -n \
        --arg name "$name" \
        --arg type "$rel_type" \
        --arg platforms "$platforms" \
        --arg project "$project" \
        --arg targetDate "$target_date" \
        --arg shortTitle "$short_title" \
        '{
            name: $name,
            type: $type,
            platforms: ($platforms | split(",")),
            project: (if $project != "" then $project else null end),
            targetDate: (if $targetDate != "" then $targetDate else null end),
            shortTitle: (if $shortTitle != "" then $shortTitle else null end)
        }')

    # Call LCARS server to create the release
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "http://localhost:8080/api/releases" 2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "201" ]]; then
        local release_id release_name
        release_id=$(echo "$body" | jq -r '.id // empty')
        release_name=$(echo "$body" | jq -r '.name // empty')
        echo "✓ Created release: $release_name ($release_id)"
        echo "  Type: $rel_type"
        echo "  Platforms: $platforms"
        [[ -n "$target_date" ]] && echo "  Target: $target_date"
        [[ -n "$project" ]] && echo "  Project: $project"
        echo ""
        echo "  Next steps:"
        echo "    kb-release assign <item-id> $release_id [platform]"
        echo "    kb-release list"
    elif [[ "$http_code" == "000" ]]; then
        echo "Error: LCARS server is not running (http://localhost:8080)"
        echo "  Start it with: lcars-start (or check server status)"
        return 1
    else
        echo "Error: Failed to create release (HTTP $http_code)"
        [[ -n "$body" ]] && echo "  $body"
        return 1
    fi
}

# List all releases
kb-release-list() {
    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "No kanban board found for team '$team'"
        return 1
    fi

    echo "Releases for ${team}:"
    echo "═════════════════════════════════════════════════════════════"

    local releases=$(_kb_load_releases | jq -r '.releases[] | "\(.id)|\(.name)|\(.status)|\(.type)"')

    if [[ -z "$releases" ]]; then
        echo "  (no active releases)"
        return 0
    fi

    while IFS='|' read -r id name rel_status rtype; do
        local status_icon="●"
        case "$rel_status" in
            in_progress) status_icon="▶" ;;
            completed) status_icon="✓" ;;
            cancelled) status_icon="✗" ;;
            archived) status_icon="□" ;;
        esac

        printf "  %s %-20s %s [%s]\n" "$status_icon" "$id" "$name" "$rtype"
    done <<< "$releases"
}

# Assign a kanban item to a release
# Usage: kb-release-assign <item-id> <release-id> [platform]
kb-release-assign() {
    local item_id="$1"
    local release_id="$2"
    local platform="${3:-ios}"

    if [[ -z "$item_id" || -z "$release_id" ]]; then
        echo "Usage: kb-release-assign <item-id> <release-id> [platform]"
        echo "  item-id:    Kanban item ID (e.g., XIOS-0042)"
        echo "  release-id: Release ID (e.g., REL-2026-Q1-001)"
        echo "  platform:   ios, android, firebase (default: ios)"
        return 1
    fi

    # Use current team context
    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: Board not found for team: $team"
        return 1
    fi

    # Validate item belongs to current team
    local item_exists
    item_exists=$(jq -r --arg id "$item_id" '.backlog[]? | select(.id == $id) | .id' "$board_file" 2>/dev/null)
    if [[ -z "$item_exists" ]]; then
        echo "Error: Item '$item_id' not found in $team board"
        echo "  You can only assign releases to items in your current team's kanban."
        return 1
    fi

    # Verify release exists in current team's board
    local release_name=$(_kb_release_name "$release_id")
    if [[ -z "$release_name" ]]; then
        echo "Error: Release not found: $release_id"
        echo "  Available releases:"
        kb-release-list
        return 1
    fi

    # Update the kanban item with releaseAssignment
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local jq_filter='.backlog |= map(if .id == $id then . + {releaseAssignment: {releaseId: $rel, platform: $plat, assignedAt: $ts}} else . end) | .lastUpdated = $ts'

    _kb_jq_update "$board_file" "$jq_filter" \
        --arg id "$item_id" \
        --arg rel "$release_id" \
        --arg plat "$platform" \
        --arg ts "$timestamp"

    if [[ $? -eq 0 ]]; then
        echo "✓ Assigned $item_id to release: $release_name ($release_id)"
        echo "  Platform: $platform"
    else
        echo "Error: Failed to update item"
        return 1
    fi
}

# Unassign a kanban item from its release
# Usage: kb-release-unassign <item-id>
kb-release-unassign() {
    local item_id="$1"

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-release-unassign <item-id>"
        return 1
    fi

    # Use current team context
    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: Board not found for team: $team"
        return 1
    fi

    # Validate item belongs to current team
    local item_exists
    item_exists=$(jq -r --arg id "$item_id" '.backlog[]? | select(.id == $id) | .id' "$board_file" 2>/dev/null)
    if [[ -z "$item_exists" ]]; then
        echo "Error: Item '$item_id' not found in $team board"
        echo "  You can only manage releases for items in your current team's kanban."
        return 1
    fi

    # Remove releaseAssignment from the item
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local jq_filter='.backlog |= map(if .id == $id then del(.releaseAssignment) else . end) | .lastUpdated = $ts'

    _kb_jq_update "$board_file" "$jq_filter" \
        --arg id "$item_id" \
        --arg ts "$timestamp"

    if [[ $? -eq 0 ]]; then
        echo "✓ Removed release assignment from $item_id"
    else
        echo "Error: Failed to update item"
        return 1
    fi
}

# Show release assignment for an item
# Usage: kb-release-show <item-id>
kb-release-show() {
    local item_id="$1"

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-release-show <item-id>"
        return 1
    fi

    # Use current team context
    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: Board not found for team: $team"
        return 1
    fi

    # Validate item belongs to current team
    local item_exists
    item_exists=$(jq -r --arg id "$item_id" '.backlog[]? | select(.id == $id) | .id' "$board_file" 2>/dev/null)
    if [[ -z "$item_exists" ]]; then
        echo "Error: Item '$item_id' not found in $team board"
        echo "  You can only view releases for items in your current team's kanban."
        return 1
    fi

    local assignment=$(_kb_jq_read "$board_file" '.backlog[] | select(.id == $id) | .releaseAssignment // empty' --arg id "$item_id")

    if [[ -z "$assignment" || "$assignment" == "null" ]]; then
        echo "$item_id: Not assigned to any release"
        return 0
    fi

    local release_id=$(echo "$assignment" | jq -r '.releaseId')
    local platform=$(echo "$assignment" | jq -r '.platform')
    local assigned_at=$(echo "$assignment" | jq -r '.assignedAt')
    local release_name=$(_kb_release_name "$release_id")

    echo "$item_id Release Assignment:"
    echo "  Release: $release_name ($release_id)"
    echo "  Platform: $platform"
    echo "  Assigned: $assigned_at"
}

# Unified release command
# Usage: kb-release <subcommand> [args...]
kb-release() {
    local subcmd="$1"
    shift

    case "$subcmd" in
        create|new)
            kb-release-create "$@"
            ;;
        list|ls)
            kb-release-list "$@"
            ;;
        assign|add)
            kb-release-assign "$@"
            ;;
        unassign|remove|rm)
            kb-release-unassign "$@"
            ;;
        show|status)
            kb-release-show "$@"
            ;;
        help|--help|-h|"")
            echo "Release Management Commands:"
            echo "  kb-release create <name> [options]   Create a new release"
            echo "  kb-release list                      List all releases"
            echo "  kb-release assign <item> <rel> [plt] Assign item to release"
            echo "  kb-release unassign <item>           Remove release assignment"
            echo "  kb-release show <item>               Show item's release info"
            echo ""
            echo "Create options:"
            echo "  --type <type>        feature|bugfix|hotfix|maintenance (default: feature)"
            echo "  --platforms <list>   ios,android,firebase (default: ios,android)"
            echo "  --project <name>     Project name"
            echo "  --target-date <date> Target date (YYYY-MM-DD)"
            echo "  --short-title <str>  Short display name for LCARS UI"
            ;;
        *)
            echo "Unknown subcommand: $subcmd"
            echo "Run 'kb-release help' for usage"
            return 1
            ;;
    esac
}

# ============================================================================
# End Release Management Functions
# ============================================================================

# ============================================================================
# Epic System Functions
# ============================================================================
# Epics group multiple kanban items into high-level objectives
# Each team has their own Epics - no cross-team sharing
# Epic ID format: E{TEAMCODE}-{0000} (e.g., EACA-0001)
# ============================================================================

# Ensure board has epics support (adds epics array and nextEpicId if missing)
_kb_ensure_epics_support() {
    local board_file="$1"
    local timestamp
    timestamp=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" '
        if has("epics") then .
        else . + {"epics": [], "nextEpicId": 1}
        end |
        .lastUpdated = $ts
    ' --arg ts "$timestamp"
}

# Generate Epic ID (EPIC-0001 format, uses nextEpicId counter)
_kb_generate_epic_id() {
    local board_file="$1"
    local team="$2"

    # All epics use universal EPIC- prefix
    local prefix="EPIC"

    # Get current nextEpicId from board, default to 1
    local next_num
    next_num=$(_kb_jq_read "$board_file" '.nextEpicId // 1' -r)

    # Format as 4-digit number with leading zeros
    printf "%s-%04d" "$prefix" "$next_num"
}

# Increment the nextEpicId counter in the board
_kb_increment_epic_id() {
    local board_file="$1"
    local timestamp
    timestamp=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" \
       '.nextEpicId = ((.nextEpicId // 1) + 1) | .lastUpdated = $ts' \
       --arg ts "$timestamp"
}

# Find Epic index by ID
# Returns the array index or -1 if not found
_kb_find_epic_by_id() {
    local board_file="$1"
    local epic_id="$2"

    _kb_jq_read "$board_file" \
       '.epics // [] | to_entries | map(select(.value.id == $id)) | .[0].key // -1' \
       --arg id "$epic_id" -r
}

# Resolve Epic selector to index - supports both ID (EACA-0001) and numeric index
_kb_resolve_epic_selector() {
    local board_file="$1"
    local selector="$2"

    if [[ "$selector" =~ ^E[A-Z]{3}-[0-9]+$ ]]; then
        # It's an Epic ID - look it up
        _kb_find_epic_by_id "$board_file" "$selector"
    elif [[ "$selector" =~ ^[0-9]+$ ]]; then
        # It's a numeric index
        local count
        count=$(_kb_jq_read "$board_file" '.epics // [] | length' -r)
        if [[ "$selector" -lt "$count" ]]; then
            echo "$selector"
        else
            echo "-1"
        fi
    else
        echo "-1"
    fi
}

# Calculate Epic progress from items
_kb_epic_progress() {
    local board_file="$1"
    local epic_id="$2"

    _kb_jq_read "$board_file" '
        (.epics // [] | map(select(.id == $epic_id)) | .[0]) as $epic |
        if $epic then
            ($epic.itemIds // []) as $ids |
            [.backlog[] | select(.id as $id | $ids | index($id))] as $items |
            {
                totalItems: ($items | length),
                completedItems: ([$items[] | select(.status == "completed")] | length),
                cancelledItems: ([$items[] | select(.status == "cancelled")] | length),
                inProgressItems: ([$items[] | select(.status == "in_progress")] | length),
                blockedItems: ([$items[] | select(.status == "blocked")] | length),
                todoItems: ([$items[] | select(.status == "todo")] | length)
            } as $counts |
            $counts + {
                resolvedItems: ($counts.completedItems + $counts.cancelledItems),
                percentComplete: (if $counts.totalItems > 0 then ((($counts.completedItems + $counts.cancelledItems) * 100) / $counts.totalItems | floor) else 0 end)
            }
        else
            null
        end
    ' --arg epic_id "$epic_id"
}

# Main Epic command with subcommands
kb-epic() {
    _kb_ensure_jq || return 1

    local cmd="$1"
    shift 2>/dev/null

    local context team board_file
    context=$(_kb_detect_context)
    team="${context%%:*}"
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    # Ensure epics support exists
    _kb_ensure_epics_support "$board_file"

    case "$cmd" in
        create|add)
            # Parse optional flags first
            local short_title=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --short-title|-s)
                        short_title="$2"
                        shift 2
                        ;;
                    *)
                        break
                        ;;
                esac
            done

            local title="$1"
            local description="${2:-}"
            local priority="${3:-medium}"
            local category="${4:-}"

            if [[ -z "$title" ]]; then
                echo "Usage: kb-epic create [--short-title \"short\"] \"title\" [\"description\"] [priority] [category]"
                echo "  --short-title, -s : Optional abbreviated title for QUEUE tab display"
                echo "Priority: low | medium | high | critical"
                echo "Category: project | release | legal | milestone | (custom)"
                return 1
            fi

            # Normalize priority
            [[ "$priority" == "med" ]] && priority="medium"
            [[ "$priority" == "crit" ]] && priority="critical"

            local timestamp epic_id
            timestamp=$(_kb_get_timestamp)
            epic_id=$(_kb_generate_epic_id "$board_file" "$team")

            # Build the Epic object
            local jq_filter='.epics += [{
                "id": $id,
                "title": $title,
                "status": "planning",
                "priority": $priority,
                "itemIds": [],
                "addedAt": $timestamp,
                "updatedAt": $timestamp,
                "tags": [],
                "collapsed": false'
            local jq_args=(--arg id "$epic_id" --arg title "$title" --arg priority "$priority" --arg timestamp "$timestamp")

            if [[ -n "$short_title" ]]; then
                jq_filter+=', "shortTitle": $shortTitle'
                jq_args+=(--arg shortTitle "$short_title")
            fi

            if [[ -n "$description" ]]; then
                jq_filter+=', "description": $desc'
                jq_args+=(--arg desc "$description")
            fi

            if [[ -n "$category" ]]; then
                jq_filter+=', "category": $cat'
                jq_args+=(--arg cat "$category")
            fi

            jq_filter+='}] | .lastUpdated = $timestamp'

            _kb_jq_update "$board_file" "$jq_filter" "${jq_args[@]}"
            _kb_increment_epic_id "$board_file"

            echo "✓ Created Epic [$epic_id]: $title"
            [[ -n "$short_title" ]] && echo "  Short Title: $short_title"
            [[ -n "$category" ]] && echo "  Category: $category"
            [[ -n "$description" ]] && echo "  Description: ${description:0:50}..."
            ;;

        list|ls)
            local epic_count
            epic_count=$(_kb_jq_read "$board_file" '.epics // [] | length' -r)

            echo "Epics for ${team}: ($epic_count epics)"
            echo "═══════════════════════════════════════════════════"

            if [[ "$epic_count" -eq 0 ]]; then
                echo "  (no epics)"
            else
                _kb_jq_read "$board_file" '
                    .epics // [] | .[] |
                    "  [\(.id)] \(.status | ascii_upcase | .[0:4]) \(.title) (\(.itemIds | length) items)"
                ' -r
            fi
            echo "═══════════════════════════════════════════════════"
            ;;

        show|info)
            local selector="$1"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-epic show <epic-id>"
                return 1
            fi

            local index
            index=$(_kb_resolve_epic_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Epic not found: $selector"
                return 1
            fi

            # Get Epic details
            local epic_json
            epic_json=$(_kb_jq_read "$board_file" ".epics[$index]")

            local epic_id epic_title epic_status epic_priority epic_desc
            epic_id=$(_kb_jq_read "$board_file" ".epics[$index].id" -r)
            epic_title=$(_kb_jq_read "$board_file" ".epics[$index].title" -r)
            epic_status=$(_kb_jq_read "$board_file" ".epics[$index].status" -r)
            epic_priority=$(_kb_jq_read "$board_file" ".epics[$index].priority" -r)
            epic_desc=$(_kb_jq_read "$board_file" ".epics[$index].description // \"(no description)\"" -r)

            echo "╔═══════════════════════════════════════════════════════════╗"
            echo "║ EPIC: [$epic_id] $epic_title"
            echo "╠═══════════════════════════════════════════════════════════╣"
            echo "║ Status: ${(U)epic_status}    Priority: ${(U)epic_priority}"
            echo "║ $epic_desc"
            echo "╠═══════════════════════════════════════════════════════════╣"
            echo "║ ITEMS:"

            # List items in this Epic
            local item_count
            item_count=$(_kb_jq_read "$board_file" '.epics[$idx].itemIds // [] | length' --argjson idx "$index" -r)

            if [[ "$item_count" -eq 0 ]]; then
                echo "║   (no items assigned)"
            else
                _kb_jq_read "$board_file" '
                    (.epics[$idx].itemIds // []) as $ids |
                    .backlog[] | select(.id as $id | $ids | index($id)) |
                    "║   [\(.id)] \(.status | ascii_upcase | .[0:4]) \(.title)"
                ' --argjson idx "$index" -r
            fi

            echo "╠═══════════════════════════════════════════════════════════╣"

            # Calculate progress
            local progress
            progress=$(_kb_epic_progress "$board_file" "$epic_id")
            local total completed pct
            total=$(echo "$progress" | jq -r '.totalItems // 0')
            completed=$(echo "$progress" | jq -r '.completedItems // 0')
            pct=$(echo "$progress" | jq -r '.percentComplete // 0')

            echo "║ PROGRESS: $completed/$total items ($pct%)"
            echo "╚═══════════════════════════════════════════════════════════╝"
            ;;

        add-item|assign)
            local epic_selector="$1"
            local item_id="$2"

            if [[ -z "$epic_selector" ]] || [[ -z "$item_id" ]]; then
                echo "Usage: kb-epic add-item <epic-id> <item-id>"
                return 1
            fi

            local epic_index
            epic_index=$(_kb_resolve_epic_selector "$board_file" "$epic_selector")

            if [[ "$epic_index" == "-1" ]]; then
                echo "Error: Epic not found: $epic_selector"
                return 1
            fi

            # Verify item exists in backlog
            local item_index
            item_index=$(_kb_find_by_id "$board_file" "$item_id")

            if [[ "$item_index" == "-1" ]]; then
                echo "Error: Item not found: $item_id"
                echo "  (Item must exist in this team's backlog)"
                return 1
            fi

            # Check if item is already in this or another Epic
            local existing_epic
            existing_epic=$(_kb_jq_read "$board_file" ".backlog[$item_index].epicId // empty" -r)

            if [[ -n "$existing_epic" ]]; then
                echo "Error: Item $item_id is already in Epic $existing_epic"
                echo "  Remove it first with: kb-epic remove-item $existing_epic $item_id"
                return 1
            fi

            local timestamp epic_id
            timestamp=$(_kb_get_timestamp)
            epic_id=$(_kb_jq_read "$board_file" ".epics[$epic_index].id" -r)

            # Add item to Epic's itemIds and set epicId on item
            _kb_jq_update "$board_file" '
                .epics[$idx].itemIds += [$itemId] |
                .epics[$idx].itemIds |= unique |
                .epics[$idx].updatedAt = $ts |
                (.backlog[] | select(.id == $itemId)).epicId = $epicId |
                .lastUpdated = $ts
            ' \
            --argjson idx "$epic_index" \
            --arg itemId "$item_id" \
            --arg epicId "$epic_id" \
            --arg ts "$timestamp"

            # Update Epic status if needed
            _kb_update_epic_status "$board_file" "$epic_id"

            echo "✓ Added item [$item_id] to Epic [$epic_id]"
            ;;

        remove-item|unassign)
            local epic_selector="$1"
            local item_id="$2"

            if [[ -z "$epic_selector" ]] || [[ -z "$item_id" ]]; then
                echo "Usage: kb-epic remove-item <epic-id> <item-id>"
                return 1
            fi

            local epic_index
            epic_index=$(_kb_resolve_epic_selector "$board_file" "$epic_selector")

            if [[ "$epic_index" == "-1" ]]; then
                echo "Error: Epic not found: $epic_selector"
                return 1
            fi

            local timestamp epic_id
            timestamp=$(_kb_get_timestamp)
            epic_id=$(_kb_jq_read "$board_file" ".epics[$epic_index].id" -r)

            # Remove item from Epic's itemIds and clear epicId on item
            _kb_jq_update "$board_file" '
                .epics[$idx].itemIds -= [$itemId] |
                .epics[$idx].updatedAt = $ts |
                (.backlog[] | select(.id == $itemId)) |= del(.epicId) |
                .lastUpdated = $ts
            ' \
            --argjson idx "$epic_index" \
            --arg itemId "$item_id" \
            --arg ts "$timestamp"

            # Update Epic status
            _kb_update_epic_status "$board_file" "$epic_id"

            echo "✓ Removed item [$item_id] from Epic [$epic_id]"
            ;;

        update|edit)
            local epic_selector="$1"
            local field="$2"
            local value="$3"

            if [[ -z "$epic_selector" ]] || [[ -z "$field" ]]; then
                echo "Usage: kb-epic update <epic-id> <field> <value>"
                echo "Fields: title | shortTitle | description | priority | status | category | dueDate"
                echo "Status: planning | active | completed | on_hold | cancelled"
                return 1
            fi

            local epic_index
            epic_index=$(_kb_resolve_epic_selector "$board_file" "$epic_selector")

            if [[ "$epic_index" == "-1" ]]; then
                echo "Error: Epic not found: $epic_selector"
                return 1
            fi

            local timestamp epic_id
            timestamp=$(_kb_get_timestamp)
            epic_id=$(_kb_jq_read "$board_file" ".epics[$epic_index].id" -r)

            case "$field" in
                title|shortTitle|description|priority|status|category|dueDate|owner)
                    _kb_jq_update "$board_file" "
                        .epics[$epic_index].$field = \$value |
                        .epics[$epic_index].updatedAt = \$ts |
                        .lastUpdated = \$ts
                    " --arg value "$value" --arg ts "$timestamp"
                    echo "✓ Updated [$epic_id] $field = $value"
                    ;;
                *)
                    echo "Error: Unknown field '$field'"
                    echo "Valid fields: title | shortTitle | description | priority | status | category | dueDate | owner"
                    return 1
                    ;;
            esac
            ;;

        delete|rm)
            local epic_selector="$1"

            if [[ -z "$epic_selector" ]]; then
                echo "Usage: kb-epic delete <epic-id>"
                return 1
            fi

            local epic_index
            epic_index=$(_kb_resolve_epic_selector "$board_file" "$epic_selector")

            if [[ "$epic_index" == "-1" ]]; then
                echo "Error: Epic not found: $epic_selector"
                return 1
            fi

            local epic_id epic_title
            epic_id=$(_kb_jq_read "$board_file" ".epics[$epic_index].id" -r)
            epic_title=$(_kb_jq_read "$board_file" ".epics[$epic_index].title" -r)

            local timestamp
            timestamp=$(_kb_get_timestamp)

            # Remove Epic and clear epicId from all its items
            _kb_jq_update "$board_file" '
                (.epics[$idx].itemIds // []) as $ids |
                del(.epics[$idx]) |
                (.backlog[] | select(.id as $id | $ids | index($id))) |= del(.epicId) |
                .lastUpdated = $ts
            ' \
            --argjson idx "$epic_index" \
            --arg ts "$timestamp"

            echo "✓ Deleted Epic [$epic_id]: $epic_title"
            echo "  (Items unassigned from Epic but not deleted)"
            ;;

        status|progress)
            local epic_selector="$1"

            if [[ -z "$epic_selector" ]]; then
                echo "Usage: kb-epic status <epic-id>"
                return 1
            fi

            local epic_index
            epic_index=$(_kb_resolve_epic_selector "$board_file" "$epic_selector")

            if [[ "$epic_index" == "-1" ]]; then
                echo "Error: Epic not found: $epic_selector"
                return 1
            fi

            local epic_id
            epic_id=$(_kb_jq_read "$board_file" ".epics[$epic_index].id" -r)

            local progress
            progress=$(_kb_epic_progress "$board_file" "$epic_id")

            echo "Epic Progress: [$epic_id]"
            echo "─────────────────────────────────────"
            echo "$progress" | jq -r '
                "  Total Items:       \(.totalItems)",
                "  Completed:         \(.completedItems)",
                "  In Progress:       \(.inProgressItems)",
                "  Blocked:           \(.blockedItems)",
                "  Todo:              \(.todoItems)",
                "  ─────────────────────────────────────",
                "  Progress:          \(.percentComplete)%"
            '
            ;;

        help|--help|-h|"")
            echo "Epic Management Commands:"
            echo "  kb-epic create [--short-title \"short\"] \"title\" [\"desc\"] [priority] [category]"
            echo "  kb-epic list                           List all Epics"
            echo "  kb-epic show <epic-id>                 Show Epic details"
            echo "  kb-epic add-item <epic-id> <item-id>   Add item to Epic"
            echo "  kb-epic remove-item <epic-id> <item-id> Remove item from Epic"
            echo "  kb-epic update <epic-id> <field> <val> Update Epic field"
            echo "  kb-epic delete <epic-id>               Delete Epic"
            echo "  kb-epic status <epic-id>               Show Epic progress"
            echo ""
            echo "Epic ID Format: E<TEAM>-#### (e.g., EACA-0001)"
            echo "Status: planning | active | completed | on_hold | cancelled"
            ;;
        *)
            echo "Unknown subcommand: $cmd"
            echo "Run 'kb-epic help' for usage"
            return 1
            ;;
    esac
}

# Update Epic status based on item statuses
_kb_update_epic_status() {
    local board_file="$1"
    local epic_id="$2"

    local progress
    progress=$(_kb_epic_progress "$board_file" "$epic_id")

    if [[ -z "$progress" ]] || [[ "$progress" == "null" ]]; then
        return 0
    fi

    local total completed cancelled resolved in_progress
    total=$(echo "$progress" | jq -r '.totalItems // 0')
    completed=$(echo "$progress" | jq -r '.completedItems // 0')
    cancelled=$(echo "$progress" | jq -r '.cancelledItems // 0')
    in_progress=$(echo "$progress" | jq -r '.inProgressItems // 0')
    resolved=$((completed + cancelled))

    local new_status
    if [[ "$total" -eq 0 ]]; then
        new_status="planning"
    elif [[ "$resolved" -eq "$total" ]]; then
        new_status="completed"
    elif [[ "$in_progress" -gt 0 ]] || [[ "$completed" -gt 0 ]]; then
        new_status="active"
    else
        new_status="planning"
    fi

    local timestamp
    timestamp=$(_kb_get_timestamp)

    # Get current status - only auto-update if not manually set to on_hold/cancelled
    local current_status
    current_status=$(_kb_jq_read "$board_file" '
        (.epics // [] | map(select(.id == $id)) | .[0].status) // "planning"
    ' --arg id "$epic_id" -r)

    # Don't override manual statuses
    if [[ "$current_status" == "on_hold" ]] || [[ "$current_status" == "cancelled" ]]; then
        return 0
    fi

    _kb_jq_update "$board_file" '
        (.epics[] | select(.id == $id)).status = $status |
        (.epics[] | select(.id == $id)).updatedAt = $ts |
        .lastUpdated = $ts
    ' --arg id "$epic_id" --arg status "$new_status" --arg ts "$timestamp"
}

# ============================================================================
# End Epic System Functions
# ============================================================================

# ============================================================================
# Fleet Monitor Integration
# ============================================================================

# Initialize Fleet Monitor URL from board config
# Reads fleetMonitorUrl from board JSON and exports as FLEET_MONITOR_API
_kb_init_fleet_monitor() {
    # Detect current team from session context
    if [ -z "$SESSION_TYPE" ]; then
        return  # Not in a team session, skip
    fi

    # Get board file for current team
    local board_file=$(_kb_get_board_file "$SESSION_TYPE")

    if [ ! -f "$board_file" ]; then
        return  # Board file doesn't exist, skip
    fi

    # Read fleetMonitorUrl from board JSON (default to production Fleet Monitor)
    local fleet_url
    fleet_url=$(jq -r '.fleetMonitorUrl // "https://fleet-monitor.fly.dev"' "$board_file" 2>/dev/null)

    # Export as FLEET_MONITOR_API for fleet-reporter.sh
    export FLEET_MONITOR_API="${fleet_url}/api/status"
}

# Register team metadata with Fleet Monitor
# POSTs team board metadata to the Fleet Monitor's /api/team-register endpoint
# Runs in background to avoid blocking terminal startup
_kb_register_team() {
    # Detect current team from session context
    if [ -z "$SESSION_TYPE" ]; then
        return  # Not in a team session, skip
    fi

    # Get board file for current team
    local board_file=$(_kb_get_board_file "$SESSION_TYPE")

    if [ ! -f "$board_file" ]; then
        return  # Board file doesn't exist, skip
    fi

    # Read fleetMonitorUrl from board JSON (default to production Fleet Monitor)
    local fleet_url
    fleet_url=$(jq -r '.fleetMonitorUrl // "https://fleet-monitor.fly.dev"' "$board_file" 2>/dev/null)

    if [ -z "$fleet_url" ]; then
        return  # No fleet monitor URL configured
    fi

    # Extract team metadata (exclude workflow columns like backlog, ready, inProgress, etc.)
    local team_metadata
    team_metadata=$(jq '{team, teamName, subtitle, ship, series, organization, orgColor, kanbanDir, fleetMonitorUrl, terminals}' "$board_file" 2>/dev/null)

    if [ -z "$team_metadata" ]; then
        return  # Failed to extract metadata
    fi

    # POST team metadata to Fleet Monitor (background, silent, with timeout)
    # Don't block if fleet monitor is down
    # NOTE: "|| true" ensures exit 0 so zsh doesn't print noisy
    # "[N] + exit 7" background job notifications when Fleet Monitor is offline.
    # NOTE: "disown" detaches the job from zsh's job table so it won't print
    # "[N] + done" notifications when the background curl completes.
    (
        curl -s -m 5 -X POST \
            -H "Content-Type: application/json" \
            -d "$team_metadata" \
            "${fleet_url}/api/team-register" \
            >/dev/null 2>&1 || true
    ) &
    disown 2>/dev/null
}

# User-facing command to manually trigger team registration
kb-register() {
    _kb_register_team
    echo "Team registration sent to Fleet Monitor"
}

# Auto-initialize on source (when SESSION_TYPE is set)
if [ -n "$SESSION_TYPE" ]; then
    _kb_init_fleet_monitor
    _kb_register_team
fi

# ============================================================================
# End Fleet Monitor Integration
# ============================================================================

# Show help
kb-help() {
    echo "Kanban Board Commands (Window-Based Tracking)"
    echo "═════════════════════════════════════════════════════════════"
    echo ""
    echo "Status Updates:"
    echo "  kb-plan \"task\"         Start planning a task"
    echo "  kb-code                Move to coding"
    echo "  kb-test                Move to testing"
    echo "  kb-commit              Move to commit"
    echo "  kb-pr                  Move to PR review"
    echo "  kb-pause \"reason\"      Pause task with reason (external wait)"
    echo "  kb-resume              Resume and return to previous status"
    echo "  kb-block \"reason\"      (deprecated alias for kb-pause)"
    echo "  kb-unblock             (deprecated alias for kb-resume)"
    echo "  kb-done [item-id]      Complete and remove from board"
    echo "  kb-cancel [item-id] [--reason \"text\"]   Cancel item/subitem without completing"
    echo "  kb-clear               Remove window from board"
    echo ""
    echo "Task Management:"
    echo "  kb-task \"desc\"         Set task description"
    echo "  kb-status <status>     Set status directly"
    echo "  kb-stop-working        Clear working-on item (without completing)"
    echo ""
    echo "Backlog Items (use ID like XFRE-0001 or numeric index):"
    echo "  kb-backlog add \"task\" [priority] [\"desc\"] [jira]  Add item"
    echo "  kb-backlog list                         List all items"
    echo "  kb-backlog change <id> [\"text\"] [pri]   Update title/priority"
    echo "  kb-backlog remove <id>                  Remove item"
    echo "  kb-backlog toggle <id>                  Toggle collapsed state"
    echo "  kb-backlog unpick <id>                  Clear activelyWorking flag"
    echo "  kb-backlog desc <id> \"text\"             Set description"
    echo "  kb-backlog jira <id> [ticket|-]         Set/clear JIRA link"
    echo "  kb-backlog github <id> [issue|-]        Set/clear GitHub issue"
    echo "  kb-backlog tag <id> [add|rm|clear] ...  Manage tags"
    echo "  kb-backlog priority <id> [pri|-]        Set/view/reset priority"
    echo "  kb-backlog due <id> [YYYY-MM-DD|-]      Set/clear due date"
    echo "  kb-pick <id>                            Mark item as active (simple)"
    echo "  kb-run <id>                             Launch cc (auto-creates worktree)"
    echo "  kb-work <id>                            Launch cc (NO worktree, use current dir)"
    echo ""
    echo "Worktree Integration:"
    echo "  kb-link-worktree <id>                   Link current worktree to item"
    echo "  kb-unlink-worktree <id>                 Remove worktree link from item"
    echo ""
    echo "Subitems:"
    echo "  kb-backlog sub add <id> \"title\" [jira]  Add subitem to parent"
    echo "  kb-backlog sub list <id>                List subitems of parent"
    echo "  kb-backlog sub remove <id> <idx>        Remove subitem"
    echo "  kb-backlog sub start <subitem-id>       Start working on subitem"
    echo "  kb-backlog sub done <subitem-id>        Mark subitem completed"
    echo "  kb-backlog sub cancel <subitem-id> [--reason \"text\"]   Cancel subitem"
    echo "  kb-backlog sub stop <id> <idx>          Stop working on subitem"
    echo "  kb-backlog sub todo <id> <idx>          Mark subitem as todo"
    echo "  kb-backlog sub jira <id> <idx> [ticket] Set subitem JIRA"
    echo "  kb-backlog sub github <id> <idx> [issue] Set subitem GitHub"
    echo "  kb-backlog sub tag <id> <idx> ...       Manage subitem tags"
    echo ""
    echo "Release Management:"
    echo "  kb-release create <name> [options]      Create a new release"
    echo "  kb-release list                         List all active releases"
    echo "  kb-release assign <item> <rel> [plt]    Assign item to release"
    echo "  kb-release unassign <item>              Remove release assignment"
    echo "  kb-release show <item>                  Show item's release info"
    echo ""
    echo "Epic Management:"
    echo "  kb-epic create [-s \"short\"] \"title\" [desc] [pri]  Create new Epic"
    echo "  kb-epic list                            List all Epics"
    echo "  kb-epic show <epic-id>                  Show Epic with items"
    echo "  kb-epic add-item <epic-id> <item-id>    Add item to Epic"
    echo "  kb-epic remove-item <epic-id> <item-id> Remove item from Epic"
    echo "  kb-epic update <epic-id> <field> <val>  Update Epic field"
    echo "  kb-epic delete <epic-id>                Delete Epic"
    echo "  kb-epic status <epic-id>                Show Epic progress"
    echo ""
    echo "Display:"
    echo "  kb-my-status           Show this window's status"
    echo "  kb-show                Display full kanban board"
    echo "  kb-watch [sec]         Auto-refresh display (default 5s)"
    echo "  kb-ui                  Open LCARS web UI in browser"
    echo "  kb-browser [port]      Open LCARS at specific port"
    echo ""
    echo "Health Monitoring:"
    echo "  lcars-status           Check all LCARS servers (no restart)"
    echo "  lcars-health           Check and auto-restart unhealthy servers"
    echo "  lcars-daemon           Start continuous health monitoring"
    echo "  lcars-logs [n]         View last n lines of health log (default 50)"
    echo ""
    echo "ID Format: X<TEAM>-#### (e.g., XFRE-0001, XIOS-0042)"
    echo "Subitem IDs: <parent>-### (e.g., XFRE-0001-001)"
    echo "Epic IDs: E<TEAM>-#### (e.g., EACA-0001, EIOS-0003)"
    echo "Priority: low | med | high | crit | blocked"
    echo ""
    echo "═════════════════════════════════════════════════════════════"
}
