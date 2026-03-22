# Function Micro-Analysis Example

This example demonstrates a complete micro-analysis following the Per-Function Microstructure Checklist. The pattern (authenticated HTTP handler that spawns a subprocess) is common across languages and frameworks.

---

## Target: `handleCreateSession(req, res)` — HTTP route handler that creates a new tmux session

**Purpose:**
Handles POST requests to create a new AI agent session. This is the primary entrypoint for spawning interactive terminal sessions — it validates user input, resolves a project directory, generates a unique session name, and delegates to tmux for process creation. It bridges untrusted HTTP input to privileged shell operations, making it a critical trust boundary in the system.

---

**Inputs & Assumptions:**

*Parameters:*
- `req` (HTTP request): Contains JSON body with `project`, `cmd`, `sessionName`. Source: network (untrusted).
- `res` (HTTP response): Output channel. Trusted (framework-provided).

*Implicit Inputs:*
- `DEV_DIR` (env/config): Base directory for projects. Assumed to be a valid, existing path set during setup.
- `loadSettings()` (function): Returns saved agent command preference. Assumed to return valid config or safe defaults.
- Active tmux sessions (system state): Queried to prevent name collisions. Assumed to reflect real tmux state.

*Preconditions:*
- Request has passed JWT auth middleware (L126-131 in server — `shouldAuthenticateApiPath` returns true for `/api/create`).
- Request body is valid JSON under 64KB (enforced by `parseBody`, L105-121 in http module).
- Rate limiter has not rejected this IP (L136-143 in server).

*Trust Assumptions:*
1. Auth middleware has already validated the JWT — this handler does NOT re-check authentication.
2. `DEV_DIR` was validated during setup and hasn't been tampered with since.
3. `isValidProjectName()` and `isValidSessionName()` correctly reject path traversal attempts.
4. `tmuxNewSession()` handles shell escaping for the command string.
5. The `project` field maps 1:1 to a directory name under `DEV_DIR` — no symbolic link resolution is performed here (but `validateProjectDir` does check symlinks).

---

**Outputs & Effects:**

*Returns (via HTTP response):*
- Success: `{ ok: true, session: "<name>" }` (200)
- Validation error: `{ error: "<message>" }` (400)
- Duplicate session: `{ error: "session exists", session: "<name>", hint: "..." }` (409)
- Directory not found: `{ error: "project directory not found" }` (404)

*State Writes:*
- New tmux session created (system-level side effect — persists beyond request lifecycle)
- `sessionDirMap` updated with session→directory mapping (in-memory server state)
- tmux session environment variable `WOLFPACK_PROJECT_DIR` set (persists in tmux)

*External Interactions:*
- `tmux new-session` subprocess spawned (privileged operation — runs shell commands)
- `tmux has-session` subprocess (duplicate check)
- `tmux set-option` subprocess (mouse mode)
- `tmux set-environment` subprocess (persist project dir)
- Filesystem: `mkdirSync` if `newProject` is set, `lstatSync`/`statSync`/`realpathSync` for validation

*Postconditions:*
- If success: exactly one new tmux session exists with the returned name, CWD set to project directory
- If error: no tmux session created, no state modified (atomic — all-or-nothing)
- Session name is unique across all existing tmux sessions at time of creation

---

**Block-by-Block Analysis:**

```
// L316-323: Parse and extract request body
const body = await parseBody(req, res);
if (!body) return;
const { project, newProject, cmd, sessionName } = body;
```
- **What:** Parses JSON body, destructures expected fields
- **Why here:** Must extract input before any validation
- **Assumptions:** `parseBody` has already enforced 64KB limit and valid JSON; returns null on failure (and sends 400 response)
- **Depends on:** `parseBody` handling malformed input and responding to client
- **First Principles:** Parse once at the boundary, then work with validated types — don't re-parse or trust raw strings downstream

---

