#!/usr/bin/env bash
set -uo pipefail

# Regression harness for the v2 explicit per-module build refactor.
# See BUILD_REGRESSION_PLAN.md.
#
# Usage:
#   run-regression.sh --commit <sha> --repo curl|redis [--attempts 3] [--smoke]
#
# Per repo per attempt: runs `/edc:edc-build` once on the target repo using the
# EDC plugin AT --commit, snapshots edc-context/, then runs `/edc:edc-review` per
# CVE in cve-lists.conf on top of that snapshot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"

WORK_DIR="${EDC_REG_WORKDIR:-/private/tmp/edc-bench-regression}"
# Single-knob default — used by harness as the "model" label in OUT_DIR and as
# the outer claude -p --model. For per-phase splits (e.g. build=sonnet,
# review=haiku), set EDC_BUILD_MODEL / EDC_REVIEW_MODEL explicitly and set
# EDC_RUN_LABEL to a descriptive dirname (e.g. "build-sonnet-review-haiku").
MODEL="${EDC_BENCH_MODEL:-haiku}"
# Phase 0 (F1): propagate model into edc_spawn via per-phase env vars so the
# spawned child claude/cursor/codex actually receives --model. Bench harness
# always resolves explicitly so the interactive prompt path in `edc` never
# triggers under CI / non-tty runs.
export EDC_BUILD_MODEL="${EDC_BUILD_MODEL:-$MODEL}"
export EDC_REVIEW_MODEL="${EDC_REVIEW_MODEL:-$MODEL}"
# Outer claude -p --model: the bench's top-level claude that shells out to
# edc-build.sh. It doesn't do real work (4-7 turns) so this matters little;
# default to the build model since build is the longer phase.
OUTER_MODEL="${EDC_OUTER_MODEL:-$EDC_BUILD_MODEL}"
# Label used to name OUT_DIR's model subdir. Defaults to the single-knob MODEL
# (e.g. "haiku"); override for split-model runs (e.g. "build-sonnet-review-haiku").
RUN_LABEL="${EDC_RUN_LABEL:-$MODEL}"
# Phase 0 observability: preserve every edc_spawn transcript for post-hoc
# analysis with edc-spawn-analyze.sh. Transcripts go under each run_dir's
# edc-context/build/transcripts/ by default; we explicitly point them at our
# per-attempt output dir so attempts don't collide.
export EDC_PRESERVE_TRANSCRIPTS="${EDC_PRESERVE_TRANSCRIPTS:-1}"
# CLAUDE_CODE_SUBAGENT_MODEL is set per-phase by edc_spawn (build phase →
# EDC_BUILD_MODEL, review phase → EDC_REVIEW_MODEL) via --settings inline
# JSON, so we don't export a single fixed value here. The outer claude -p
# below (the bench's own top-level invocation) still inherits the user's
# global ~/.claude/settings.json for its own Task tool, but in practice the
# outer claude doesn't fan out — it only shells out. Leaving this unset
# means the outer's Task tool (if any) inherits the global setting, which
# is acceptable since no real subagent work happens at that layer.
MODE="${EDC_REG_MODE:-v2}"
BUILD_TIMEOUT="${EDC_REG_BUILD_TIMEOUT:-1800}"
REVIEW_TIMEOUT="${EDC_REG_REVIEW_TIMEOUT:-600}"
BUILD_TURNS="${EDC_REG_BUILD_TURNS:-100}"
REVIEW_TURNS="${EDC_REG_REVIEW_TURNS:-25}"
V1_BUILD_TURNS="${EDC_REG_V1_BUILD_TURNS:-30}"
V1_BUILD_TIMEOUT="${EDC_REG_V1_BUILD_TIMEOUT:-600}"

COMMIT=""
REPO=""
ATTEMPTS=3
SMOKE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)   COMMIT="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --smoke)    SMOKE=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

[[ "$MODE" == "v1" || "$MODE" == "v2" || "$MODE" == "v2-per-cve" ]] || { echo "--mode must be v1, v2, or v2-per-cve" >&2; exit 64; }

