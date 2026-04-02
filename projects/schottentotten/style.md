# Coding Style — auto-extracted from codebase
# Last updated: 2026-04-02

## Naming

- **Files**: `kebab-case` for multi-word files (`app-utils.test.js`, `engine-utils.test.js`). React components use `PascalCase.jsx` (`App.jsx`, `Landing.jsx`). Shared logic uses lowercase (`engine.js`, `mcts.js`).
- **Test files**: `<subject>.test.js` in the top-level `tests/` directory, not co-located with source.
- **Custom hooks**: `useXxx.js` in `src/hooks/` (e.g. `useWebSocket.js`). Note: `src/hooks/` is referenced in solution docs but not yet present in `staging` — check `main` before creating it again.
- **Cache variables**: `_xCache` (underscore prefix for module-private Maps). Exported clear function: `clearXCache()`.
- **Handlers**: `handleXxx` convention (e.g. `handleRecruiterConfirm`, `handleMove`).
- **Test helpers**: descriptive factory names like `makeTacticsState()`.

## Patterns

- **Pure function extraction with explicit inputs**: Business logic that's hard to test inside a React closure is extracted as exported pure functions from `App.jsx`. The live handler delegates to the export — it does not duplicate logic inline.
- **Discriminated union guards**: Every handler that reads type-specific fields from `pendingAction` starts with `if (!pendingAction || pendingAction.type !== "<type>") return;`.
- **Snapshot-rollback for mutations**: Engine mutation calls in `server/index.js` are wrapped in `structuredClone` snapshot + try/catch + rollback.
- **Idempotency flag**: Functions callable from multiple termination paths set a `completed` boolean synchronously on the game object before any side effects.
- **Module-level memoization (caches)**: Expensive pure computations use a module-scoped `Map` with a FIFO size cap and an exported `clear()` function for test isolation.
- **Module-level state Maps (security/connections)**: Maps tracking live server state (`ipStrikes`, `connectionsByIp`) use TTL-based eviction in the 30s `setInterval` cleanup loop — not size caps. These are not caches; their entries represent real in-flight state.
- **WebSocket state attachment**: Values needed in close handlers are attached to the `ws` object at connection time (e.g. `ws.ip = ip`), not captured from closure variables.
- **Optional `now` parameter**: Functions with `Date.now()` calls accept `now = Date.now()` as an optional trailing parameter for deterministic testing without fake timers.
- **Env-configurable server constants**: All rate-limit and server capacity constants are read from `process.env` with hard-coded defaults (e.g. `Number(process.env.WS_RATE_MAX_STRIKES || 3)`). Never hard-code these values inline.

## Testing

- **Framework**: Vitest with jsdom environment.
- **Setup file**: `tests/setup.js` installs a complete `localStorage` mock (`getItem`, `setItem`, `removeItem`, `clear`, `key`, `length`) via `Object.defineProperty` with `configurable: true`, reset per `beforeEach`. Registered via `setupFiles` in `vitest.config.js`.
- **Coverage threshold**: 80% statements/branches/functions/lines globally; 85% for `shared/engine.js`. Enforced in CI.
- **WebSocket hook testing**: Use a module-scoped `MockWebSocket` class that captures `lastInstance` and exposes `onopen`/`onclose`/`onmessage` for direct invocation.
- **Card-move assertions**: Must assert specific card IDs moved (not just counts) — see `recruiterDrawChoiceReducer` tests.
- **Boundary tests**: Off-by-one fixes always include a `length - 1` (valid) test and a `length` (throws) test.
- **Tactics drain pattern**: `makeTacticsState()` calls `declineClaim(state)` after `createGame({ variant: "tactics" })` — mandatory because the variant always starts with a blocking `pendingClaim`.
- **Exported functions for direct testing**: Server-side helpers like `finalizeGame` should be exported so tests exercise the real function, not a replica.
- **Replica test files**: When a server function cannot be exported (e.g. `connectionsByIp` tracking), tests may replicate the logic in-process. The replica file must open with an explicit "Replicates X from server/index.js — update if that logic changes" comment. See `tests/server-ws-ip.test.js`.
- **vi.mock heavy deps for App.jsx tests**: `tests/app-utils.test.js` is the canonical example — always mock `../shared/mcts.js`, `../shared/ai-policy.js`, `../shared/engine.js`, `../src/Landing.jsx`, and `../src/i18n.js` to prevent import-time side effects from executing in unit tests.
- **Node.js 25 `localStorage` regression**: Node.js 25's native `localStorage` global (from `--experimental-webstorage`) overrides jsdom's stub but omits `clear()`. The `tests/setup.js` mock handles this. Add `NODE_NO_WARNINGS=1` to the `test` npm script to suppress the harmless `--localstorage-file was provided without a valid path` warning if running on Node 25+.

## Architecture

- **`src/`** — React SPA frontend: `App.jsx` (main component, ~3600 lines), `Landing.jsx`, hooks in `src/hooks/`, worker in `ai.worker.js`.
- **`server/`** — Node.js WebSocket server (`server/index.js`). Wires engine functions. Handles connection lifecycle, message routing, rate limiting, and IP ban tracking.
- **`shared/`** — Pure game engine (`shared/engine.js`) and MCTS AI (`shared/mcts.js`, `shared/ai-policy.js`). No framework dependencies. Used by both client and server.
- **`tests/`** — All unit tests. Not co-located with source. One test file per module subject area.
- **`scripts/`** — Observability and AI training helpers: `obs-report.js` (log parsing), `selfplay.js` / `metrics-selfplay.js` / `validate-selfplay.js` (AI self-play pipeline), `build-policy.js`. `obs-report.js` has unit tests in `tests/obs-report.test.js`.
- **`e2e/`** — Playwright smoke tests (`e2e/smoke.spec.js`). Excluded from Vitest.
- **`infra/terraform/`** — One subdirectory per environment (`staging/`, `app/`, `pwa/`, `bootstrap/`). Each has its own Terraform state.
- **Module system**: `"type": "module"` — everything is ESM. No CommonJS.
- **Build**: Vite for frontend; server runs directly under Node.js >= 17.
- **No TypeScript**: Plain JavaScript throughout. No JSDoc type annotations added without a specific reason.
