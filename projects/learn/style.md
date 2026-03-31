# Coding Style — auto-extracted from codebase
# Last updated: 2026-03-31 (rev 4)

## Naming

- **Files:** lowercase kebab-case for scripts and test files (e.g. `server-rate-limit.test.js`, `app-utils.test.js`, `obs-report.js`). PascalCase for React components (`App.jsx`, `Landing.jsx`).
- **Test files:** `tests/<subject>.test.js` — subject mirrors the module under test (e.g. `engine.test.js` tests `shared/engine.js`).
- **Hooks:** `use` prefix, PascalCase file in `src/hooks/` (e.g. `useWebSocket.js`).
- **Engine functions:** verb + noun, camelCase (`applyMove`, `applyClaim`, `applyPass`, `applyDrawChoice`, `declineClaim`, `createGameState`).
- **Server handlers:** `handle` prefix + action noun (`handleMove`, `handlePass`, `handleRecruiterConfirm`).
- **Event log keys:** snake_case strings (`"engine_error"`, `"connection_closed"`).
- **Cache maps:** `_xCache` (underscore-prefixed, module-level). Clear function: `clearXCache()`.

## Patterns

- **Discriminated union for `pendingAction`.** Shape: `{ type: "recruiter" | "scout" | ..., ...fields } | null`. All handlers must guard with `if (!pendingAction || pendingAction.type !== "<type>") return;` before accessing type-specific fields.

- **Pure function extraction + delegation.** Business logic that needs to be unit-tested is extracted as an exported pure function from `App.jsx`; the handler then delegates to it. The exported function is the single source of truth — never duplicate inline.

- **Optional `now` parameter for time-dependent functions.** Functions that call `Date.now()` accept `now = Date.now()` so tests can pass deterministic values.

- **Snapshot-rollback guard for stateful mutations.**
  ```js
  const snapshot = structuredClone(game.state);
  try {
    engineFn(game.state, ...args);
  } catch (err) {
    game.state = snapshot;
    logEvent("engine_error", { handler: "...", error: err.message, stack: err.stack });
    send(ws, { type: "error", message: "Action could not be applied." });
    return;
  }
  ```

- **Unknown-IP guard.** First line of every per-IP write function: `if (ip === "unknown") return;`.

- **WebSocket message shape.** Typed messages: `{ type: string, ...payload }`. Error responses: `{ type: "error", message: string }`.

- **Analytical helpers for formation evaluation.** One exported function per formation type (`flexColorRun`, `flexThreeKind`, etc.) that evaluates in O(1). No recursive variant walks — 3 jokers × 54 card variants = 157,464 paths. Established in `shared/engine.js` since commit `829944b`. When implementing memoization: guard with `if (best !== null)` before caching to avoid storing `null` for unrecognized cards; exclude mutable fields like `completedAt` from cache keys to prevent unbounded growth in MCTS workloads.

- **Idempotency guard before side effects.**
  ```js
  // Sync version
  function finalizeGame(game, winnerIndex) {
    if (game.completed) return;
    game.completed = true;
    // now safe to call side-effectful APIs
  }

  // Async version — flag MUST be set before first await
  async function recordMatchResult(game, winner) {
    if (game.completed) return;
    game.completed = true; // must be set before first await — acts as mutex in single-threaded JS
    await persistResult(game, winner);
  }
  ```
  Any function callable from multiple game-end paths (timeout, disconnect, normal end) uses this pattern. In async functions, the flag must come before the **first `await`** — Node.js's single-threaded event loop makes this a reliable mutex. Add the comment; future devs will assume it's redundant and remove it.

- **Module-level memoization with FIFO size cap and clear hook.**
  ```js
  const FORMATION_CACHE_MAX = 10_000;
  const _formationCache = new Map();
  export function clearFormationCache() { _formationCache.clear(); }

  // in the function:
  const key = cards.map(c => c.id).sort().join(",");
  if (_formationCache.has(key)) return _formationCache.get(key);
  if (_formationCache.size >= FORMATION_CACHE_MAX) {
    _formationCache.delete(_formationCache.keys().next().value); // evict oldest (FIFO)
  }
  const result = expensiveCompute(cards);
  _formationCache.set(key, result);
  return result;
  ```
  Use FIFO single-entry eviction (not bulk `_cache.clear()`) — bulk eviction discards all warm entries and causes a cold-cache spike. Map guarantees insertion-order iteration so `.keys().next().value` is always the oldest entry.

- **WebSocket close handler: attach closure vars to `ws` at connection time.**
  ```js
  ws.on("connection", (ws, req) => {
    const ip = getIp(req);
    ws.ip = ip; // ← attach at connection time
    ws.on("close", () => {
      connectionsByIp.delete(ws.ip); // ← use ws.ip, not ip
    });
  });
  ```
  Robust against transpiler quirks and conditional handler registration.

## Testing

- **Framework:** Vitest (`vitest run`). Config in `vite.config.js` or `vitest.config.js`.
- **Test location:** `tests/` at project root. No co-located test files.
- **Mocking React deps:** Use `vi.mock(...)` for heavy dependencies (`mcts.js`, `ai-policy.js`, `Landing.jsx`, `i18n.js`) when testing pure exports from `App.jsx`.
- **WebSocket hook testing:** Module-scoped `lastInstance` captures the socket; lifecycle driven by calling `lastInstance.onopen?.()` etc. directly. Reference: `tests/use-websocket.test.js`.
- **Server logic testing:** Inline logic under test in the test file; never import `server/index.js`.
- **Pure function testing:** Pass deterministic `now` values to time-dependent functions instead of `vi.useFakeTimers()`.
- **Cache isolation:** Call `clearXCache()` in `afterEach` for any test file exercising a memoized function.
- **Card-move assertions:** Assert specific card IDs at source and destination — `hand.length` assertions alone are insufficient.
- **Test drain helper for variant initial state.**
  ```js
  function makeTacticsState() {
    const state = createGame({ variant: "tactics" });
    // tactics always starts with pendingClaim: { player: 0 }
    // must drain before any applyMove or the guard blocks all moves
    declineClaim(state);
    return state;
  }
  ```
- **Known pre-existing failures:** `tests/app-utils.test.js` has 14 failing tests (`localStorage.clear is not a function`) predating recent work — do not treat as regressions from unrelated changes.

## Architecture

- **Frontend:** React 18 SPA, Vite build, single-file component (`src/App.jsx`). PWA via `registerSW.js`.
- **Shared logic:** `shared/` contains pure JS modules (`engine.js`, `mcts.js`, `ai-policy.js`) used by both client and server. No React or Node-specific APIs here.
- **Server:** Node.js WebSocket server (`server/index.js`), standalone with its own `server/package.json`. `engines.node >= 17` (uses `structuredClone` natively).
- **Infrastructure:** Per-environment Terraform in `infra/terraform/<env>/`. Environments: `staging`, `app` (prod), `bootstrap`, `pwa`. Each has its own state backend and IAM role.
- **CI/CD:** `.github/workflows/ci.yml` (test), `.github/workflows/deploy.yml` (deploy). Deploy targets `main` branch → prod, `staging` branch → staging.
- **AI worker:** `src/ai.worker.js` runs MCTS in a Web Worker off the main thread. Do not `structuredClone` data before passing to `worker.postMessage` — `postMessage` clones synchronously.