[[ -z "$COMMIT" ]] && { echo "--commit required" >&2; exit 64; }
[[ -z "$REPO" ]]   && { echo "--repo required" >&2; exit 64; }

# Resolve commit to a full SHA (so worktree path is stable)
COMMIT_SHA=$(git -C "$REPO_ROOT" rev-parse "$COMMIT" 2>/dev/null) || {
  echo "could not resolve commit: $COMMIT" >&2; exit 1
}
SHORT_SHA="${COMMIT_SHA:0:10}"

REPO_BENCH_DIR="$BENCH_DIR/$REPO"
[[ -f "$REPO_BENCH_DIR/repo.conf" ]] || { echo "no repo.conf for $REPO" >&2; exit 1; }
[[ -f "$REPO_BENCH_DIR/cve-lists.conf" ]] || { echo "no cve-lists.conf for $REPO" >&2; exit 1; }
[[ -f "$REPO_BENCH_DIR/ground-truth.md" ]] || { echo "no ground-truth.md for $REPO" >&2; exit 1; }

REPO_URL=$(awk -F= '$1=="repo_url"{print $2}' "$REPO_BENCH_DIR/repo.conf")
[[ -z "$REPO_URL" ]] && { echo "no repo_url in $REPO/repo.conf" >&2; exit 1; }

# Load CVE list — for the regression we score every CVE (fast + regression)
FAST_CVES=()
REGRESSION_CVES=()
source "$REPO_BENCH_DIR/cve-lists.conf"
ALL_CVES=("${FAST_CVES[@]}" "${REGRESSION_CVES[@]}")

if [[ -n "${EDC_REG_ONLY_CVES:-}" ]]; then
  IFS=',' read -ra ALL_CVES <<< "$EDC_REG_ONLY_CVES"
  echo "[only] running ${#ALL_CVES[@]} CVE(s): ${ALL_CVES[*]}"
fi

if $SMOKE; then
  ALL_CVES=("${ALL_CVES[0]}")
  ATTEMPTS=1
  echo "[smoke] one CVE, one attempt: ${ALL_CVES[0]}"
fi

# ── Output paths ───────────────────────────────────────────────────────────
OUT_DIR="$BENCH_DIR/regression/results/${SHORT_SHA}/${MODE}/${RUN_LABEL}/${REPO}"
mkdir -p "$OUT_DIR"
LOGFILE="$OUT_DIR/run.log"
BUILD_TSV="$OUT_DIR/build-metrics.tsv"
REVIEW_TSV="$OUT_DIR/review-metrics.tsv"
SCORE_TSV="$OUT_DIR/review-results.tsv"

[[ -f "$BUILD_TSV" ]] || printf 'repo\tcommit\tattempt\tduration_s\tnum_turns\tin_tokens\tout_tokens\tcache_read\tcache_create\ttotal_cost_usd\tmodule_count\tindex_lines\tstatus\n' > "$BUILD_TSV"
[[ -f "$REVIEW_TSV" ]] || printf 'repo\tcommit\tcve\tattempt\tduration_s\tnum_turns\tin_tokens\tout_tokens\tcache_read\tcache_create\ttotal_cost_usd\tstatus\n' > "$REVIEW_TSV"
[[ -f "$SCORE_TSV" ]] || printf 'timestamp\tcve\tcategory\tseverity\tfound\tconfidence\tduration\tnotes\n' > "$SCORE_TSV"

log() {
  local m="[$(date '+%H:%M:%S')] $*"
  echo "$m" | tee -a "$LOGFILE"
}

# ── Worktree the EDC plugin AT $COMMIT_SHA ─────────────────────────────────
EDC_WT="$WORK_DIR/edc-worktree-$SHORT_SHA"
if [[ ! -d "$EDC_WT/plugins/edc" ]]; then
  log "creating EDC worktree at $COMMIT_SHA → $EDC_WT"
  mkdir -p "$WORK_DIR"
  rm -rf "$EDC_WT"
  git -C "$REPO_ROOT" worktree add --detach "$EDC_WT" "$COMMIT_SHA" >/dev/null
