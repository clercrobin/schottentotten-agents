#!/bin/bash
# ============================================================
# backcountryskitrace — Project config for ai-agent-factory
# ============================================================

# The target project agents work on (force-set — overrides base config)
export TARGET_PROJECT="$HOME/Workspace/backcountryskitrace"

# GitHub — agents communicate via Discussions on a dedicated -agents repo
export GITHUB_OWNER="clercrobin"
export GITHUB_REPO="backcountryskitrace-agents"

# Claude Code settings
export CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
export CLAUDE_MAX_BUDGET="${CLAUDE_MAX_BUDGET:-5.00}"
export CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-3600}"

# Agent polling / parallelism
export POLL_INTERVAL="${POLL_INTERVAL:-30}"
export MAX_PARALLEL_SESSIONS="${MAX_PARALLEL_SESSIONS:-1}"
