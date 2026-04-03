#!/bin/bash
# ============================================================
# Test detection and execution — shared by test-runner + pipeline
#
# Usage: source this file, then call detect_and_run_tests
# Must be called from within the target project directory.
# Returns: 0=pass, 1=fail, 2=no tests detected
# Output: markdown-formatted test results on stdout
# ============================================================

detect_and_run_tests() {
    local results=""
    local any_failed=0
    local _log_fn="${1:-echo}"  # optional log function

    # ── Node.js ──
    if [ -f "package.json" ]; then
        if grep -q '"test"' package.json 2>/dev/null; then
            $_log_fn "  Detected: npm test" 2>/dev/null || true
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
            $_log_fn "  Detected: lint" 2>/dev/null || true
            local lint_out
            lint_out=$(npm run lint 2>&1) && results+="### Lint ✅ PASS
" || { any_failed=1; results+="### Lint ❌ FAIL
\`\`\`
$(echo "$lint_out" | tail -30)
\`\`\`
"; }
        fi
    fi

    # ── Python ──
    if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
        if [ -d "tests" ] || [ -d "test" ]; then
            $_log_fn "  Detected: pytest" 2>/dev/null || true
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
    fi

    # ── Go ──
    if [ -f "go.mod" ]; then
        $_log_fn "  Detected: go test" 2>/dev/null || true
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

    # ── Rust ──
    if [ -f "Cargo.toml" ]; then
        $_log_fn "  Detected: cargo test" 2>/dev/null || true
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

    # ── Ruby ──
    if [ -f "Gemfile" ]; then
        if [ -d "spec" ]; then
            $_log_fn "  Detected: rspec" 2>/dev/null || true
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
        fi
    fi

    if [ -z "$results" ]; then
        results="### ⚠️ No test runner detected
Could not find a test suite. Manual verification required."
        any_failed=2
    fi

    echo "$results"
    return "$any_failed"
}
