#!/bin/bash
# ============================================================
# Robustness utilities — retry, timeout, health checks
# ============================================================

_ROBUST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ROBUST_LIB_DIR/state.sh"

# ────────────────────────────────────────────
# Load a prompt template with project override support
# Checks: projects/<name>/prompts/<name>.md → prompts/<name>.md
# Usage: load_prompt "cto-scan"
# Returns: raw template content (with {{PLACEHOLDERS}})
# ────────────────────────────────────────────
load_prompt() {
    local name="$1"
    local base_dir="${BASE_DIR:-$(cd "$_ROBUST_LIB_DIR/.." && pwd)}"
    local project_prompt="${PROJECT_DIR:+$PROJECT_DIR/prompts/${name}.md}"
    local base_prompt="$base_dir/prompts/${name}.md"
    local content=""

    if [ -n "$project_prompt" ] && [ -f "$project_prompt" ]; then
        content=$(cat "$project_prompt")
    elif [ -f "$base_prompt" ]; then
        content=$(cat "$base_prompt")
    else
        echo "ERROR: prompt template '$name' not found" >&2
        return 1
    fi

    # Auto-inject project-specific rules and style (self-improvement output)
    if [ -n "${PROJECT_DIR:-}" ]; then
        local rules_file="$PROJECT_DIR/rules.md"
        local style_file="$PROJECT_DIR/style.md"

        local project_context=""
        if [ -f "$rules_file" ]; then
            project_context="$project_context

## Project Rules (auto-learned — MUST follow)
$(cat "$rules_file")"
        fi
        if [ -f "$style_file" ]; then
            project_context="$project_context

## Project Style (auto-learned — follow conventions)
$(cat "$style_file")"
        fi

        if [ -n "$project_context" ]; then
            content="$content
---
$project_context"
        fi
    fi

    # Auto-inject environment context when ENV_NAME is set
    if [ -n "${ENV_NAME:-}" ]; then
        local env_context_file="$base_dir/prompts/env-context.md"
        if [ -f "$env_context_file" ]; then
            content="$content

---
$(cat "$env_context_file")

**Current environment:** ${ENV_NAME}
**Deploy branch:** ${DEPLOY_BRANCH:-main}
**Deploy URL:** ${DEPLOY_URL:-N/A}
**TF directory:** ${TF_DIR:-infra/terraform}
**S3 bucket:** ${S3_BUCKET:-N/A}
**IAM role:** ${IAM_ROLE_ARN:-N/A}"
        fi
    fi

    echo "$content"
}

