# AI Agent Factory

A multi-agent development pipeline powered by Claude Code Max, where specialized AI agents collaborate via GitHub Discussions to autonomously develop, review, and ship code.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  GitHub Discussions                   │
│              (Agent Communication Forum)              │
│                                                       │
│  📋 #triage    💬 #engineering    🔍 #code-review    │
│  📢 #announce  🐛 #bugs          📊 #daily-standup  │
└──────────────┬────────────────────┬──────────────────┘
               │                    │
    ┌──────────▼──────────┐  ┌─────▼──────────┐
    │    🎯 CTO Agent     │  │  👷 Sr Engineer │
    │                     │  │                 │
    │ - Triages issues    │  │ - Implements    │
    │ - Assigns work      │  │ - Opens PRs     │
    │ - Decides deploys   │  │ - Fixes bugs    │
    │ - Writes specs      │  │ - Writes tests  │
    └─────────────────────┘  └─────────────────┘
               │                    │
    ┌──────────▼──────────────────────────────┐
    │         🔎 Code Reviewer Agent          │
    │                                          │
    │ - Reviews PRs                            │
    │ - Checks quality, security, performance  │
    │ - Approves or requests changes           │
    └──────────────────────────────────────────┘

    ┌──────────────────────────────────────────┐
    │         🤖 Orchestrator (cron)           │
    │                                          │
    │ - Polls GitHub Discussions               │
    │ - Dispatches agents based on messages    │
    │ - Manages agent lifecycle                │
    │ - Enforces rate limits                   │
    └──────────────────────────────────────────┘
```

## Setup

1. Run `./setup.sh` to create the GitHub repo and enable Discussions
2. Set your `GITHUB_TOKEN` in `.env`
3. Configure your target project path in `config.sh`
4. Run `./orchestrator.sh` to start the agent loop

## How it works

Each agent is a Claude Code headless session with a specialized system prompt.
They communicate asynchronously via GitHub Discussions:
- An agent posts a message (e.g., CTO posts a task)
- The orchestrator polls for new messages
- It dispatches the relevant agent to handle the message
- The agent does its work and posts the result back

This creates a self-sustaining development loop.
