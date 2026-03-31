#!/bin/bash
# ============================================================
# 🔗 Dependency Auditor Agent — Security & freshness
#
# Scans for vulnerable dependencies, outdated packages,
# and license compatibility issues.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-audit}"
AGENT="dependency-auditor"

log() { echo "[$(date '+%H:%M:%S')] [DEP] $*"; }

run_audit() {
    log "🔗 Auditing dependencies..."

    cd "$TARGET_PROJECT"
    local findings=""
    local has_issues=false

    # ── npm audit ──
    if [ -f "package.json" ]; then
        log "  Checking npm..."
        local npm_audit
        npm_audit=$(npm audit --json 2>/dev/null || echo '{}')
        local vuln_count
        vuln_count=$(echo "$npm_audit" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    meta = d.get('metadata', d.get('vulnerabilities', {}))
    if isinstance(meta, dict) and 'vulnerabilities' in meta:
        v = meta['vulnerabilities']
        total = sum(v.values()) if isinstance(v, dict) else 0
    else:
        total = sum(meta.values()) if isinstance(meta, dict) else 0
    print(total)
except:
    print(0)
" 2>/dev/null)
        if [ "${vuln_count:-0}" -gt 0 ]; then
            findings+="### npm: $vuln_count vulnerabilities found
\`\`\`
$(npm audit 2>/dev/null | head -40)
\`\`\`
"
            has_issues=true
        else
            findings+="### npm: ✅ No vulnerabilities
"
        fi

        # Check outdated
        local outdated
        outdated=$(npm outdated 2>/dev/null | head -20)
        if [ -n "$outdated" ]; then
            findings+="### npm outdated packages
\`\`\`
$outdated
\`\`\`
"
        fi
    fi

    # ── pip audit ──
    if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
        log "  Checking Python..."
        if command -v pip-audit &>/dev/null; then
            local pip_result
            pip_result=$(pip-audit 2>&1) && findings+="### pip-audit: ✅ No vulnerabilities
" || { findings+="### pip-audit: vulnerabilities found
\`\`\`
$(echo "$pip_result" | head -30)
\`\`\`
"; has_issues=true; }
        fi

        if command -v pip &>/dev/null; then
            local outdated_py
            outdated_py=$(pip list --outdated 2>/dev/null | head -20)
            if [ -n "$outdated_py" ]; then
                findings+="### pip outdated packages
\`\`\`
$outdated_py
\`\`\`
"
            fi
        fi
    fi

    # ── bundle audit ──
    if [ -f "Gemfile.lock" ]; then
        log "  Checking Ruby..."
        if command -v bundle-audit &>/dev/null || command -v bundler-audit &>/dev/null; then
            local bundle_result
            bundle_result=$(bundle audit check --update 2>&1) && findings+="### bundle-audit: ✅ No vulnerabilities
" || { findings+="### bundle-audit: vulnerabilities found
\`\`\`
$(echo "$bundle_result" | head -30)
\`\`\`
"; has_issues=true; }
        fi
    fi

    # ── License check ──
    log "  Checking licenses..."
    local license_prompt
    license_prompt=$(load_prompt "dependency-licenses") || license_prompt=""
    if [ -n "$license_prompt" ]; then
        local license_result
        license_result=$(safe_claude "$AGENT" "$license_prompt" \
        --allowedTools "Read,Glob,Grep") || license_result="(license check failed)"
        findings+="### License Compliance
$license_result
"
    fi

    # Post results
    if [ "$has_issues" = true ]; then
        post_discussion "$CAT_TRIAGE" "[HIGH] Dependency vulnerabilities found" \
"**Priority:** high
**Category:** security

$findings

**Suggested approach:** Run \`npm audit fix\` / \`pip-audit --fix\` / \`bundle update\` to resolve known vulnerabilities." "$AGENT_DEP_AUDITOR" || true
        log "⚠️  Vulnerabilities found — posted to Triage"
    else
        log "✅ Dependencies clean"
    fi

    log_event "$AGENT" "AUDIT_DONE" "has_issues=$has_issues"
}

case "$MODE" in
    audit) run_audit ;;
    *)     echo "Usage: $0 {audit}"; exit 1 ;;
esac