```
// L325-326: Determine folder name from project or newProject
const folderName = newProject?.trim() || project?.trim();
if (!validateProject(res, folderName)) return;
```
- **What:** Resolves folder name (preferring newProject over project), validates it
- **Why here:** Must validate project name before using it in any path operations
- **Assumptions:** `validateProject` calls `isValidProjectName()` which rejects `..`, `.`, and non-alphanumeric characters. This is the ONLY defense against path traversal at this layer.
- **Invariant established:** After this point, `folderName` is safe to use in `join(DEV_DIR, folderName)` without path traversal risk
- **5 Whys:**
  - Why validate project name? → It's used to construct a filesystem path
  - Why is path traversal dangerous? → Could read/create sessions outside DEV_DIR
  - Why not just use realpath? → Need to validate the NAME before constructing the path at all
  - Why prefer newProject? → User is creating a new directory; existing project is fallback
  - Why trim? → Whitespace in directory names causes subtle bugs in shell commands

---

```
// L327-329: Validate command string
if (cmd && cmd !== "shell" && !CMD_REGEX.test(cmd)) {
  return json(res, { error: "invalid characters in command" }, 400);
}
```
- **What:** Validates the agent command against an allowlist regex
- **Why here:** Before any command reaches tmux — last chance to reject dangerous input
- **Assumptions:** `CMD_REGEX` (`/^[a-zA-Z0-9 \-._/=]+$/`) is sufficient to prevent command injection. This is a critical assumption — if bypass is possible, arbitrary commands execute in user's shell.
- **Invariant established:** `cmd` contains only safe characters for shell interpolation
- **5 Whys:**
  - Why regex validation? → cmd eventually reaches `shell -lic` via tmuxNewSession
  - Why not shell-escape instead? → Defense in depth: reject bad input AND escape downstream
  - Why allow `/` and `=`? → Agent commands like `claude --model=opus` need these
  - Why is "shell" special-cased? → It bypasses agent launch, just opens a terminal
  - Why not allowlist specific commands? → Users configure custom agent commands

---

```
// L340-346: Create project directory if new, validate directory exists
const projectDir = join(DEV_DIR, folderName);
if (newProject) {
  try { mkdirSync(projectDir, { recursive: true }); } catch {}
}
if (!validateProjectDir(res, projectDir)) return;
```
- **What:** Constructs full path, optionally creates directory, validates it exists and is safe
- **Why here:** Directory must exist before tmux session can use it as CWD
- **Assumptions:** `join(DEV_DIR, folderName)` is safe because `folderName` was validated above. `validateProjectDir` checks: not a symlink, is a directory, realpath resolves under DEV_DIR.
- **Depends on:** `folderName` validation from L326. If that check is bypassed, this join could resolve outside DEV_DIR.
- **Invariant established:** `projectDir` is a real directory under DEV_DIR, not a symlink, accessible
- **5 Hows:**
  - How to ensure path safety? → Validate name (L326), then validate resolved path (validateProjectDir)
  - How does validateProjectDir work? → Checks lstat (no symlink), stat (is directory), realpath (under DEV_DIR)
  - How to handle new projects? → mkdirSync with recursive:true, then validate like existing
  - How to prevent symlink attacks? → lstatSync detects symlinks before following them
  - How to prevent TOCTOU? → Minimal gap between validation and use; tmux create is next

---

