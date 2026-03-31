# Agent Factory — End-to-End Lifecycle

## Design Principles

1. **Claude sessions are expensive.** Every `safe_claude` call costs ~3 min. Budget: ~10 sessions/cycle.
2. **Shell when possible, AI when necessary.** Tests, health checks, CI parsing, git ops = shell. Planning, coding, reviewing, learning = AI.
3. **One session per concern.** The reviewer covers 7 domains in ONE prompt. The planner does research AND planning in one pass.
4. **Only post when something happened.** No "nothing to report" Discussions.
5. **The system must get smarter.** Self-improvement extracts project-specific rules from past work and injects them into future prompts.

## The Cycle

```
 DISCOVER → PLAN → BUILD → VERIFY → SHIP → LEARN
   2-4 sess  2 sess  1 sess  2 sess  0 sess  1-2 sess
```

### Phase 1: DISCOVER — What needs building? (2 sessions)

```
📊 Product Manager ──── intake ────────── 1 session
   │  Reads: GitHub Issues, Ideas Discussions, CI failures
   │  Creates: Triage items (clear) or Q&A @human (unclear)
   │  Rule: proceed autonomously unless fundamentally ambiguous
   │
   ├── check-decisions ────────────────── 1 session (if Q&A replies exist)
   │   Reads: your replies to Q&A Discussions
   │   Creates: Triage items from your decisions
   │
🎯 CTO ──── triage ───────────────────── 1 session
   │  Prioritizes Triage backlog
   │
   └── scan (every 5 cycles) ─────────── 1 session
       Scans codebase for bugs, security, env isolation, missing tools
```

### Phase 2: PLAN — How to build it? (2 sessions)

```
📋 Planner ──── plan ─────────────────── 1 session
   │  In ONE pass: research codebase + check past solutions + write plan
   │  Reads: docs/solutions/, CLAUDE.md, rules.md, style.md
   │  Output: implementation steps, files, tests, infra impact
   │
🎯 CTO ──── approve-plans ───────────── 1 session
       Gate: rejects incomplete plans or env isolation violations
```

### Phase 3: BUILD — Write the code (1 session)

```
👷 Engineer ──── work ────────────────── 1 session
       Follows the plan step by step. Runs tests as it goes.
       Commits to branch, pushes, opens PR.
```

### Phase 4: VERIFY — Does it work? (2 sessions)

```
🧪 Test Runner ──── verify ──────────── 0 sessions (shell)
   │  Runs: npm test, lint, typecheck
   │  Gate: blocks review if tests fail
   │
🔎 Reviewer ──── review ─────────────── 1 session
   │  ONE comprehensive pass covering 7 domains:
   │  security, performance, architecture, data integrity,
   │  code quality, deployment safety, test coverage
   │  Gate: blocks merge if P1 findings
   │
👷 Engineer ──── respond-reviews ─────── 1 session
       Fixes P1/P2 findings from review
```

### Phase 5: SHIP — Deploy to staging (0 sessions — all shell)

```
🎯 CTO ──── review-prs ─────────────── 0 sessions (gh pr merge)
   │  Gate: CI ✅ + review ✅ → squash merge
   │
🔧 DevOps ──── staging ─────────────── 0 sessions (git)
   │  Rebuilds staging branch from all merged PRs
   │  Push triggers CI → deploy-staging.yml
   │     └── unit tests → deploy to S3 → Playwright smoke tests
   │
🔧 DevOps ──── deploy-verify ───────── 0 sessions (curl)
   │  HTTP health check on staging URL
   │
🚨 SRE ──── monitor ────────────────── 0 sessions (curl)
   │  Health checks ALL environments (prod + staging)
   │  TLS cert expiry check
   │
🚦 Quality Gate ──── check ─────────── 0 sessions (gh run view)
       Parses CI results: unit tests, deploy, smoke tests
       Posts staging report with ✅/❌ table
       If ❌: creates targeted fix tasks → retry next cycle
       If ✅: @mentions you — "ready for prod, merge staging → main"
```

