#!/bin/bash
# ============================================================
# Ensure target project has a CLAUDE.md
#
# If TARGET_PROJECT has no CLAUDE.md, auto-generate one by
# scanning the project for stack, commands, and structure.
#
# Usage: source this file, then call ensure_claude_md
# ============================================================

ensure_claude_md() {
    local target="${TARGET_PROJECT:-.}"
    local claude_md="$target/CLAUDE.md"

    [ -f "$claude_md" ] && return 0

    echo "[setup] No CLAUDE.md found — generating one for $(basename "$target")" >&2

    local project_name
    project_name=$(basename "$target")

    # ── Detect stack ──
    local stack_lines=""
    local commands_lines=""
    local has_npm=false has_python=false has_go=false has_rust=false has_ruby=false

    if [ -f "$target/package.json" ]; then
        has_npm=true
        local pkg_scripts
        pkg_scripts=$(python3 -c "
import json
d = json.load(open('$target/package.json'))
for k, v in d.get('scripts', {}).items():
    print(f'{k}: {v}')
" 2>/dev/null)

        # Detect framework
        local framework=""
        grep -q '"react"' "$target/package.json" && framework="React"
        grep -q '"vue"' "$target/package.json" && framework="Vue"
        grep -q '"next"' "$target/package.json" && framework="Next.js"
        grep -q '"svelte"' "$target/package.json" && framework="Svelte"
        grep -q '"angular"' "$target/package.json" && framework="Angular"

        local bundler=""
        grep -q '"vite"' "$target/package.json" && bundler="Vite"
        grep -q '"webpack"' "$target/package.json" && bundler="Webpack"
        grep -q '"esbuild"' "$target/package.json" && bundler="esbuild"

        local test_framework=""
        grep -q '"vitest"' "$target/package.json" && test_framework="Vitest"
        grep -q '"jest"' "$target/package.json" && test_framework="Jest"
        grep -q '"mocha"' "$target/package.json" && test_framework="Mocha"
        grep -q '"playwright"' "$target/package.json" && test_framework="${test_framework:+$test_framework + }Playwright"

        stack_lines="- **Frontend:** ${framework:-JavaScript}${bundler:+ ($bundler)}"
        [ -d "$target/server" ] || [ -f "$target/server.js" ] || grep -q '"express"' "$target/package.json" 2>/dev/null && \
            stack_lines="$stack_lines
- **Backend:** Node.js$(grep -q '"express"' "$target/package.json" 2>/dev/null && echo ', Express')"
        [ -n "$test_framework" ] && stack_lines="$stack_lines
- **Tests:** $test_framework"

        commands_lines="npm install           # Install dependencies"
        echo "$pkg_scripts" | grep -q "^test:" && commands_lines="$commands_lines
npm test              # Run tests"
        echo "$pkg_scripts" | grep -q "^build:" && commands_lines="$commands_lines
npm run build         # Build for production"
        echo "$pkg_scripts" | grep -q "^dev:" && commands_lines="$commands_lines
npm run dev           # Dev server"
        echo "$pkg_scripts" | grep -q "^lint:" && commands_lines="$commands_lines
npm run lint          # Linter"
    fi

    if [ -f "$target/requirements.txt" ] || [ -f "$target/pyproject.toml" ] || [ -f "$target/setup.py" ]; then
        has_python=true
        stack_lines="${stack_lines:+$stack_lines
}- **Language:** Python"
        commands_lines="${commands_lines:+$commands_lines
}pip install -r requirements.txt  # Install dependencies"
        [ -f "$target/pytest.ini" ] || [ -f "$target/pyproject.toml" ] && commands_lines="$commands_lines
pytest                # Run tests"
    fi

    if [ -f "$target/go.mod" ]; then
        has_go=true
        stack_lines="${stack_lines:+$stack_lines
}- **Language:** Go"
        commands_lines="${commands_lines:+$commands_lines
}go test ./...        # Run tests
go build              # Build"
    fi

    if [ -f "$target/Cargo.toml" ]; then
        has_rust=true
        stack_lines="${stack_lines:+$stack_lines
}- **Language:** Rust"
        commands_lines="${commands_lines:+$commands_lines
}cargo test           # Run tests
cargo build           # Build"
    fi

    if [ -f "$target/Gemfile" ]; then
        has_ruby=true
        stack_lines="${stack_lines:+$stack_lines
}- **Language:** Ruby"
        commands_lines="${commands_lines:+$commands_lines
}bundle install       # Install dependencies
bundle exec rspec     # Run tests"
    fi

    # Detect infra
    [ -d "$target/infra/terraform" ] && stack_lines="$stack_lines
- **Infra:** Terraform (in \`infra/terraform/\`)"
    [ -d "$target/.github/workflows" ] && stack_lines="$stack_lines
- **CI:** GitHub Actions"

    # Detect deploy
    local deploy_info=""
    [ -n "${DEPLOY_URL:-}" ] && deploy_info="- **Staging URL:** $DEPLOY_URL"
    [ -n "${DEPLOY_BRANCH:-}" ] && deploy_info="$deploy_info
- **Staging branch:** ${DEPLOY_BRANCH}
- **Prod branch:** main"

    # Fallback if nothing detected
    [ -z "$stack_lines" ] && stack_lines="- *(auto-detection found no recognized stack — update this section)*"
    [ -z "$commands_lines" ] && commands_lines="# No standard commands detected — update this section"

    # ── Write CLAUDE.md ──
    cat > "$claude_md" << CLAUDEMD
# CLAUDE.md — $project_name

## Stack
$stack_lines

## Commands
\`\`\`bash
$commands_lines
\`\`\`

## Work Methodology

### Gather → Act → Verify → Repeat
Every task follows this loop. No step is optional.

### Pre-Work
- Before refactoring a file >300 LOC, remove dead code first. Commit cleanup separately.
- Break multi-file changes into phases of ≤5 files. Verify each phase before continuing.
- When given a plan, follow it exactly. If something is wrong, flag it — don't improvise.

### Code Quality
- Fix architecture issues when you see them. Ask: "Would a senior dev reject this in code review?"
- Write code that reads like a human wrote it. No robotic comment blocks.
- Don't over-engineer for hypothetical futures.

### Verification — MANDATORY
You are FORBIDDEN from reporting a task as complete until you have:
1. Run tests (see Commands above)
2. Run the build/compile step
3. Fixed ALL resulting errors

Never claim success with errors outstanding.

### Context Hygiene
- After 10+ messages, re-read any file before editing it.
- For files over 500 LOC, use offset/limit to read in chunks.
- If grep returns few results, re-run with narrower scope.
- Use sub-agents for tasks touching >5 independent files.

### Edit Safety
- Re-read a file before and after editing.
- When renaming anything, search for: direct calls, type references, string literals, dynamic imports, re-exports, test mocks.
- Never delete a file without verifying nothing references it.

### Failure Recovery
- If a fix doesn't work after two attempts, stop. Re-read the code top-down. Find where your mental model was wrong.
- After fixing a bug, note what caused it and whether a pattern prevents the category.
${deploy_info:+
## Environment
$deploy_info
- Each environment has independent infrastructure state. Never cross-reference environments.
}
CLAUDEMD

    echo "[setup] Generated CLAUDE.md for $project_name" >&2
    return 0
}