```
// L347-356: Generate session name and create tmux session
const finalName = customName || await uniqueSessionName(folderName);
try {
  await tmuxNewSession(finalName, projectDir, cmd, loadSettings);
} catch (e) {
  if (e.code === "DUPLICATE_SESSION") {
    return json(res, { error: "session exists", session: finalName, hint: "reconnect or choose a different name" }, 409);
  }
  throw e;
}
json(res, { ok: true, session: finalName });
```
- **What:** Generates unique name, delegates to tmux for session creation, handles duplicate race
- **Why here:** All validation complete — this is the "do the thing" block
- **Assumptions:** `uniqueSessionName` queries live tmux state, but there's a TOCTOU window between name generation and `tmux new-session`. `tmuxNewSession` has its own `has-session` guard as defense-in-depth.
- **Depends on:** All prior validation (project name, directory, command). If any was skipped, this spawns a tmux session with unsafe parameters.
- **Risk:** Race condition — two concurrent requests could get the same unique name. `tmuxNewSession`'s `has-session` check catches this, but there's still a TOCTOU gap between `has-session` and `new-session` within tmux itself. In practice, unlikely due to single-threaded event loop + sequential tmux commands.
- **First Principles:** The function that creates external resources (tmux sessions) must handle the "already exists" case explicitly — can't assume uniqueness even after checking.
- **5 Whys:**
  - Why catch DUPLICATE_SESSION specifically? → Return 409 (Conflict) so client can reconnect instead of retry
  - Why re-throw other errors? → Unknown failures should bubble up to the 500 handler
  - Why provide a hint? → Client UI can show "reconnect" button instead of generic error
  - Why not just use the custom name directly? → Custom names need existence check; auto-names need uniqueness
  - Why is the TOCTOU acceptable? → Single-threaded server + tmux's own atomicity make collision extremely unlikely

---

**Cross-Function Dependencies:**

*Internal Calls:*
- `parseBody(req, res)` (http module): JSON parsing + size limit. Returns null and responds 400 on failure.
- `validateProject(res, project)` (routes module): Calls `isValidProjectName()` from validation module. Sends 400 on failure.
- `validateProjectDir(res, dir)` (routes module): Symlink check + realpath containment. Sends 400/404 on failure.
- `uniqueSessionName(folderName)` (http module): Calls `tmuxList()` to find unused name. Depends on live tmux state.
- `tmuxNewSession(name, cwd, cmd, loadSettings)` (tmux module): The actual session creation. See detailed analysis below.

*External Calls (Outbound):*
- `mkdirSync(projectDir, { recursive: true })`: Filesystem write. Risk: permission errors, disk full. Silent catch means failure is ignored — directory validation happens next anyway.
- `lstatSync`, `statSync`, `realpathSync` (via validateProjectDir): Filesystem reads. Risk: race condition if directory is modified between calls.
- `tmux new-session` (via tmuxNewSession → exec): Subprocess spawn. Risk: command injection if `cmd` validation is bypassed. Risk: resource exhaustion if sessions aren't cleaned up.

*Called By:*
- HTTP server route dispatcher (server/index.ts L146-147): Routes `POST /api/create` to this handler.
- Only reachable after auth middleware (L126-131) and rate limiting (L136-143).

*Shares State With:*
- `sessionDirMap` (tmux module): Written by `tmuxNewSession`. Read by `/api/sessions`, `/api/git-status`, `/api/ralph/*` routes. If this mapping is wrong, subsequent operations target the wrong directory.
- `prevPaneContent` (routes module): NOT written here, but the session name created here becomes a key in this map when `/api/sessions` polls it.
- `activePtySessions` (websocket module): NOT written here, but the session name created here becomes a key when a WebSocket client connects.

*Invariant Coupling:*
- **Path safety chain:** `isValidProjectName(folderName)` → `join(DEV_DIR, folderName)` → `validateProjectDir(realpath check)` → `tmuxNewSession(cwd)`. Breaking ANY link in this chain allows path traversal.
- **Session uniqueness:** `uniqueSessionName()` + `tmuxNewSession(has-session guard)` — double defense against duplicate sessions. Breaking uniqueSessionName alone doesn't cause duplicates (tmux guard catches it), but breaking tmux guard without uniqueSessionName causes 409 errors on legitimate requests.
- **Command safety chain:** `CMD_REGEX.test(cmd)` → `injectAgentContext(cmd)` → `shellEscape(fullCmd)` → `exec(TMUX, ["new-session", ..., shellCmd])`. The regex is defense-in-depth; shellEscape is the actual injection prevention.

*Assumptions Propagated to Callers:*
- Caller (HTTP client) must provide valid JSON body with `project` field
- Caller must have a valid JWT token (auth middleware enforced upstream)
- Caller should handle 409 responses by reconnecting to existing session
- Returned session name is the authoritative identifier for all subsequent API calls