# ────────────────────────────────────────────
# Render a prompt template by replacing {{PLACEHOLDERS}}
# Usage: render_prompt "template content" VAR1 "value1" VAR2 "value2"
# Replaces {{VAR1}} with value1, {{VAR2}} with value2, etc.
# ────────────────────────────────────────────
render_prompt() {
    local template="$1"
    shift

    while [ $# -ge 2 ]; do
        local key="$1"
        local value="$2"
        shift 2
        # Use awk for safe replacement (no sed delimiter issues)
        template=$(echo "$template" | KEY="$key" VALUE="$value" awk '{
            gsub("{{" ENVIRON["KEY"] "}}", ENVIRON["VALUE"])
            print
        }')
    done

    echo "$template"
}

# ────────────────────────────────────────────
# Run a command with retries + exponential backoff
# Usage: with_retry <max_retries> <command...>
# ────────────────────────────────────────────
with_retry() {
    local max_retries="$1"
    shift
    local attempt=0
    local backoff=5

    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$max_retries" ]; then
            echo "[retry] Attempt $attempt/$max_retries failed. Waiting ${backoff}s..." >&2
            sleep "$backoff"
            backoff=$(( backoff * 2 > 120 ? 120 : backoff * 2 ))
        fi
    done
    echo "[retry] All $max_retries attempts failed" >&2
    return 1
}

# ────────────────────────────────────────────
# Run a command with a timeout (macOS-safe)
# Usage: with_timeout <seconds> <command...>
#
# On macOS there's no coreutils `timeout` by default.
# We use perl as a portable fallback.
# ────────────────────────────────────────────
with_timeout() {
    local timeout_secs="$1"
    shift

    if command -v gtimeout &>/dev/null; then
        gtimeout --signal=TERM --kill-after=30 "$timeout_secs" "$@"
        return $?
    elif command -v timeout &>/dev/null; then
        timeout --signal=TERM --kill-after=30 "$timeout_secs" "$@"
        return $?
    else
        # Perl-based timeout — no zombie leak, proper cleanup
        perl -e '
            use POSIX ":sys_wait_h";
            $SIG{ALRM} = sub {
                kill "TERM", $pid;
                sleep 5;
                kill "KILL", $pid if kill(0, $pid);
                exit 124;
            };
            $pid = fork();
            if ($pid == 0) { exec @ARGV; exit 127; }
            alarm '"$timeout_secs"';
            waitpid($pid, 0);
            exit ($? >> 8);
        ' -- "$@"
        return $?
    fi
}

# ────────────────────────────────────────────
# Safe Claude invocation
#
# 1. Acquires a slot from the pool (N parallel sessions)
# 2. Timeout (default 5 min, SHORTER than lock stale time)
# 3. Retries on rate limit
# 4. Waits for process exit before releasing slot
# 5. Captures stderr
# ────────────────────────────────────────────
safe_claude() {
    local agent_name="$1"
    local prompt="$2"
    shift 2
    local extra_args=("$@")

    # Timeout MUST be shorter than lock stale time (900s)
    local timeout_secs="${CLAUDE_TIMEOUT:-300}"
    local error_file
    error_file=$(mktemp)

    local target_dir="${TARGET_PROJECT:-.}"
    local model="${CLAUDE_MODEL:-sonnet}"
    local budget="${CLAUDE_MAX_BUDGET:-1.00}"
    local pool_size="${MAX_PARALLEL_SESSIONS:-1}"
    local base_dir="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    # ── Agent definition support ──
    # If an agent definition exists in .claude/agents/<name>.md, use it:
    #   - System prompt from the agent definition (after frontmatter)
    #   - allowedTools from frontmatter
    #   - --add-dir for cross-repo access (factory + target)
    # Otherwise fall back to passing everything via -p (legacy mode)
    local agent_def_file="$base_dir/.claude/agents/${agent_name}.md"
    local agent_system_prompt=""
    local agent_allowed_tools=""
    local use_agent_mode=false

    if [ -f "$agent_def_file" ]; then
        # Extract body (after second ---) as system prompt
        agent_system_prompt=$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$agent_def_file")
        # Extract allowedTools from frontmatter
        agent_allowed_tools=$(awk '/^---$/,/^---$/' "$agent_def_file" | grep '^allowedTools:' | sed 's/^allowedTools: *//')
        if [ -n "$agent_system_prompt" ]; then
            use_agent_mode=true
        fi
    fi

    echo "  [safe_claude] agent=$agent_name model=$model timeout=${timeout_secs}s budget=\$${budget} slots=$pool_size" >&2
    echo "  [safe_claude] target_dir=$target_dir" >&2
    echo "  [safe_claude] agent_mode=$use_agent_mode" >&2
    echo "  [safe_claude] extra_args: ${extra_args[*]:-<none>}" >&2
    echo "  [safe_claude] prompt (first 120 chars): ${prompt:0:120}..." >&2

    # Verify target dir exists
    if [ ! -d "$target_dir" ]; then
        echo "  [safe_claude] ERROR: target_dir does not exist: $target_dir" >&2
        log_event "$agent_name" "ERROR" "target_dir missing: $target_dir"
        rm -f "$error_file"
        return 1
    fi

    # Wait for a pool slot — up to 5 min
    local wait_count=0
    local acquired_slot=""
    # Lock stale time must exceed timeout (with margin for retries)
    local lock_stale=$(( timeout_secs * 2 + 300 ))
    while true; do
        acquired_slot=$(acquire_pool_slot "claude" "$pool_size" "$lock_stale" 2>/dev/null) && break
        wait_count=$((wait_count + 1))
        echo "  [safe_claude] All $pool_size slots busy, waiting... attempt $wait_count/30" >&2
        if [ "$wait_count" -gt 30 ]; then
            echo "  [safe_claude] ERROR: lock timeout after 5min (all $pool_size slots busy)" >&2
            log_event "$agent_name" "LOCK_TIMEOUT" "Could not acquire claude slot after 5min ($pool_size slots)"
            rm -f "$error_file"
            return 1
        fi
        sleep 10
    done

    echo "  [safe_claude] Acquired slot $acquired_slot/$pool_size" >&2
    log_event "$agent_name" "CLAUDE_START" "Starting session (slot $acquired_slot)"

    local result=""
    local exit_code=1

    # Build claude command args based on mode
    local claude_args=()
    claude_args+=(-p "$prompt")
    claude_args+=(--model "$model")
    claude_args+=(--max-budget-usd "$budget")

    if [ "$use_agent_mode" = true ]; then
        # Agent mode: system prompt from definition, --add-dir for factory access
        claude_args+=(--append-system-prompt "$agent_system_prompt")
        claude_args+=(--add-dir "$base_dir")
        # Use allowedTools from agent definition if not already in extra_args
        if [ -n "$agent_allowed_tools" ]; then
            local has_tools=false
            if [ ${#extra_args[@]} -gt 0 ]; then
                for arg in "${extra_args[@]}"; do
                    case "$arg" in --allowedTools|--allowed-tools) has_tools=true ;; esac
                done
            fi
            if [ "$has_tools" = false ]; then
                claude_args+=(--allowedTools "$agent_allowed_tools")
            fi
        fi
    fi

    [ ${#extra_args[@]} -gt 0 ] && claude_args+=("${extra_args[@]}")

    for attempt in 1 2; do
        echo "  [safe_claude] Attempt $attempt/2 — invoking claude..." >&2
        local start_time
        start_time=$(date +%s)

        result=$(cd "$target_dir" && with_timeout "$timeout_secs" \
            claude "${claude_args[@]}" \
            2>"$error_file")
        exit_code=$?

        local end_time elapsed
        end_time=$(date +%s)
        elapsed=$(( end_time - start_time ))

        if [ "$exit_code" -eq 0 ]; then
            local result_len=${#result}
            echo "  [safe_claude] Attempt $attempt succeeded in ${elapsed}s (output: ${result_len} chars)" >&2
            break
        fi

        local error_msg
        error_msg=$(cat "$error_file" 2>/dev/null)

        echo "  [safe_claude] Attempt $attempt failed (exit=$exit_code, ${elapsed}s)" >&2
        if [ -n "$error_msg" ]; then
            echo "  [safe_claude] stderr: ${error_msg:0:300}" >&2
        fi

        if echo "$error_msg" | grep -qi "rate.limit\|429\|too many"; then
            echo "  [safe_claude] Rate limited — waiting 120s" >&2
            log_event "$agent_name" "RATE_LIMITED" "Waiting 120s"
            sleep 120
        elif [ "$exit_code" -eq 124 ]; then
            echo "  [safe_claude] Timed out after ${timeout_secs}s" >&2
            log_event "$agent_name" "TIMEOUT" "Timed out after ${timeout_secs}s"
            sleep 10
        else
            echo "  [safe_claude] Unknown error (exit=$exit_code)" >&2
            log_event "$agent_name" "ERROR" "${error_msg:0:200}"
            sleep 10
        fi
    done

    # Always release slot, even on failure
    release_pool_slot "claude" "$acquired_slot"
    rm -f "$error_file"
    echo "  [safe_claude] Slot $acquired_slot released" >&2

    if [ "$exit_code" -eq 0 ]; then
        log_event "$agent_name" "CLAUDE_DONE" "OK"
        echo "$result"
    else
        echo "  [safe_claude] FAILED — all attempts exhausted" >&2
        log_event "$agent_name" "CLAUDE_FAILED" "All attempts failed"
    fi

    return "$exit_code"
}

# ────────────────────────────────────────────
# Safe GitHub API call — with retry
# ────────────────────────────────────────────
safe_gh() {
    with_retry 3 gh "$@"
}

# ────────────────────────────────────────────
# Health check
# Returns 0 if healthy, non-zero if not
# ────────────────────────────────────────────
health_check() {
    local errors=0

    # gh CLI
    if ! command -v gh &>/dev/null; then
        echo "[health] gh CLI missing" >&2
        errors=$((errors + 1))
    elif ! gh auth status &>/dev/null 2>&1; then
        echo "[health] gh not authenticated" >&2
        errors=$((errors + 1))
    else
        # Real API check — catches expired tokens
        if ! gh api user --jq '.login' &>/dev/null 2>&1; then
            echo "[health] gh token invalid or expired" >&2
            errors=$((errors + 1))
        fi
        # Check repo is reachable
        if ! gh repo view "$GITHUB_REPO_FULL" &>/dev/null 2>&1; then
            echo "[health] Cannot reach repo: $GITHUB_REPO_FULL" >&2
            errors=$((errors + 1))
        fi
    fi

    # claude CLI
    if ! command -v claude &>/dev/null; then
        echo "[health] claude CLI missing" >&2
        errors=$((errors + 1))
    fi

    # Target project
    if [ ! -d "${TARGET_PROJECT:-.}" ]; then
        echo "[health] Target project missing: $TARGET_PROJECT" >&2
        errors=$((errors + 1))
    elif [ ! -d "${TARGET_PROJECT:-.}/.git" ]; then
        echo "[health] Target project is not a git repo" >&2
        errors=$((errors + 1))
    fi

    # Disk space (warn < 1GB)
    local free_mb
    free_mb=$(df -m "${TARGET_PROJECT:-.}" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 1024 ]; then
        echo "[health] Low disk: ${free_mb}MB free" >&2
        errors=$((errors + 1))
    fi

    # Stale locks (check both per-project and global pool)
    for lock_search_dir in "$LOCK_DIR" "$GLOBAL_LOCK_DIR"; do
    for lockfile in "$lock_search_dir"/*.lock; do
        [ -e "$lockfile" ] || continue
        local lock_time now age
        lock_time=$(cat "$lockfile" 2>/dev/null || echo "0")
        now=$(date +%s)
        age=$(( now - lock_time ))
        if [ "$age" -gt 1800 ]; then
            echo "[health] Very stale lock: $(basename "$lockfile") (${age}s)" >&2
            rm -f "$lockfile"
            rmdir "${lockfile%.lock}.d" 2>/dev/null || true
        fi
    done
    done

    [ "$errors" -eq 0 ] && return 0 || return 1
}

# ────────────────────────────────────────────
# Rotate logs if too big (>10MB each)
# ────────────────────────────────────────────
rotate_logs() {
    for logfile in "$LOG_DIR"/*.log; do
        [ -e "$logfile" ] || continue
        local size
        size=$(wc -c < "$logfile" | tr -d ' ')
        if [ "$size" -gt 10485760 ]; then
            mv "$logfile" "${logfile}.$(date '+%Y%m%d%H%M%S').bak"
            echo "[rotate] Rotated $(basename "$logfile")" >&2
        fi
    done

    # Also rotate state files
    rotate_state
}