### Phase 6: LEARN — Get smarter (1-2 sessions)

```
🔄 Compound ──── extract ───────────── 1 session
   │  Writes: docs/solutions/YYYY-MM-DD-*.md (YAML frontmatter)
   │  Adds: smoke tests to e2e/smoke.spec.js for new features
   │  Suggests: CLAUDE.md updates
   │
🧬 Self-Improve (every 5 cycles) ──── 1 session
       Reads: docs/solutions/, todos/, codebase
       Writes: projects/<name>/rules.md (review rules from past findings)
       Writes: projects/<name>/style.md (coding conventions)
       These are auto-injected into ALL future prompts
       → The system catches yesterday's mistakes automatically
```

## Periodic Audits (1 session, staggered — one per cycle)

| Cycle mod 10 | Agent | What |
|---|---|---|
| 2 | 📝 Docs Writer | Doc drift, missing docs |
| 4 | 🔗 Dependency Auditor | Vulnerabilities, licenses |
| 6 | ♿ Accessibility Auditor | WCAG 2.2 compliance |
| 8 | 🚨 SRE | Environment isolation audit |
| 0 | 🧪 QA Writer | Generate tests for coverage gaps |

Plus: Quality Gate report (every 5), Changelog (every 20).

## Session Budget

| Phase | Sessions | Notes |
|-------|----------|-------|
| Discover | 2-4 | PM + CTO triage (+ scan every 5 cycles) |
| Plan | 2 | Planner + CTO approve |
| Build | 1 | Engineer |
| Verify | 2 | Reviewer + Engineer respond |
| Ship | 0 | All shell operations |
| Learn | 1 | Compound |
| Periodic | 1 | Staggered audit |
| **Light cycle** | **~8** | **~24 min** |
| **Normal cycle** | **~10** | **~30 min** |
| **Heavy cycle (self-improve + scan + audit)** | **~13** | **~39 min** |

## Security — Owned by 🛡️ Security Agent

Security is NOT a checklist item in the reviewer. It's a dedicated agent with 4 touchpoints:

```
DISCOVER ──── security scan ───── secrets, attack surface, hardcoded creds
                                   (every 5 cycles, alongside CTO scan)

VERIFY ────── security review ──── dedicated security pass on every PR diff
                                   separate from general review — security
                                   findings can't be deprioritized by mixing
                                   with style/perf concerns
                                   can BLOCK merge (security-blocked tag)

SHIP ──────── deploy-check ─────── HTTP headers, TLS, server version exposure
                                   runs against live staging URL after deploy
                                   (0 sessions — shell only: curl + openssl)

PERIODIC ──── security audit ───── npm audit CVEs, secret grep, .env in git,
                                   verify past findings were actually fixed
                                   (every 10 cycles)
```

**Security gate on merge:** CTO checks for `security-blocked` tag before merging any PR. A security block cannot be overridden by code review approval.

## Gates

| # | Gate | Type | Blocks | Retry |
|----|------|------|--------|-------|
| 1 | PM escalation | Human (Q&A) | Only fundamental ambiguity | You reply → next cycle |
| 2 | Plan approval | Auto | Bad plans, env violations | Planner revises |
| 3 | Unit tests | Auto (CI) | Failures | Engineer auto-fixes |
| 4 | Code review | Auto (1 session) | P1 findings | Engineer auto-fixes |
| 5 | **Security review** | **Auto (1 session)** | **SECURITY BLOCK** | **Engineer must fix — cannot skip** |
| 6 | CI pipeline | Auto | Build/deploy failure | Fix task → next cycle |
| 7 | Smoke tests (E2E) | Auto (CI) | Broken user flows | Fix task → next cycle |
| 8 | Quality gate | Auto (shell) | Any CI job failing | Targeted fix tasks |
| 9 | **You merge to main** | **HUMAN — MANDATORY** | **ALWAYS** | **Agents NEVER merge to main** |

