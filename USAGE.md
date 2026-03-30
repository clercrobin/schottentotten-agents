# AI Agent Factory — Multi-Project Usage Guide

Running multiple AI agent teams on your Mac Studio, managed over SSH.

---

## Overview

The factory is a **reusable engine** that targets **existing codebases**. You point it at a project that already lives on disk and on GitHub — the factory doesn't create or modify that project. Instead, it creates a **separate `-agents` repo** alongside it where the AI team communicates via GitHub Discussions.

For each project you add, the factory creates:
- A **dedicated GitHub repo** (`<project>-agents`) for agent communication — your actual codebase is untouched
- Isolated state, logs, and config in `projects/<name>/`
- Optional custom prompts and agent overrides
- Its own tmux session

The base engine (`agents/`, `lib/`, `prompts/`) is never modified per-project.

```
~/Workspace/
├── my-saas-app/                ← YOUR CODE (already exists, already on GitHub)
│   ├── src/
│   ├── tests/
│   └── .git/
│
├── ai-agent-factory/           ← ENGINE (shared, never modified per-project)
│   ├── agents/                 ← default agent scripts
│   ├── prompts/                ← default prompt templates
│   ├── lib/                    ← shared libraries
│   └── projects/
│       ├── schottentotten/     ← agent config for project A
│       │   ├── config.sh      ← points to ~/Workspace/schottentotten
│       │   ├── state/
│       │   ├── logs/
│       │   ├── prompts/       ← optional overrides
│       │   └── agents/        ← optional overrides
│       └── my-saas-app/       ← agent config for project B
│           └── config.sh      ← points to ~/Workspace/my-saas-app

GitHub:
├── clercrobin/my-saas-app              ← your actual code repo (PRs land here)
├── clercrobin/my-saas-app-agents       ← agent Discussions repo (created by spawn)
├── clercrobin/schottentotten           ← your actual code repo
└── clercrobin/schottentotten-agents    ← agent Discussions repo
```

The agents **read and write code** in your project repo, **open PRs** against it, and **discuss work** in the `-agents` repo.

---

## 1. SSH into your Mac Studio

```bash
ssh macstudio
# or
ssh robin@192.168.x.x
```

Everything below runs on the Mac Studio.

---

## 2. Spawn agents for an existing project

Your project already exists — it's a git repo on disk and on GitHub, with code in it. `spawn` creates the **agent infrastructure around it**:

```bash
cd ~/Workspace/ai-agent-factory

# Point the factory at your existing project
./spawn.sh my-saas-app ~/Workspace/my-saas-app
```