fi
PLUGIN_DIR="$EDC_WT/plugins/edc"
[[ -d "$PLUGIN_DIR" ]] || { echo "no plugins/edc at $COMMIT_SHA" >&2; exit 1; }

# ── Clone target repo (shared) ─────────────────────────────────────────────
TARGET_REPO_DIR="$WORK_DIR/repos/$REPO"
if ! git -C "$TARGET_REPO_DIR" rev-parse HEAD >/dev/null 2>&1; then
  log "cloning $REPO from $REPO_URL"
  rm -rf "$TARGET_REPO_DIR"
  mkdir -p "$(dirname "$TARGET_REPO_DIR")"
  git clone --quiet "$REPO_URL" "$TARGET_REPO_DIR"
fi

# ── Build commit selection: most recent fix_commit~1 across CVE list ──────
# Pick the CVE whose fix_commit is most recent in main; build context at that fix~1.
pick_build_commit() {
  local newest_sha="" newest_ts=0
  for cve in "${ALL_CVES[@]}"; do
    local info fix
    info=$(python3 "$BENCH_DIR/parse_gt.py" "$REPO_BENCH_DIR/ground-truth.md" | grep "^$cve|") || continue
    fix=$(echo "$info" | cut -d'|' -f2)
    [[ -z "$fix" ]] && continue
    local ts
    ts=$(git -C "$TARGET_REPO_DIR" show -s --format=%ct "$fix" 2>/dev/null) || continue
    if [[ "$ts" -gt "$newest_ts" ]]; then
      newest_ts="$ts"
      newest_sha="$fix"
    fi
  done
  [[ -z "$newest_sha" ]] && { echo "could not pick build commit" >&2; return 1; }
  echo "${newest_sha}~1"
}

BUILD_COMMIT=$(pick_build_commit) || exit 1
log "build commit (target repo): $BUILD_COMMIT"

# ── Run claude with watchdog and parse metrics from stream-json ───────────
# args: <run_dir> <prompt> <max_turns> <timeout_s> <metrics_var_prefix>
# Writes claude-output.txt in $run_dir; sets METRICS array via temp file.
run_claude() {
  local run_dir="$1" prompt="$2" max_turns="$3" timeout="$4" allowed_tools="${5:-}"
  mkdir -p "$run_dir"
  local out="$run_dir/claude-output.txt"
  local t0=$(date +%s)
  local tools_arg=()
  [[ -n "$allowed_tools" ]] && tools_arg=(--allowedTools "$allowed_tools")

  (cd "$run_dir" && exec claude -p "$prompt" \
      --plugin-dir "$PLUGIN_DIR" \
      --max-turns "$max_turns" \
      --model "$OUTER_MODEL" \
      "${tools_arg[@]}" \
      --output-format stream-json --verbose \
      --dangerously-skip-permissions) \
      < /dev/null > "$out" 2>&1 &
  local pid=$!
  ( sleep "$timeout" \
      && kill "$pid" 2>/dev/null \
      && pkill -TERM -P "$pid" 2>/dev/null \
      ; sleep 5 \
      ; kill -9 "$pid" 2>/dev/null \
      ; pkill -KILL -P "$pid" 2>/dev/null \
  ) &
  local wd=$!
  wait "$pid" 2>/dev/null || true
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true

  RUN_DURATION=$(( $(date +%s) - t0 ))
  RUN_IN=0; RUN_OUT=0; RUN_CACHE_R=0; RUN_CACHE_C=0; RUN_COST=0; RUN_TURNS=0
  if [[ -s "$out" ]]; then
    local rl
    rl=$(grep -m1 '"type":"result"' "$out" 2>/dev/null | tail -1)
    if [[ -n "$rl" ]]; then
      RUN_IN=$(printf '%s' "$rl" | jq -r '.usage.input_tokens // 0')
      RUN_OUT=$(printf '%s' "$rl" | jq -r '.usage.output_tokens // 0')
      RUN_CACHE_R=$(printf '%s' "$rl" | jq -r '.usage.cache_read_input_tokens // 0')
      RUN_CACHE_C=$(printf '%s' "$rl" | jq -r '.usage.cache_creation_input_tokens // 0')
      RUN_COST=$(printf '%s' "$rl" | jq -r '.total_cost_usd // 0')
      RUN_TURNS=$(printf '%s' "$rl" | jq -r '.num_turns // 0')
    fi
  fi
}