### CRITICAL: Agents never merge to main

The CTO tags PRs as `staging-approved` and includes them in the staging branch rebuild.
**Only you can merge staging → main.** This is the prod gate. No exceptions.

```
Agents CAN:     approve PRs, rebuild staging, deploy to staging, post reports
Agents CANNOT:  merge to main, deploy to prod, bypass your approval
```

## Self-Improvement Loop

```
Cycle N:   Reviewer finds "missing try/catch in WS handler" → P2 finding
Cycle N:   Compound documents it in docs/solutions/
Cycle N+5: Self-improve reads 3 similar solutions →
           Writes to rules.md: "All WS handlers MUST have try/catch"
Cycle N+6: Planner reads rules.md → includes try/catch in plan
           Reviewer reads rules.md → checks for try/catch
           → This category of bug is eliminated
```

Project-specific knowledge lives in:
```
projects/<name>/
├── rules.md    ← auto-generated review rules (from past findings)
├── style.md    ← auto-extracted coding conventions
├── envs/       ← per-environment configs
└── prompts/    ← project-specific prompt overrides (manual)
```

All prompts automatically receive: `rules.md` + `style.md` + `env-context.md`.
No generic personalities — only project-specific, evidence-based knowledge.

## What You See

**In Discussions (tagged `[staging]` or `[prod]`):**

```
🚦 [staging] Staging: ✅ READY — c9d1e2f
  | Unit tests | ✅ | Coverage: 85% |
  | Deploy     | ✅ |               |
  | Smoke (3)  | ✅ | 3/3 passed    |
  | Health     | ✅ | HTTP 200      |
  @clercrobin — merge staging → main to ship.

❓ [staging] Decision needed: Add spectator mode?
  Two approaches: A) read-only WebSocket B) replay from server state
  @clercrobin — reply to unblock.

🧬 CLAUDE.md update suggested
  + "All WebSocket handlers must wrap applyMove in try/catch"
  + "Use structuredClone for state snapshots, not JSON round-trip"
```

**On your machine:**
```bash
./labs.sh              # all environments with health status
./labs.sh --watch      # auto-refresh
```

## How You Interact

| Action | Where |
|--------|-------|
| Request a feature | Post to **Ideas** in Discussions |
| Report a bug | Open **GitHub Issue** on the project |
| Answer a question | Reply to **Q&A** Discussion |
| Check staging | Look for `🚦 Staging: ✅ READY` |
| Ship to prod | Merge `staging → main` |
| Monitor | `./labs.sh` |

## 17 Agents, 22 Prompts, 0 Dead Code

```
agents/ (17)                   prompts/ (22)
├── product-manager.sh         ├── pm-intake.md
├── cto.sh                     ├── pm-decision.md
├── planner.sh                 ├── cto-scan.md
├── senior-engineer.sh         ├── cto-triage.md
├── test-runner.sh             ├── cto-approve-plan.md
├── reviewer.sh                ├── planner-plan.md
├── security.sh ← NEW         ├── engineer-implement.md
├── devops.sh                  ├── engineer-respond.md
├── sre.sh                     ├── reviewer-comprehensive.md
├── quality-gate.sh            ├── security-scan.md ← NEW
├── compound.sh                ├── security-review.md ← NEW
├── self-improve.sh            ├── compound-extract.md
├── docs-writer.sh             ├── self-improve-learn.md
├── dependency-auditor.sh      ├── docs-audit.md, docs-update.md
├── accessibility-auditor.sh   ├── dependency-licenses.md
├── qa-writer.sh               ├── devops-infra.md, devops-apply.md
└── release-manager.sh         ├── a11y-audit.md, qa-generate.md
                               ├── release-changelog.md
                               └── env-context.md (auto-injected)
```