What spawn does (and doesn't do):

| Does | Doesn't |
|------|---------|
| Creates `clercrobin/my-saas-app-agents` repo on GitHub (for Discussions) | Touch your code repo `clercrobin/my-saas-app` |
| Enables Discussions + prompts you to create categories | Modify any files in `~/Workspace/my-saas-app/` |
| Scaffolds `projects/my-saas-app/` inside the factory (config, state, logs) | Clone or fork your project |
| Posts a welcome message to the agents repo | Install anything in your project |

The agents will then: read/write code in `~/Workspace/my-saas-app/`, push branches and open PRs on `clercrobin/my-saas-app`, and discuss their work in `clercrobin/my-saas-app-agents`.

With a custom GitHub org:

```bash
./spawn.sh my-saas-app ~/Workspace/my-saas-app --owner myorg
```

List all projects:

```bash
./spawn.sh list
# PROJECT              TARGET                                   REPO
# schottentotten       /Users/robin/Workspace/schottentotten     clercrobin/schottentotten-agents
# my-saas-app          /Users/robin/Workspace/my-saas-app        clercrobin/my-saas-app-agents
```

---

## 3. Run agents for a project

Every command accepts `--project <name>`:

```bash
# One-shot test
./kick.sh --project my-saas-app cto scan

# Single cycle (all agents once)
./orchestrator.sh --project my-saas-app --once

# Full loop
./orchestrator.sh --project my-saas-app --loop
```

### Set a default project (avoid typing --project every time)

```bash
# Option A: env var (current shell only)
export AI_AGENT_PROJECT=my-saas-app

# Option B: file-based (persists)
echo "my-saas-app" > .current-project
```

Then just `./kick.sh cto scan` — it picks up the default.

---

## 4. Run projects in tmux (interactive, over SSH)

Each project gets its own tmux session, named `agent-factory-<project>`:

```bash
# Start project A
./factory.sh --project schottentotten start

# Start project B (separate tmux session)
./factory.sh --project my-saas-app start

# Attach to either one
./factory.sh --project schottentotten attach
./factory.sh --project my-saas-app attach
```

Detach from tmux with `Ctrl+B d` — agents keep running.

List running sessions:

```bash
tmux ls
# agent-factory-schottentotten: 1 windows ...
# agent-factory-my-saas-app: 1 windows ...
```

Reattach after disconnecting SSH:

```bash
ssh macstudio
tmux attach -t agent-factory-schottentotten
```

---

## 5. Run as background services (headless, survives SSH disconnect)

For always-on operation, install as launchd daemons. Since launchd doesn't natively support per-project instances, use tmux in detached mode — it's the simplest approach:

```bash
# Start both (detached, no need to attach)
./factory.sh --project schottentotten start
./factory.sh --project my-saas-app start
```

tmux sessions survive SSH disconnects. They run until you stop them or the machine reboots.

To **auto-start on boot**, add to your crontab:

```bash
crontab -e
```

```
@reboot cd ~/Workspace/ai-agent-factory && ./factory.sh --project schottentotten start
@reboot cd ~/Workspace/ai-agent-factory && ./factory.sh --project my-saas-app start
```

---

## 6. Monitor & control over SSH

```bash
ssh macstudio

cd ~/Workspace/ai-agent-factory

# Status of a project
./factory.sh --project schottentotten status

# Tail logs
./factory.sh --project schottentotten logs

# Dashboard (live updating)
./dashboard.sh --project my-saas-app

# Manually trigger an action
./kick.sh --project my-saas-app engineer work

# Inject a task
./kick.sh --project my-saas-app seed "Add dark mode support"

# Open the Discussions forum in your local browser (from Mac Studio)
./factory.sh --project schottentotten forum

# Stop a project
./factory.sh --project schottentotten stop
```

---

## 7. Customize per project

### Config overrides

Edit `projects/<name>/config.sh`:

```bash
# Use a stronger model for complex codebases
export CLAUDE_MODEL="opus"

# Higher budget for long tasks
export CLAUDE_MAX_BUDGET="10.00"

# Slower polling to save rate limits
export POLL_INTERVAL="120"
```

### Custom prompts

Drop a file in `projects/<name>/prompts/` with the same name as a base prompt to override it:

```bash
# Override CTO scan for this project
cat > projects/my-saas-app/prompts/cto-scan.md << 'EOF'
You are the CTO of a SaaS application. Analyze the codebase.

Focus especially on: authentication security, API rate limiting,
database query performance, and billing integration correctness.

For each issue, output a JSON array:
[{"title": "...", "priority": "critical|high|medium|low", "category": "bug|security|performance|quality", "description": "...", "files": ["..."], "suggested_approach": "..."}]

Output ONLY the JSON array. Max 5 issues.
EOF
```

Available prompt names: `cto-scan`, `cto-triage`, `engineer-implement`, `engineer-respond`, `reviewer-review`.

### Custom agents

Drop a script in `projects/<name>/agents/` to override a base agent:

```bash
# Custom CTO for this project
cp agents/cto.sh projects/my-saas-app/agents/cto.sh
# Edit to add project-specific logic
```

Or add entirely new agents — the orchestrator resolves from `projects/<name>/agents/` first.

---

## 8. Typical multi-project SSH workflow

```bash
# Morning: SSH in and check on everything
ssh macstudio
cd ~/Workspace/ai-agent-factory

# Quick status of all projects
./spawn.sh list
./factory.sh --project schottentotten status
./factory.sh --project my-saas-app status

# Check what happened overnight
tail -20 projects/schottentotten/logs/orchestrator.log
tail -20 projects/my-saas-app/logs/orchestrator.log

# Seed a new task for project A
./kick.sh --project schottentotten seed "Refactor the auth middleware"

# Attach to project B to watch it work
tmux attach -t agent-factory-my-saas-app
# Ctrl+B d to detach

# Disconnect — everything keeps running
exit
```

---

## Resource considerations

### Parallel sessions (`MAX_PARALLEL_SESSIONS`)

The factory uses a **pool of lock slots** to control how many Claude sessions can run simultaneously. By default there's 1 slot — only one agent talks to Claude at a time. Set `MAX_PARALLEL_SESSIONS` to allow 2 or 3 agents to run in parallel.

```
MAX_PARALLEL_SESSIONS=1       →  claude-0.lock
MAX_PARALLEL_SESSIONS=3       →  claude-0.lock, claude-1.lock, claude-2.lock
```

Each slot = 1 Claude Code Max subscription. When an agent calls `safe_claude()`, it grabs the first free slot. If all slots are busy, it waits (up to 5 min).

The lock pool lives in the **base** `state/locks/` directory (not per-project), so all projects share the same pool. Two projects can't accidentally exceed your total number of subscriptions.

**Set it in `config.sh`** (global, one knob for the whole Mac Studio):
```bash
export MAX_PARALLEL_SESSIONS=3
```

This is intentionally a global setting — it reflects how many Claude Code Max subscriptions you have on this machine, not a per-project preference.

### Within a project: two orchestration modes

| Mode | How it works | Best with |
|---|---|---|
| `orchestrator.sh` (sequential) | One loop, agents run one after another: CTO scan → Engineer work → Reviewer review → ... | 1 slot |
| `parallel-orchestrator.sh` (concurrent) | Each agent gets its own tmux pane and polls independently | 2-3 slots |

With `parallel-orchestrator.sh` + `MAX_PARALLEL_SESSIONS=3`, the CTO, Engineer, and Reviewer each grab their own slot and **truly run in parallel**. With only 1 slot, they'd take turns — still useful for faster reaction time, but no actual parallelism.

### Across projects

If two projects are running (two tmux sessions), they share the same lock pool. With 3 slots, project A might hold slots 0 and 1 while project B uses slot 2 — they interleave naturally.

### Recommended setups

| Subscriptions | `MAX_PARALLEL_SESSIONS` | Setup |
|---|---|---|
| 1 | `1` (default) | Sequential orchestrator. Multiple projects take turns. |
| 2 | `2` | Parallel orchestrator for your main project, sequential for others. |
| 3 | `3` | Parallel orchestrator — all 3 agents run simultaneously. Or 3 projects each on sequential. |

### Example: 2 projects, 3 subscriptions

```bash
# In config.sh (global)
export MAX_PARALLEL_SESSIONS=3

# Start both projects — they share the 3 slots
./factory.sh --project schottentotten start    # uses parallel-orchestrator
./factory.sh --project my-saas-app start       # uses sequential orchestrator

# schottentotten grabs 2 slots (CTO + Engineer running simultaneously)
# my-saas-app grabs the 3rd slot when its turn comes
```

---

## File locations

| What | Where |
|---|---|
| Project config | `projects/<name>/config.sh` |
| Project state | `projects/<name>/state/` |
| Project logs | `projects/<name>/logs/` |
| Custom prompts | `projects/<name>/prompts/*.md` |
| Custom agents | `projects/<name>/agents/*.sh` |
| Base prompts | `prompts/*.md` |
| Base agents | `agents/*.sh` |
| Default project | `.current-project` or `$AI_AGENT_PROJECT` |
