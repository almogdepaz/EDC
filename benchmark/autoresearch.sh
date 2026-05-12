#!/usr/bin/env bash
set -euo pipefail

# ── EDC Autoresearch ─────────────────────────────────────────────────────────
#
# Karpathy-style autonomous prompt tuning loop for security analysis skills.
#
# Method:
#   1. LLM agent freely edits skill files (SKILL.md, methodology.md)
#   2. SHA256 of file contents checked against tried-hashes.tsv → skip dupes
#   3. Commit the change (flat commit on current branch)
#   4. Benchmark: run fast CVEs in parallel via `claude -p --model sonnet`
#   5. If fast score > baseline → validate on regression CVEs in parallel
#   6. If regression holds → keep commit, update baseline
#      Otherwise → restore skill files from HEAD~1 + soft reset (safe discard)
#   7. Log hash + score + delta + heuristic description (all attempts)
#   8. Repeat until -n limit or SIGTERM/SIGINT
#
# Repos are auto-discovered from benchmark/{name}/ directories containing
# ground-truth.md + repo.conf. Add a new repo by creating those two files.
# Optionally add cve-lists.conf to control fast/regression CVE split.
#
# Usage:
#   ./benchmark/autoresearch.sh                  # run on all repos until stopped
#   ./benchmark/autoresearch.sh --repo curl      # run on curl only
#   ./benchmark/autoresearch.sh -n 5             # run 5 iterations
#   ./benchmark/autoresearch.sh --status         # show progress
#   ./benchmark/autoresearch.sh --stop           # graceful stop
#   ./benchmark/autoresearch.sh --baseline       # recompute baseline
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${EDC_BENCH_WORKDIR:-/private/tmp/edc-bench}"
CVE_CACHE="$WORK_DIR/cve-cache"

SKILL_FILES=(
    "plugins/edc/skills/edc-review-impl/SKILL.md"
    "plugins/edc/skills/edc-review-impl/methodology.md"
    "plugins/edc/skills/edc-review-impl/patterns.md"
    "plugins/edc/skills/edc-review-impl/adversarial.md"
)

MODEL="${EDC_BENCH_MODEL:-sonnet}"

# ── Repo discovery ──────────────────────────────────────────────────────────

declare -a ACTIVE_REPOS=()
declare -a ALL_FAST_CVES=()
declare -a ALL_REGRESSION_CVES=()
declare -a ALL_CVES=()
declare -A CVE_REPO=()

