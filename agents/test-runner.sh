#!/bin/bash
# ============================================================
# 🧪 Test Runner Agent — Compound Engineering: Verification
#
# Runs the target project's test suite, linter, and type checker
# AFTER the engineer implements and BEFORE the reviewer reviews.
# Posts results to the Code Review discussion so the reviewer
# has hard evidence of pass/fail.
#
# This is the enforcement gate — no PR should be approved
# without test results.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-verify}"
AGENT="test-runner"

log() { echo "[$(date '+%H:%M:%S')] [TEST] $*"; }

# ────────────────────────────────────────────
# Detect and run the project's test suite
# Returns: test output on stdout, exit code 0=pass, 1=fail
# ────────────────────────────────────────────
detect_and_run_tests() {
    cd "$TARGET_PROJECT"

    local results=""
    local any_failed=0

    # ── Detect test runner ──
    if [ -f "package.json" ]; then
        # Node.js project
        if grep -q '"test"' package.json 2>/dev/null; then
            log "  Detected: npm test"
            local test_out
            test_out=$(npm test 2>&1) && results+="### npm test ✅ PASS
\`\`\`
$(echo "$test_out" | tail -30)
\`\`\`
" || { any_failed=1; results+="### npm test ❌ FAIL
\`\`\`
$(echo "$test_out" | tail -50)
\`\`\`
"; }
        fi
        if grep -q '"lint"' package.json 2>/dev/null; then
            log "  Detected: npm run lint"
            local lint_out
            lint_out=$(npm run lint 2>&1) && results+="### Lint ✅ PASS
" || { any_failed=1; results+="### Lint ❌ FAIL
\`\`\`
$(echo "$lint_out" | tail -30)
\`\`\`
"; }
        fi
        if grep -q '"typecheck\|type-check\|tsc"' package.json 2>/dev/null; then
            log "  Detected: typecheck"
            local tc_out
            tc_out=$(npx tsc --noEmit 2>&1) && results+="### Type Check ✅ PASS
" || { any_failed=1; results+="### Type Check ❌ FAIL
\`\`\`
$(echo "$tc_out" | tail -30)
\`\`\`
"; }
        fi
    fi

    if [ -f "Gemfile" ]; then
        # Ruby/Rails project
        if [ -d "spec" ]; then
            log "  Detected: rspec"
            local rspec_out
            rspec_out=$(bundle exec rspec 2>&1) && results+="### RSpec ✅ PASS
\`\`\`
$(echo "$rspec_out" | tail -20)
\`\`\`
" || { any_failed=1; results+="### RSpec ❌ FAIL
\`\`\`
$(echo "$rspec_out" | tail -50)
\`\`\`
"; }
        elif [ -d "test" ]; then
            log "  Detected: rails test"
            local rails_out
            rails_out=$(bundle exec rails test 2>&1) && results+="### Rails Test ✅ PASS
\`\`\`
$(echo "$rails_out" | tail -20)
\`\`\`
" || { any_failed=1; results+="### Rails Test ❌ FAIL
\`\`\`
$(echo "$rails_out" | tail -50)
\`\`\`
"; }
        fi
        if [ -f ".rubocop.yml" ]; then
            log "  Detected: rubocop"
            local rubocop_out
            rubocop_out=$(bundle exec rubocop 2>&1) && results+="### Rubocop ✅ PASS
" || { any_failed=1; results+="### Rubocop ❌ FAIL
\`\`\`
$(echo "$rubocop_out" | tail -30)
\`\`\`
"; }
        fi
    fi

    if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
        # Python project
        if [ -d "tests" ] || [ -d "test" ]; then
            log "  Detected: pytest"
            local pytest_out
            pytest_out=$(python3 -m pytest 2>&1) && results+="### Pytest ✅ PASS
\`\`\`
$(echo "$pytest_out" | tail -20)
\`\`\`
" || { any_failed=1; results+="### Pytest ❌ FAIL
\`\`\`
$(echo "$pytest_out" | tail -50)
\`\`\`
"; }
        fi
        if command -v ruff &>/dev/null; then
            log "  Detected: ruff"
            local ruff_out
            ruff_out=$(ruff check . 2>&1) && results+="### Ruff ✅ PASS
" || { any_failed=1; results+="### Ruff ❌ FAIL
\`\`\`
$(echo "$ruff_out" | tail -30)
\`\`\`
"; }
        fi
    fi

    if [ -f "go.mod" ]; then
        # Go project
        log "  Detected: go test"
        local go_out
        go_out=$(go test ./... 2>&1) && results+="### Go Test ✅ PASS
\`\`\`
$(echo "$go_out" | tail -20)
\`\`\`
" || { any_failed=1; results+="### Go Test ❌ FAIL
\`\`\`
$(echo "$go_out" | tail -50)
\`\`\`
"; }
    fi

    if [ -f "Cargo.toml" ]; then
        # Rust project
        log "  Detected: cargo test"
        local cargo_out
        cargo_out=$(cargo test 2>&1) && results+="### Cargo Test ✅ PASS
\`\`\`
$(echo "$cargo_out" | tail -20)
\`\`\`
" || { any_failed=1; results+="### Cargo Test ❌ FAIL
\`\`\`
$(echo "$cargo_out" | tail -50)
\`\`\`
"; }
    fi

    if [ -z "$results" ]; then
        results="### ⚠️ No test runner detected
Could not detect a test suite in this project. Checked for:
- package.json (npm test/lint)
- Gemfile (rspec/rails test/rubocop)
- requirements.txt/pyproject.toml (pytest/ruff)
- go.mod (go test)
- Cargo.toml (cargo test)

**Manual verification required.**"
        any_failed=2  # unknown — flag for human review
    fi

    echo "$results"
    return "$any_failed"
}

# ────────────────────────────────────────────
# verify — Run tests on branches with open Code Review discussions
# ────────────────────────────────────────────
run_verify() {
    log "🧪 Looking for PRs to test..."

    local unprocessed
    unprocessed=$(get_unprocessed "$CAT_CODE_REVIEW" "$AGENT_TEST_RUNNER") || return 0

    echo "$unprocessed" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    title = d['title'].replace('\t', ' ')
    body = d['body'][:2000].replace('\t', ' ')
    print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue

        is_processed "$num" "$AGENT" "tested" && continue

        log "🧪 Testing #$num: $title"

        # Extract branch name
        local branch_name
        branch_name=$(echo "$body" | sed -n 's/.*Branch:[[:space:]]*`\([^`]*\)`.*/\1/p' | head -1)

        if [ -z "$branch_name" ]; then
            log "  ⚠️  No branch found in #$num — skipping"
            mark_processed "$num" "$AGENT" "tested"
            continue
        fi

        # Checkout the branch
        cd "$TARGET_PROJECT"
        git fetch origin 2>/dev/null || true
        local base_branch
        base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")

        git checkout "$branch_name" 2>/dev/null || git checkout -b "$branch_name" "origin/$branch_name" 2>/dev/null || {
            log "  ⚠️  Cannot checkout $branch_name"
            reply_to_discussion "$num" "⚠️ **Test Runner:** Could not checkout branch \`$branch_name\`." "$AGENT_TEST_RUNNER" || true
            mark_processed "$num" "$AGENT" "tested"
            git checkout "$base_branch" 2>/dev/null || true
            continue
        }

        # Run tests
        local test_results
        local test_exit
        test_results=$(detect_and_run_tests 2>&1)
        test_exit=$?

        local verdict
        if [ "$test_exit" -eq 0 ]; then
            verdict="## 🧪 Test Results: ✅ ALL PASSING"
            tag_discussion "$num" "tests-passing" || true
        elif [ "$test_exit" -eq 2 ]; then
            verdict="## 🧪 Test Results: ⚠️ NO TESTS DETECTED"
        else
            verdict="## 🧪 Test Results: ❌ FAILURES FOUND"
            tag_discussion "$num" "tests-failing" || true
        fi

        reply_to_discussion "$num" "$verdict

$test_results

---
*Tests must pass before merge approval.*" "$AGENT_TEST_RUNNER" || true

        mark_processed "$num" "$AGENT" "tested"

        # Return to base branch
        git checkout "$base_branch" 2>/dev/null || true

        log "✅ Test run complete for #$num (exit=$test_exit)"
    done
}

case "$MODE" in
    verify) run_verify ;;
    *)      echo "Usage: $0 {verify}"; exit 1 ;;
esac
