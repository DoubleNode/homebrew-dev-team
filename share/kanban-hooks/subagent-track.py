#!/usr/bin/env python3
"""
Subagent Tracker Hook for Claude Code

Tracks Task tool subagent lifecycle (start/stop) for LCARS agent panel display.
Writes active subagent list to /tmp/lcars-subagents-{session}-w{window}.json
so agent-panel-display.sh can render crew avatars.

Actions:
  start   - PreToolUse: add subagent_type to tracking file
  stop    - PostToolUse: remove subagent_type from tracking file
  cleanup - Stop event: clear tracking file for this session/window
"""

import json
import os
import sys
import subprocess
import fcntl
import glob


def get_tmux_context():
    """Get tmux session name and window index."""
    try:
        session = subprocess.run(
            ["tmux", "display-message", "-p", "#S"],
            capture_output=True, text=True, timeout=2
        )
        window_idx = subprocess.run(
            ["tmux", "display-message", "-p", "#I"],
            capture_output=True, text=True, timeout=2
        )
        if session.returncode == 0 and window_idx.returncode == 0:
            return session.stdout.strip(), window_idx.stdout.strip()
    except Exception:
        pass
    return None, None


def tracking_file_path(session_name, window_index):
    """Build tracking file path for this session/window."""
    return f"/tmp/lcars-subagents-{session_name}-w{window_index}.json"


def locked_update(filepath, update_fn):
    """Atomic read-modify-write with file locking."""
    lockfile = filepath + ".lock"
    with open(lockfile, "w") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        try:
            # Read current state
            try:
                with open(filepath, "r") as f:
                    data = json.load(f)
                if not isinstance(data, list):
                    data = []
            except (FileNotFoundError, json.JSONDecodeError):
                data = []

            # Apply update
            data = update_fn(data)

            # Write atomically
            tmp = filepath + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.rename(tmp, filepath)
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def add_agent(filepath, agent_type):
    """Append agent type to tracking list."""
    def updater(agents):
        agents.append(agent_type)
        return agents
    locked_update(filepath, updater)


def remove_agent(filepath, agent_type):
    """Remove first occurrence of agent type from tracking list."""
    def updater(agents):
        try:
            agents.remove(agent_type)
        except ValueError:
            pass  # Not found, already removed
        return agents
    locked_update(filepath, updater)


def cleanup_session(session_name):
    """Remove all tracking files for this session (all windows)."""
    pattern = f"/tmp/lcars-subagents-{session_name}-w*.json"
    for f in glob.glob(pattern):
        try:
            os.remove(f)
        except OSError:
            pass
    # Also clean lock files
    for f in glob.glob(pattern + ".lock"):
        try:
            os.remove(f)
        except OSError:
            pass


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "unknown"

    # Read hook input from stdin
    try:
        input_data = json.load(sys.stdin)
    except Exception:
        input_data = {}

    session_name, window_index = get_tmux_context()
    if not session_name or not window_index:
        # Not in tmux - nothing to track
        print(json.dumps({}))
        sys.exit(0)

    if action == "start":
        agent_type = input_data.get("tool_input", {}).get("subagent_type", "")
        if agent_type:
            filepath = tracking_file_path(session_name, window_index)
            add_agent(filepath, agent_type)

    elif action == "stop":
        agent_type = input_data.get("tool_input", {}).get("subagent_type", "")
        if agent_type:
            filepath = tracking_file_path(session_name, window_index)
            remove_agent(filepath, agent_type)

    elif action == "cleanup":
        cleanup_session(session_name)

    # Return valid JSON (hooks requirement)
    print(json.dumps({}))
    sys.exit(0)


if __name__ == "__main__":
    main()