# ── Build phase ────────────────────────────────────────────────────────────
# v1 has no per-repo build; per-CVE context is built inline by review_one_cve.
build_one_attempt() {
  local attempt="$1"
  if [[ "$MODE" == "v1" || "$MODE" == "v2-per-cve" ]]; then
    log "[build] $MODE mode — per-repo build skipped (per-CVE build inline)"
    return 0
  fi
  local cache_dir="$WORK_DIR/cache/$SHORT_SHA/$MODE/$RUN_LABEL/$REPO/attempt-$attempt"
  if [[ -d "$cache_dir/edc-context" ]] && [[ -f "$cache_dir/edc-context/manifest.json" ]]; then
    log "[build] attempt $attempt cached → $cache_dir"
    return 0
  fi

  local run_dir="$WORK_DIR/builds/$SHORT_SHA/$MODE/$RUN_LABEL/$REPO/attempt-$attempt"
  rm -rf "$run_dir"
  mkdir -p "$run_dir"

  log "[build] attempt $attempt — checking out target repo at $BUILD_COMMIT"
  # Copy a clean checkout of the target repo into run_dir
  git -C "$TARGET_REPO_DIR" worktree add --quiet --detach "$run_dir/src" "$BUILD_COMMIT" 2>/dev/null || {
    rm -rf "$run_dir/src"
    git clone --quiet --no-local "$TARGET_REPO_DIR" "$run_dir/src"
    git -C "$run_dir/src" checkout --quiet --detach "$BUILD_COMMIT"
  }
  rm -rf "$run_dir/src/edc-context"

  # Run edc-build.sh DIRECTLY (no outer claude wrapper).
  #
  # Why: claude code's Bash tool auto-backgrounds any command with
  # timeout > 600000ms. The build legitimately takes 15-30 min, so the
  # outer Bash call always gets backgrounded. After backgrounding, haiku
  # polls TaskOutput indefinitely — even after the inner build's edc-doctor
  # already finished and exited. The outer wrapper has no work to do beyond
  # invoking the script and surfacing its output, so we drop it. The bench
  # writes a synthetic claude-output.txt so downstream parsers (which look
  # for a `"type":"result"` line) still find what they need.
  log "[build] attempt $attempt — invoking edc-build.sh directly (build=$EDC_BUILD_MODEL, review=$EDC_REVIEW_MODEL, label=$RUN_LABEL, timeout=${BUILD_TIMEOUT}s)"
  local out="$run_dir/src/claude-output.txt"
  local t0=$(date +%s)
  pushd "$run_dir/src" >/dev/null
  ( EDC_AGENT_CLI=claude bash "$EDC_WT/plugins/edc/scripts/edc-build.sh" --force ) \
    < /dev/null > "$out" 2>&1 &
  local pid=$!
  ( sleep "$BUILD_TIMEOUT" \
      && kill "$pid" 2>/dev/null \
      && pkill -TERM -P "$pid" 2>/dev/null \
      ; sleep 5 \
      ; kill -9 "$pid" 2>/dev/null \
      ; pkill -KILL -P "$pid" 2>/dev/null \
  ) &
  local wd=$!
  wait "$pid" 2>/dev/null || true
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  popd >/dev/null

  RUN_DURATION=$(( $(date +%s) - t0 ))
  # Outer-shell metrics aren't applicable here — the real cost is in the
  # inner edc_spawn child(ren), captured in spawn-log.jsonl. Zero out the
  # outer fields so the build-metrics.tsv row stays consistent in shape.
  RUN_IN=0; RUN_OUT=0; RUN_CACHE_R=0; RUN_CACHE_C=0; RUN_COST=0; RUN_TURNS=0
  # Pull the real cost from spawn-log.jsonl if present (sum across all
  # spawns this build produced).
  local spawn_log="$run_dir/src/edc-context/build/spawn-log.jsonl"
  if [[ -s "$spawn_log" ]] && command -v jq >/dev/null 2>&1; then
    RUN_COST=$(jq -s 'map(.total_cost_usd // 0) | add' "$spawn_log" 2>/dev/null)
    RUN_IN=$(jq -s 'map(.input_tokens // 0) | add' "$spawn_log" 2>/dev/null)
    RUN_OUT=$(jq -s 'map(.output_tokens // 0) | add' "$spawn_log" 2>/dev/null)
    RUN_CACHE_R=$(jq -s 'map(.cache_read_tokens // 0) | add' "$spawn_log" 2>/dev/null)
    RUN_CACHE_C=$(jq -s 'map(.cache_write_tokens // 0) | add' "$spawn_log" 2>/dev/null)
    RUN_TURNS=$(jq -s 'map(.num_turns // 0) | add' "$spawn_log" 2>/dev/null)
  fi

  # The build skill sometimes writes edc-context to $run_dir/src (correct) and
  # sometimes to $run_dir (one level up — observed on redis). Accept either.
  local status="ok"
  local module_count=0 index_lines=0
  local found_ctx=""
  for candidate in "$run_dir/src/edc-context" "$run_dir/edc-context"; do
    [[ -d "$candidate" ]] && [[ -f "$candidate/manifest.json" ]] && { found_ctx="$candidate"; break; }
  done
  if [[ -n "$found_ctx" ]]; then
    module_count=$(ls "$found_ctx/modules" 2>/dev/null | wc -l | xargs)
    [[ -f "$found_ctx/index.md" ]] && index_lines=$(wc -l < "$found_ctx/index.md" | xargs)
    if [[ "$module_count" -gt 0 ]]; then
      mkdir -p "$cache_dir"
      cp -R "$found_ctx" "$cache_dir/"
      status="ok"
    else
      status="incomplete"
    fi
  else
    status="no-context-dir"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$REPO" "$SHORT_SHA" "$attempt" "$RUN_DURATION" "$RUN_TURNS" \
    "$RUN_IN" "$RUN_OUT" "$RUN_CACHE_R" "$RUN_CACHE_C" "$RUN_COST" \
    "$module_count" "$index_lines" "$status" >> "$BUILD_TSV"

  log "[build] attempt $attempt — $status (${RUN_DURATION}s, modules=$module_count, cost=\$$RUN_COST)"

  # Free the worktree only on success — keep failure debris for diagnosis.
  if [[ "$status" == "ok" ]]; then
    git -C "$TARGET_REPO_DIR" worktree remove --force "$run_dir/src" 2>/dev/null || true
  fi

  [[ "$status" == "ok" ]]
}

