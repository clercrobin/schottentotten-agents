---
name: next-session-brief
description: What to build next — event-driven orchestration for ai-agent-factory
type: project
---

## Next Session: Event-Driven Orchestration Rewrite

### Current State (2026-04-01)
- Stateful rewrite DONE: state/features/*.json works, plans on disk work
- PM → Planner → CTO → Engineer → Reviewer tested end-to-end on #505
- PR #37 created and reviewed autonomously
- 56 unpushed commits on ai-agent-factory main

### Problem
Factory takes 300 min for a 15 min task because:
1. 30s sleep between cycles — agents wait instead of handing off immediately
2. One agent per cycle — rigid loop, not event-driven
3. Each agent re-reads everything from scratch
4. 5 sequential Claude sessions at 3-7 min each

### What to Build
1. **Event-driven dispatch**: agent finishes → writes state → IMMEDIATELY triggers next agent. No sleep, no polling.
2. **Pipeline mode**: planner → CTO → engineer in one continuous flow when possible
3. **Code context passing**: agents share the actual code diff, not summaries
4. **Persistent state in repo**: state/ dir (not /tmp), works across restarts
5. **Overnight autonomous**: normal mode scans, discovers, plans, builds, reviews without human input
6. **Target**: 15 min idea-to-PR

### Reference
- https://github.com/moazbuilds/CodeMachine-CLI — state management and orchestration patterns
- Compound Engineering plugin — workflow commands

### Key Files
- orchestrator.sh — needs event-driven rewrite
- lib/feature-state.sh — works, may need pipeline status additions
- agents/*.sh — work with stateful approach, need faster handoff
- state/features/*.json — the source of truth (keep)
- docs/plans/*.md — plans on disk (keep)

### Schottentotten Status
- Prod: ✅ healthy at schottentotten.com
- Staging: ✅ healthy, PR #37 (card design) merged
- Open: Discussion #505 (Rework Card design) — reviewed, ready to ship
- 56 unpushed commits on ai-agent-factory — push before starting