discover_repos() {
    local filter="$1"
    ACTIVE_REPOS=()

    for repo_dir in "$SCRIPT_DIR"/*/; do
        [ -f "$repo_dir/ground-truth.md" ] || continue
        [ -f "$repo_dir/repo.conf" ] || continue
        local name
        name="$(basename "$repo_dir")"
        [ -n "$filter" ] && [ "$name" != "$filter" ] && continue
        ACTIVE_REPOS+=("$name")
    done

    if [ ${#ACTIVE_REPOS[@]} -eq 0 ]; then
        echo "No repos found${filter:+ matching '$filter'}. Each repo needs ground-truth.md + repo.conf."
        exit 1
    fi
}

load_cve_lists() {
    ALL_FAST_CVES=()
    ALL_REGRESSION_CVES=()
    ALL_CVES=()
    CVE_REPO=()

    for repo_name in "${ACTIVE_REPOS[@]}"; do
        local repo_dir="$SCRIPT_DIR/$repo_name"
        local fast=() regression=()

        if [ -f "$repo_dir/cve-lists.conf" ]; then
            # Source the conf to get FAST_CVES and REGRESSION_CVES arrays
            local FAST_CVES=() REGRESSION_CVES=()
            source "$repo_dir/cve-lists.conf"
            fast=("${FAST_CVES[@]}")
            regression=("${REGRESSION_CVES[@]}")
        else
            # No cve-lists.conf — use all CVEs from ground truth, split auto
            local all_gt=()
            while IFS='|' read -r cve_id _rest; do
                all_gt+=("$cve_id")
            done < <(python3 "$SCRIPT_DIR/parse_gt.py" "$repo_dir/ground-truth.md")

            local split=$(( ${#all_gt[@]} / 2 ))
            [ "$split" -lt 1 ] && split=1
            fast=("${all_gt[@]:0:$split}")
            regression=("${all_gt[@]:$split}")
        fi

        for cve in "${fast[@]}"; do
            ALL_FAST_CVES+=("$cve")
            CVE_REPO["$cve"]="$repo_name"
        done
        for cve in "${regression[@]}"; do
            ALL_REGRESSION_CVES+=("$cve")
            CVE_REPO["$cve"]="$repo_name"
        done
    done

    ALL_CVES=("${ALL_FAST_CVES[@]}" "${ALL_REGRESSION_CVES[@]}")
}

get_repo_url() {
    local repo_name="$1"
    local url=""
    while IFS='=' read -r key val; do
        [ "$key" = "repo_url" ] && url="$val"
    done < "$SCRIPT_DIR/$repo_name/repo.conf"
    echo "$url"
}

# ── State file paths (scoped by active repos) ──────────────────────────────

SCOPE_DIR=""
BASELINE_FILE=""
REGRESSION_FLOOR_FILE=""
HASHES_FILE=""
RESULTS_LOG=""
LOGFILE=""
PIDFILE="$SCRIPT_DIR/.autoresearch.pid"
STOPFILE="$SCRIPT_DIR/.autoresearch.stop"

setup_state_paths() {
    if [ ${#ACTIVE_REPOS[@]} -eq 1 ]; then
        SCOPE_DIR="$SCRIPT_DIR/${ACTIVE_REPOS[0]}"
    else
        SCOPE_DIR="$SCRIPT_DIR"
    fi
    BASELINE_FILE="$SCOPE_DIR/baseline-score.txt"
    REGRESSION_FLOOR_FILE="$SCOPE_DIR/regression-floor.txt"
    HASHES_FILE="$SCOPE_DIR/tried-hashes.tsv"
    RESULTS_LOG="$SCOPE_DIR/autoresearch-log.tsv"
    LOGFILE="$SCOPE_DIR/autoresearch-output.log"
}

# ── Logging ─────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOGFILE"
}

# ── Stop handling ───────────────────────────────────────────────────────────

SHOULD_STOP=false
handle_stop() { SHOULD_STOP=true; }
trap handle_stop SIGTERM SIGINT

should_stop() { $SHOULD_STOP || [ -f "$STOPFILE" ]; }

# ── PID ─────────────────────────────────────────────────────────────────────

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

# ── Hash dedup ──────────────────────────────────────────────────────────────

compute_hash() {
    local content=""
    for f in "${SKILL_FILES[@]}"; do
        content+="$(cat "$REPO_ROOT/$f" 2>/dev/null)"
    done
    echo "$content" | sha256sum | cut -d' ' -f1
}

hash_tried() {
    local h="$1"
    [ -f "$HASHES_FILE" ] && grep -q "^${h}	" "$HASHES_FILE" 2>/dev/null
}

log_hash() {
    local h="$1" score="$2" delta="$3" heuristic="$4"
    printf '%s\t%s\t%s\t%s\n' "$h" "$score" "$delta" "$heuristic" >> "$HASHES_FILE"
}

# ── Repo clone management ──────────────────────────────────────────────────

ensure_repo() {
    local repo_name="$1"
    local shared_dir="$WORK_DIR/repos/$repo_name"

    if ! git -C "$shared_dir" rev-parse HEAD >/dev/null 2>&1; then
        local url
        url=$(get_repo_url "$repo_name")
        [ -z "$url" ] && { log "ERROR: no repo_url in $repo_name/repo.conf"; return 1; }
        log "Cloning $repo_name from $url..."
        rm -rf "$shared_dir"
        mkdir -p "$(dirname "$shared_dir")"
        git clone --quiet "$url" "$shared_dir"
    fi
}

# ── CVE source cache ───────────────────────────────────────────────────────

get_cve_info() {
    local repo_name="$1" cve_id="$2"
    python3 "$SCRIPT_DIR/parse_gt.py" "$SCRIPT_DIR/$repo_name/ground-truth.md" | grep "^$cve_id|"
}

cache_cve_sources() {
    mkdir -p "$CVE_CACHE"

    for repo_name in "${ACTIVE_REPOS[@]}"; do
        local shared_dir="$WORK_DIR/repos/$repo_name"
        local tmp_worktree="$WORK_DIR/_cache_worktree_$repo_name"

        for cve in "${ALL_CVES[@]}"; do
            [ "${CVE_REPO[$cve]}" = "$repo_name" ] || continue

            local cve_dir="$CVE_CACHE/$repo_name/$cve"
            [ -d "$cve_dir" ] && [ "$(ls "$cve_dir"/*.c "$cve_dir"/*.h "$cve_dir"/*.lua 2>/dev/null | wc -l)" -gt 0 ] && continue

            local cve_info
            cve_info=$(get_cve_info "$repo_name" "$cve") || continue
            IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern description <<< "$cve_info"

            if [ ! -d "$tmp_worktree" ]; then
                git -C "$shared_dir" worktree add --quiet --detach "$tmp_worktree" "${fix_commit}~1" 2>/dev/null || continue
            else
                git -C "$tmp_worktree" checkout --quiet --detach "${fix_commit}~1" 2>/dev/null || continue
            fi

            mkdir -p "$cve_dir"
            local file_count=0
            IFS=',' read -ra files <<< "$affected_files"
            for f in "${files[@]}"; do
                f="$(echo "$f" | xargs)"
                [ -f "$tmp_worktree/$f" ] && { cp "$tmp_worktree/$f" "$cve_dir/"; file_count=$((file_count + 1)); } || log "  WARN: $cve_id file not found: $f"
            done

            local total_lines=0
            [ "$file_count" -gt 0 ] && total_lines=$(cat "$cve_dir"/* 2>/dev/null | wc -l | xargs)
            log "  Cached $cve_id ($repo_name) — $file_count files, $total_lines lines"
        done

        [ -d "$tmp_worktree" ] && git -C "$shared_dir" worktree remove --force "$tmp_worktree" 2>/dev/null || true
    done
}

build_context_for_cve() {
    local cve="$1"
    local repo_name="${CVE_REPO[$cve]}"
    local cve_info
    cve_info=$(get_cve_info "$repo_name" "$cve") || { log "  SKIP: $cve not in ground truth"; return 1; }
    IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern description <<< "$cve_info"

    local ctx_file="$CVE_CACHE/$repo_name/$cve_id/edc-context/full-context.md"
    if [ -f "$ctx_file" ] && [ -s "$ctx_file" ]; then
        log "  [$cve_id] context already cached"
        return 0
    fi

    local src_dir="$CVE_CACHE/$repo_name/$cve_id"
    [ ! -d "$src_dir" ] && { log "  SKIP: $cve_id no cached source"; return 1; }

    local file_list=""
    IFS=',' read -ra files <<< "$affected_files"
    for f in "${files[@]}"; do file_list+=" $(basename "$(echo "$f" | xargs)")"; done

    local prompt="Run the edc:edc-context skill on these files:$file_list

Build complete architectural context. Write the full analysis to edc-context/full-context.md.
This step is pure architectural context building only — do NOT identify security vulnerabilities."

    local max_retries=3
    local attempt=0
    local timeout=600

    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))
        log "  [$cve_id] building context (attempt $attempt/$max_retries)..."

        local run_dir="$WORK_DIR/ctx-build/$cve_id"
        rm -rf "$run_dir"
        cp -r "$src_dir" "$run_dir"
        mkdir -p "$run_dir/edc-context"

        local t0
        t0=$(date +%s)

        (cd "$run_dir" && exec claude -p "$prompt" \
            --plugin-dir "$REPO_ROOT/plugins/edc" \
            --allowedTools "Read Glob Grep Write Skill" \
            --max-turns 30 \
            --model "$MODEL" \
            --output-format text \
            --dangerously-skip-permissions) \
            < /dev/null \
            > "$run_dir/ctx-output.txt" 2>&1 &
        local claude_pid=$!
        ( sleep "$timeout" \
            && kill "$claude_pid" 2>/dev/null \
            && pkill -TERM -P "$claude_pid" 2>/dev/null \
            ; sleep 5 \
            ; kill -9 "$claude_pid" 2>/dev/null \
            ; pkill -KILL -P "$claude_pid" 2>/dev/null \
        ) &
        local watchdog=$!
        wait "$claude_pid" 2>/dev/null || true
        kill "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true

        local dur=$(( $(date +%s) - t0 ))

        if [ -f "$run_dir/edc-context/full-context.md" ] && [ -s "$run_dir/edc-context/full-context.md" ]; then
            mkdir -p "$CVE_CACHE/$repo_name/$cve_id/edc-context"
            cp "$run_dir/edc-context/full-context.md" "$ctx_file"
            log "  [$cve_id] context cached (${dur}s, attempt $attempt)"
            return 0
        fi

        local err=""
        [ -f "$run_dir/ctx-output.txt" ] && err=$(grep -i "error\|timeout" "$run_dir/ctx-output.txt" | head -1) || true
        log "  [$cve_id] attempt $attempt failed (${dur}s)${err:+ — $err}"

        [ "$attempt" -lt "$max_retries" ] && sleep 10
    done

    log "  [$cve_id] WARN: context build failed after $max_retries attempts — review will run without context"
}

# ── Run security review for one CVE ────────────────────────────────────────

run_cve() {
    local cve="$1"
    local repo_name="${CVE_REPO[$cve]}"
    local cve_info
    cve_info=$(get_cve_info "$repo_name" "$cve") || { log "  SKIP: $cve not in ground truth"; return 1; }

    IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern description <<< "$cve_info"

    local src_dir="$CVE_CACHE/$repo_name/$cve_id"
    [ ! -d "$src_dir" ] && { log "  SKIP: $cve_id no cached source"; return 1; }

    local run_dir="$WORK_DIR/bench-out/$cve_id"
    mkdir -p "$(dirname "$run_dir")"
    rm -rf "$run_dir"
    cp -r "$src_dir" "$run_dir"
    mkdir -p "$run_dir/edc-context/reports"

    local ctx_cached="$CVE_CACHE/$repo_name/$cve_id/edc-context/full-context.md"
    [ -f "$ctx_cached" ] && cp "$ctx_cached" "$run_dir/edc-context/full-context.md"

    local file_list=""
    IFS=',' read -ra files <<< "$affected_files"
    for f in "${files[@]}"; do file_list+=" $(basename "$(echo "$f" | xargs)")"; done

    local ctx_note="Pre-built architectural context is in edc-context/full-context.md — read it first."
    [ ! -f "$run_dir/edc-context/full-context.md" ] && ctx_note="No pre-built context available — analyze from source only."

    local prompt="$ctx_note

Perform a full security review of these source files:$file_list

Use the edc:edc-review skill. This is a FULL-FILE review — analyze the entire source for vulnerabilities.
Ignore any diff/PR-specific instructions in the skill.

Write ALL findings to edc-context/reports/issues.md with:
- issue title
- severity (critical/high/medium/low)
- category (buffer overflow, use-after-free, logic error, etc.)
- affected file:line
- description of the bug
- evidence (the specific code pattern)"

    log "  [$cve_id] reviewing ($category)..."
    local t0
    t0=$(date +%s)

    # `exec` makes the subshell REPLACE itself with claude — without it, $! is
    # the wrapping subshell PID and a kill there leaves claude reparented to
    # init. With exec, $! IS claude's PID, so SIGTERM/SIGKILL reach claude.
    (cd "$run_dir" && exec claude -p "$prompt" \
        --plugin-dir "$REPO_ROOT/plugins/edc" \
        --allowedTools "Read Glob Grep Write Skill" \
        --max-turns 20 \
        --model "$MODEL" \
        --output-format stream-json --verbose \
        --dangerously-skip-permissions) \
        < /dev/null \
        > "$run_dir/claude-output.txt" 2>&1 &
    local claude_pid=$!
    # SIGTERM at 600s, escalate to SIGKILL at 605s — claude can swallow SIGTERM
    # during rate-limit retries and stream-idle backoffs. Also pkill direct
    # children (node) in case they outlive claude.
    ( sleep 600 \
        && kill "$claude_pid" 2>/dev/null \
        && pkill -TERM -P "$claude_pid" 2>/dev/null \
        ; sleep 5 \
        ; kill -9 "$claude_pid" 2>/dev/null \
        ; pkill -KILL -P "$claude_pid" 2>/dev/null \
    ) &
    local watchdog=$!
    wait "$claude_pid" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true

    local dur=$(( $(date +%s) - t0 ))

    local input_tokens=0 output_tokens=0 cache_read=0 cache_create=0 total_cost=0 num_turns=0
    if [ -s "$run_dir/claude-output.txt" ]; then
        local result_line
        result_line=$(grep -m1 '"type":"result"' "$run_dir/claude-output.txt" 2>/dev/null | tail -1)
        if [ -n "$result_line" ]; then
            input_tokens=$(printf '%s' "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)
            output_tokens=$(printf '%s' "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)
            cache_read=$(printf '%s' "$result_line" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo 0)
            cache_create=$(printf '%s' "$result_line" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo 0)
            total_cost=$(printf '%s' "$result_line" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)
            num_turns=$(printf '%s' "$result_line" | jq -r '.num_turns // 0' 2>/dev/null || echo 0)
        fi
    fi

    # v2 canonical: edc-context/reports/issues.md. Fall back to legacy locations.
    local issues_file=""
    for candidate in \
        "$run_dir/edc-context/reports/issues.md" \
        "$run_dir/edc-context/issues.md" \
        "$run_dir/issues.md"; do
        [ -s "$candidate" ] && { issues_file="$candidate"; break; }
    done
    if [ -z "$issues_file" ]; then
        issues_file="$run_dir/edc-context/reports/issues.md"
        mkdir -p "$(dirname "$issues_file")"
        grep '"type":"result"' "$run_dir/claude-output.txt" 2>/dev/null | tail -1 \
            | jq -r '.result // empty' > "$issues_file" 2>/dev/null || true
        [ ! -s "$issues_file" ] && cp "$run_dir/claude-output.txt" "$issues_file" 2>/dev/null || true
    fi

    if [ -n "${EDC_METRICS_FILE:-}" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$cve_id" "$dur" "$num_turns" \
            "$input_tokens" "$output_tokens" "$cache_read" "$cache_create" "$total_cost" \
            >> "$EDC_METRICS_FILE"
    fi

    log "  [$cve_id] done in ${dur}s (in=${input_tokens} out=${output_tokens} cost=\$${total_cost})"

    python3 "$SCRIPT_DIR/score.py" \
        --issues "$issues_file" \
        --cve "$cve_id" \
        --bug-pattern "$bug_pattern" \
        --category "$category" \
        --severity "$severity" \
        --affected-files "$affected_files" \
        --description "$description" \
        --duration "$dur" >&2
}

calc_score() {
    local results_file="$1"
    EDC_SCORE_FILE="$results_file" python3 -c "
import os, sys
lines = open(os.environ['EDC_SCORE_FILE']).read().strip().split('\n')
if len(lines) <= 1: print('0.000'); sys.exit()
total = len(lines) - 1
exact  = sum(1 for l in lines[1:] if '\texact\t'   in l)
partial= sum(1 for l in lines[1:] if '\tpartial\t' in l)
print(f'{(exact + partial * 0.5) / total:.3f}')
"
}

# ── Parallel benchmark ──────────────────────────────────────────────────────

run_benchmark() {
    local label="$1"
    shift
    local cves=("$@")

    local results_file="$SCOPE_DIR/results-${label}.tsv"
    echo -e "timestamp\tcve\tcategory\tseverity\tfound\tconfidence\tduration\tnotes" > "$results_file"

    local metrics_file="$SCOPE_DIR/metrics-${label}.tsv"
    echo -e "cve\tduration_s\tnum_turns\tinput_tokens\toutput_tokens\tcache_read\tcache_create\ttotal_cost" > "$metrics_file"

    local bench_dir="$WORK_DIR/bench-${label}"
    rm -rf "$bench_dir"
    mkdir -p "$bench_dir"

    log "Benchmarking [$label] — ${#cves[@]} CVEs in parallel..."

    local pids=()
    local tmp_files=()
    local metrics_tmp_files=()
    for cve in "${cves[@]}"; do
        local tmp metrics_tmp
        tmp=$(mktemp "$SCOPE_DIR/.result-XXXXXXXX")
        tmp_files+=("$tmp")
        metrics_tmp=$(mktemp "$SCOPE_DIR/.metrics-XXXXXXXX")
        metrics_tmp_files+=("$metrics_tmp")
        (
            export EDC_RESULTS_FILE="$tmp"
            export EDC_METRICS_FILE="$metrics_tmp"
            export WORK_DIR="$bench_dir"
            run_cve "$cve" || true
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    for tmp in "${tmp_files[@]}"; do
        [ -s "$tmp" ] && tail -n +2 "$tmp" >> "$results_file" 2>/dev/null || true
        rm -f "$tmp"
    done

    for tmp in "${metrics_tmp_files[@]}"; do
        [ -s "$tmp" ] && cat "$tmp" >> "$metrics_file" 2>/dev/null || true
        rm -f "$tmp"
    done

    local score
    score=$(calc_score "$results_file")
    log "Score [$label]: $score"
    echo "$score" > "$SCOPE_DIR/.score-${label}.tmp"
}

# ── Agent modification ──────────────────────────────────────────────────────

apply_change() {
    local iteration="$1"
    local prompt_file
    prompt_file=$(mktemp /tmp/edc-prompt-XXXXXXXX)

    local history="(none yet)"
    [ -f "$HASHES_FILE" ] && history=$(tail -15 "$HASHES_FILE" | awk -F'\t' 'NR>1{printf "score=%s delta=%s | %s\n", $2, $3, $4}') || true

    local last_breakdown="(none yet)"
    local last_results=""
    last_results=$(ls -t "$SCOPE_DIR"/results-iter*.tsv 2>/dev/null | head -1) || true
    [ -n "$last_results" ] && last_breakdown=$(cat "$last_results")

    local tried="(none)"
    [ -f "$HASHES_FILE" ] && tried=$(awk -F'\t' 'NR>1{print $1}' "$HASHES_FILE" | tr '\n' ' ') || true

    local baseline_score
    baseline_score=$(cat "$BASELINE_FILE" 2>/dev/null || echo "unknown")

    local repos_list="${ACTIVE_REPOS[*]}"

    cat > "$prompt_file" << 'PROMPT_HEADER'
You are iteratively improving LLM security analysis skills through experimentation.
The goal: improve recall on C security CVEs (buffer overflows, use-after-free, integer underflow, protocol injection, OOB reads).

First, read the current skill files to understand what they already contain:
PROMPT_HEADER

    for f in "${SKILL_FILES[@]}"; do
        echo "  - $REPO_ROOT/$f" >> "$prompt_file"
    done

    cat >> "$prompt_file" << PROMPT_DYNAMIC

REPOS UNDER TEST: $repos_list
BASELINE SCORE: $baseline_score / 1.0
(exact=1.0pt, partial=0.5pt, missed=0pt — measured on the hard CVEs we currently miss)

RECENT EXPERIMENT HISTORY (what was tried, what score it got):
$history

LAST CVE BREAKDOWN (what was found vs missed):
$last_breakdown

ALREADY-TRIED HASHES — do NOT produce a file state matching any of these:
$tried

Only edit files in: ${SKILL_FILES[*]}
PROMPT_DYNAMIC

    cat >> "$prompt_file" << 'PROMPT_STATIC'
─────────────────────────────────────────────────────────────────────
PLANNED EXPERIMENTS — pick ONE not yet tried and implement it exactly.
These are prioritized — try them in order if none have been tried yet.
─────────────────────────────────────────────────────────────────────

EXPERIMENT A — Sharp-Edges C Checklist (add to patterns.md)
Enumerate dangerous C APIs and require per-call-site audit:
- memcpy/memmove: is `n` bounded by dest size on ALL paths?
- strcpy/strcat/sprintf: flag unconditionally as dangerous
- realloc: is return value checked before freeing old pointer?
- malloc(a * b): is overflow in `a * b` possible?
- int/short used as length/index fed by peer-controlled data: negativity check present?

EXPERIMENT B — Integer Type Tracking (add to patterns.md)
For every size/length/count variable: track declared type, source (peer-controlled vs local),
and every arithmetic op before it reaches malloc/memcpy/array index. Flag:
- signed used where unsigned expected
- narrowing casts (long → int → short)
- subtraction that could underflow (unsigned a - b where b > a)
- multiplication that could overflow before reaching malloc

EXPERIMENT C — Subagent for Complex Functions (add to SKILL.md or methodology.md)
For functions >100 LOC or containing: state machines, multi-entry switch/case, recursive
patterns, or protocol parsing — instruct the reviewer to perform a dedicated focused pass
on that function alone BEFORE continuing with the rest of the file. This prevents timeout
on complex targets where the agent runs out of context before reaching the output step.

EXPERIMENT D — Variant Analysis Pass (add to methodology.md)
After finding ANY vulnerability: grep the file for the same pattern class.
One unchecked memcpy → search all memcpy calls with peer-controlled n.
One unsigned underflow → find all arithmetic feeding malloc/memcpy.
Explicitly document whether variants exist or are ruled out.

EXPERIMENT E — Explicit Trust Boundary + Taint Trace (add to methodology.md)
For each function receiving network/peer/user input: label it a taint source.
Trace every tainted value to every sink (alloc size, copy length, array index, branch).
Document where sanitization occurs or is absent. Flag unsanitized paths.

EXPERIMENT F — Fault Injection Thinking (add to methodology.md)
For each function: ask — what if a sub-call fails/hangs/returns garbage? what if input
is malicious/empty/huge? what if two concurrent callers hit this? Flag missing cleanup
on error paths, dangling state after partial failure, missing NULL checks after alloc.

EXPERIMENT G — TRAIL Threat Modeling (add to adversarial.md)
For each entrypoint: identify trust assumptions (what must be true about inputs).
Ask "what if wrong?" for each. Trace cascading impact of each violated assumption.

─────────────────────────────────────────────────────────────────────

YOUR TASK:
1. Read the skill files listed above.
2. Pick the first experiment from A–G not already reflected in the skill files.
3. Implement it — make ONE focused, concrete addition. Do not combine multiple experiments.
4. Output exactly one line: HEURISTIC: <what you added and which experiment it was>
PROMPT_STATIC

    local agent_out
    agent_out=$(cd "$REPO_ROOT" && claude -p "$(cat "$prompt_file")" \
        --allowedTools "Read(plugins/edc/skills/*) Edit(plugins/edc/skills/*)" \
        --max-turns 15 \
        --model "$MODEL" \
        --output-format text \
        --dangerously-skip-permissions 2>/dev/null) || true

    rm -f "$prompt_file"

    local heuristic=""
    heuristic=$(echo "$agent_out" | grep "^HEURISTIC:" | head -1 | sed 's/^HEURISTIC: //') || true
    [ -z "$heuristic" ] && heuristic="iter-$iteration (no description)"

    echo "$heuristic"
}

# ── Status ──────────────────────────────────────────────────────────────────

print_status() {
    echo ""
    echo "=== Autoresearch Status ==="
    is_running && echo "State: RUNNING (PID $(cat "$PIDFILE"))" || echo "State: STOPPED"
    echo "Repos: ${ACTIVE_REPOS[*]}"
    echo "CVEs: ${#ALL_FAST_CVES[@]} fast + ${#ALL_REGRESSION_CVES[@]} regression = ${#ALL_CVES[@]} total"
    [ -f "$BASELINE_FILE" ] && echo "Baseline: $(cat "$BASELINE_FILE")" || echo "Baseline: not computed"

    if [ -f "$HASHES_FILE" ]; then
        local total kept
        total=$(( $(wc -l < "$HASHES_FILE") - 1 ))
        kept=$(awk -F'\t' 'NR>1 && $3 ~ /^\+/ && $3 != "+0.000"' "$HASHES_FILE" | wc -l | xargs)
        echo "Iterations: $total tried, $kept improved"
        echo ""
        echo "Recent:"
        tail -5 "$HASHES_FILE" | awk -F'\t' '{printf "  score=%-6s delta=%-7s %s\n", $2, $3, $4}'
    fi
    echo ""
}

# ── Main loop ───────────────────────────────────────────────────────────────

main() {
    local recompute_baseline=false
    local max_iterations=-1
    local repo_filter=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --stop)
                is_running && { kill "$(cat "$PIDFILE")"; touch "$STOPFILE"; echo "Stop sent."; } || echo "Not running."
                exit 0 ;;
            --status)
                discover_repos "$repo_filter"
                load_cve_lists
                setup_state_paths
                print_status
                exit 0 ;;
            --baseline) recompute_baseline=true; shift ;;
            --repo) repo_filter="$2"; shift 2 ;;
            --iterations|--iters|-n) max_iterations="$2"; shift 2 ;;
            *) echo "Unknown: $1"; exit 1 ;;
        esac
    done

    discover_repos "$repo_filter"
    load_cve_lists
    setup_state_paths

    if is_running; then
        echo "Already running (PID $(cat "$PIDFILE")). Use --stop or --status."
        exit 1
    fi

    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT

    mkdir -p "$WORK_DIR"

    log "Active repos: ${ACTIVE_REPOS[*]}"
    log "CVEs: ${#ALL_FAST_CVES[@]} fast + ${#ALL_REGRESSION_CVES[@]} regression = ${#ALL_CVES[@]} total"

    for repo_name in "${ACTIVE_REPOS[@]}"; do
        ensure_repo "$repo_name"
    done

    log "Caching CVE source code..."
    cache_cve_sources

    log "Building architectural context for all CVEs (one-time, cached)..."
    for cve in "${ALL_CVES[@]}"; do
        build_context_for_cve "$cve"
    done

    [ ! -f "$HASHES_FILE" ] && printf 'hash\tscore\tdelta\theuristic\n' > "$HASHES_FILE"
    [ ! -f "$RESULTS_LOG" ] && printf 'timestamp\titeration\tscore\tdelta\tstatus\theuristic\n' > "$RESULTS_LOG"

    # Baseline
    local baseline regression_floor
    if [ -f "$BASELINE_FILE" ] && [ -f "$REGRESSION_FLOOR_FILE" ] && ! $recompute_baseline; then
        baseline=$(cat "$BASELINE_FILE")
        regression_floor=$(cat "$REGRESSION_FLOOR_FILE")
        log "Loaded baseline: $baseline  regression floor: $regression_floor"
    else
        log "Computing baseline on ${#ALL_FAST_CVES[@]} fast CVEs..."
        run_benchmark "baseline" "${ALL_FAST_CVES[@]}"
        baseline=$(cat "$SCOPE_DIR/.score-baseline.tmp")
        echo "$baseline" > "$BASELINE_FILE"

        log "Computing regression floor on ${#ALL_REGRESSION_CVES[@]} regression CVEs..."
        run_benchmark "baseline-regression" "${ALL_REGRESSION_CVES[@]}"
        regression_floor=$(cat "$SCOPE_DIR/.score-baseline-regression.tmp")
        echo "$regression_floor" > "$REGRESSION_FLOOR_FILE"

        log "Baseline: $baseline  Regression floor: $regression_floor"
        log_hash "$(compute_hash)" "$baseline" "+0.000" "baseline"
    fi

    if [ "$max_iterations" -eq 0 ]; then
        log "Baseline ready: $baseline. Exiting (use -n N to run N experiment iterations)."
        rm -f "$PIDFILE"
        exit 0
    fi

    local iteration=0
    local consecutive_nochange=0
    local max_consecutive_nochange=5
    [ "$max_iterations" -gt 0 ] && log "Max iterations: $max_iterations" || log "Running until stopped"

    while ! should_stop; do
        iteration=$(( iteration + 1 ))
        [ "$max_iterations" -gt 0 ] && [ "$iteration" -gt "$max_iterations" ] && break

        log ""
        log "══════════════════════════════════════"
        log "Iteration $iteration  (fast_baseline=$baseline  reg_floor=$regression_floor)"
        log "══════════════════════════════════════"

        log "Agent proposing change..."
        local heuristic
        heuristic=$(apply_change "$iteration")
        log "Heuristic: $heuristic"

        if git -C "$REPO_ROOT" diff --quiet -- "${SKILL_FILES[@]}"; then
            consecutive_nochange=$(( consecutive_nochange + 1 ))
            log "No changes — skipping ($consecutive_nochange/$max_consecutive_nochange)"
            if [ "$consecutive_nochange" -ge "$max_consecutive_nochange" ]; then
                log "Too many consecutive no-ops — stopping. Agent is stuck."
                break
            fi
            continue
        fi
        consecutive_nochange=0

        local new_hash
        new_hash=$(compute_hash)
        if hash_tried "$new_hash"; then
            log "Hash already tried — discarding"
            git -C "$REPO_ROOT" checkout -- "${SKILL_FILES[@]}"
            continue
        fi

        git -C "$REPO_ROOT" add "${SKILL_FILES[@]}"
        git -C "$REPO_ROOT" -c commit.gpgsign=false commit -m "experiment: iter-$iteration — $heuristic" --quiet

        local old_baseline="$baseline"
        local new_score=""
        local status="discard"

        run_benchmark "iter-${iteration}-fast" "${ALL_FAST_CVES[@]}"
        local fast_score
        fast_score=$(cat "$SCOPE_DIR/.score-iter-${iteration}-fast.tmp")
        local fast_delta
        fast_delta=$(python3 -c "print(f'{$fast_score - $old_baseline:+.3f}')")
        log "Fast: $fast_score ($fast_delta)"
        new_score="$fast_score"

        if python3 -c "exit(0 if $fast_score > $old_baseline else 1)"; then
            log "Fast improved → regression check on ${#ALL_REGRESSION_CVES[@]} regression CVEs..."
            run_benchmark "iter-${iteration}-regression" "${ALL_REGRESSION_CVES[@]}"
            local reg_score
            reg_score=$(cat "$SCOPE_DIR/.score-iter-${iteration}-regression.tmp")
            log "Regression: $reg_score (floor=$regression_floor)"
            new_score="$fast_score"

            if python3 -c "exit(0 if $reg_score >= $regression_floor else 1)"; then
                status="keep"
                baseline="$fast_score"
                echo "$baseline" > "$BASELINE_FILE"
                log "KEEP — $old_baseline → $baseline — $heuristic"
            else
                log "Regression detected ($reg_score < $regression_floor) — discarding"
                git -C "$REPO_ROOT" checkout HEAD~1 -- "${SKILL_FILES[@]}"
                git -C "$REPO_ROOT" reset --soft HEAD~1 --quiet
            fi
        else
            log "No fast improvement — discarding"
            git -C "$REPO_ROOT" checkout HEAD~1 -- "${SKILL_FILES[@]}"
            git -C "$REPO_ROOT" reset --soft HEAD~1 --quiet
        fi

        local delta
        delta=$(python3 -c "print(f'{$new_score - $old_baseline:+.3f}')")

        log_hash "$new_hash" "$new_score" "$delta" "$heuristic"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$iteration" "$new_score" "$delta" "$status" "$heuristic" >> "$RESULTS_LOG"

        log "Done iter $iteration — baseline=$baseline"
    done

    log ""
    log "Stopped after $iteration iterations. Final baseline: $baseline"
    rm -f "$PIDFILE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