# ── Review phase ───────────────────────────────────────────────────────────
review_one_cve() {
  local attempt="$1" cve="$2"
  local info
  info=$(python3 "$BENCH_DIR/parse_gt.py" "$REPO_BENCH_DIR/ground-truth.md" | grep "^$cve|") || {
    log "[review] $cve not in ground truth — skip"; return 1;
  }
  IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern description <<< "$info"

  local run_dir="$WORK_DIR/reviews/$SHORT_SHA/$MODE/$RUN_LABEL/$REPO/$cve/attempt-$attempt"
  rm -rf "$run_dir"
  mkdir -p "$(dirname "$run_dir")"

  git -C "$TARGET_REPO_DIR" worktree add --quiet --detach "$run_dir" "${fix_commit}~1" 2>/dev/null || {
    rm -rf "$run_dir"
    git clone --quiet --no-local "$TARGET_REPO_DIR" "$run_dir"
    git -C "$run_dir" checkout --quiet --detach "${fix_commit}~1"
  }
  rm -rf "$run_dir/edc-context"

  local file_list=""
  IFS=',' read -ra files <<< "$affected_files"
  for f in "${files[@]}"; do
    f="$(echo "$f" | xargs)"
    if [[ "$MODE" == "v1" ]]; then
      file_list+=" $(basename "$f")"
    else
      file_list+=" $f"
    fi
  done

  local prompt
  if [[ "$MODE" == "v2" ]]; then
    local cache_dir="$WORK_DIR/cache/$SHORT_SHA/$MODE/$RUN_LABEL/$REPO/attempt-$attempt"
    [[ -d "$cache_dir/edc-context" ]] || { log "[review] no cached context for attempt $attempt — skip $cve"; return 1; }
    cp -R "$cache_dir/edc-context" "$run_dir/edc-context"

    prompt="Pre-built v2 architectural context exists under edc-context/ (index.md, manifest.json, modules/*.md). Read edc-context/index.md first, then drill into the relevant module(s) under edc-context/modules/.

Perform a FULL-FILE security review of these source files:$file_list

Use the edc:edc-review skill. Treat this as full-file analysis (ignore any diff/PR-only language in the skill).

Write ALL findings to edc-context/reports/issues.md with: title, severity, category, file:line, description, evidence."
  else
    # v1 / v2-per-cve: build per-CVE context first, then review.
    mkdir -p "$run_dir/edc-context/modules"
    local v1_prompt
    if [[ "$MODE" == "v1" ]]; then
      v1_prompt="Run the edc:edc-context skill on these files:$file_list

Build complete architectural context. Write the full analysis to edc-context/full-context.md.
This step is pure architectural context building only — do NOT identify security vulnerabilities."
    else
      # v2-per-cve: mirrors edc-build-plan.sh's per-module prompt verbatim,
      # but with a single synthetic module = the CVE's affected files.
      v1_prompt="Build deep architectural context for module \`target\`. Files in scope: \`${affected_files}\`. Invoke the \`edc-context\` skill on these files. You may read sibling-module source if it materially improves this module's context. Write the deep doc directly to \`edc-context/modules/target.md\`. Return a ≤500-token summary for the orchestrator."
    fi

    local v1_tools=""
    [[ "$MODE" == "v1" ]] && v1_tools="Read Glob Grep Write Skill"
    log "[$MODE-build] $cve attempt $attempt — claude invoking (turns=$V1_BUILD_TURNS, timeout=${V1_BUILD_TIMEOUT}s)"
    pushd "$run_dir" >/dev/null
    run_claude "$run_dir" "$v1_prompt" "$V1_BUILD_TURNS" "$V1_BUILD_TIMEOUT" "$v1_tools"
    popd >/dev/null

    local v1_dur=$RUN_DURATION v1_in=$RUN_IN v1_out=$RUN_OUT v1_cr=$RUN_CACHE_R v1_cc=$RUN_CACHE_C v1_cost=$RUN_COST v1_turns=$RUN_TURNS
    local v1_status="ok"
    local ctx_files=0
    [[ -d "$run_dir/edc-context" ]] && ctx_files=$(find "$run_dir/edc-context" -type f -name '*.md' 2>/dev/null | wc -l | xargs)
    [[ "$ctx_files" -gt 0 ]] || v1_status="no-context-files"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$REPO" "$SHORT_SHA" "${cve}-${attempt}" "$v1_dur" "$v1_turns" \
      "$v1_in" "$v1_out" "$v1_cr" "$v1_cc" "$v1_cost" \
      "$ctx_files" 0 "$v1_status" >> "$BUILD_TSV"
    log "[v1-build] $cve attempt $attempt — $v1_status (${v1_dur}s, ctx_files=$ctx_files, cost=\$$v1_cost)"

    # Snapshot the v1 edc-context for later inspection (per-CVE)
    local v1_cache="$WORK_DIR/cache/$SHORT_SHA/$MODE/$RUN_LABEL/$REPO/$cve/attempt-$attempt"
    mkdir -p "$v1_cache"
    cp -R "$run_dir/edc-context" "$v1_cache/" 2>/dev/null || true

    [[ "$v1_status" == "ok" ]] || { log "[review] skipping $cve — build failed"; return 1; }

    if [[ "$MODE" == "v1" ]]; then
      prompt="Pre-built v1 architectural context exists under edc-context/ (full-context.md and per-file *.md). Read those first.

Perform a FULL-FILE security review of these source files:$file_list

Use the edc:edc-review skill. Treat this as full-file analysis (ignore any diff/PR-only language in the skill).

Write ALL findings to edc-context/reports/issues.md with: title, severity, category, file:line, description, evidence."
    else
      # v2-per-cve: review reads the narrow module doc rather than a per-repo index.
      prompt="Pre-built v2-style architectural context for the in-scope files exists at edc-context/modules/target.md. Read it first.

Perform a FULL-FILE security review of these source files:$file_list

Use the edc:edc-review skill. Treat this as full-file analysis (ignore any diff/PR-only language in the skill).

Write ALL findings to edc-context/reports/issues.md with: title, severity, category, file:line, description, evidence."
    fi
  fi

  local review_tools=""
  local review_turns="$REVIEW_TURNS"
  if [[ "$MODE" == "v1" ]]; then
    review_tools="Read Glob Grep Write Skill"
    review_turns=20
  fi
  log "[review] $cve attempt $attempt — claude invoking"
  pushd "$run_dir" >/dev/null
  run_claude "$run_dir" "$prompt" "$review_turns" "$REVIEW_TIMEOUT" "$review_tools"
  popd >/dev/null

  # Look for findings at the v2 canonical path first, fall back to legacy locations.
  local issues=""
  for candidate in \
      "$run_dir/edc-context/reports/issues.md" \
      "$run_dir/edc-context/issues.md" \
      "$run_dir/issues.md"; do
    [[ -s "$candidate" ]] && { issues="$candidate"; break; }
  done
  if [[ -z "$issues" ]]; then
    issues="$run_dir/edc-context/reports/issues.md"
    mkdir -p "$(dirname "$issues")"
    grep '"type":"result"' "$run_dir/claude-output.txt" 2>/dev/null | tail -1 \
      | jq -r '.result // empty' > "$issues" 2>/dev/null || true
  fi
  [[ -s "$issues" ]] || cp "$run_dir/claude-output.txt" "$issues" 2>/dev/null || true

  local status="ok"
  [[ -s "$issues" ]] || status="no-issues-file"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$REPO" "$SHORT_SHA" "$cve" "$attempt" "$RUN_DURATION" "$RUN_TURNS" \
    "$RUN_IN" "$RUN_OUT" "$RUN_CACHE_R" "$RUN_CACHE_C" "$RUN_COST" "$status" \
    >> "$REVIEW_TSV"

  log "[review] $cve attempt $attempt — $status (${RUN_DURATION}s, cost=\$$RUN_COST)"

  EDC_RESULTS_FILE="$SCORE_TSV" python3 "$BENCH_DIR/score.py" \
    --issues "$issues" \
    --cve "$cve_id" \
    --bug-pattern "$bug_pattern" \
    --category "$category" \
    --severity "$severity" \
    --affected-files "$affected_files" \
    --description "$description" \
    --duration "$RUN_DURATION" >&2 || true

  # Preserve review worktree if EDC_REG_KEEP_REVIEW=1 (for diagnosis)
  if [[ "${EDC_REG_KEEP_REVIEW:-0}" != "1" ]]; then
    git -C "$TARGET_REPO_DIR" worktree remove --force "$run_dir" 2>/dev/null || true
  fi
}

# ── Drive ──────────────────────────────────────────────────────────────────
log "starting regression: commit=$SHORT_SHA repo=$REPO attempts=$ATTEMPTS cves=${#ALL_CVES[@]} outer=$OUTER_MODEL build=$EDC_BUILD_MODEL review=$EDC_REVIEW_MODEL label=$RUN_LABEL"

for ((a=1; a<=ATTEMPTS; a++)); do
  log "═══ attempt $a/$ATTEMPTS ═══"
  if ! build_one_attempt "$a"; then
    log "[build] attempt $a failed — skipping reviews"
    continue
  fi
  for cve in "${ALL_CVES[@]}"; do
    review_one_cve "$a" "$cve"
  done
done

log "done — see $OUT_DIR/"
