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
#   4. Benchmark: run 5 fast CVEs in parallel via `claude -p --model sonnet`
#   5. If fast score > baseline → validate on all 11 CVEs in parallel
#   6. If full score > baseline → keep commit, update baseline
#      Otherwise → git reset --hard HEAD~1 (discard, karpathy pattern)
#   7. Log hash + score + delta + heuristic description (all attempts)
#   8. Repeat until -n limit or SIGTERM/SIGINT
#
# The agent reads experiment history each iteration to avoid repeating
# failed approaches and to build on what worked.
#
# Usage:
#   ./benchmark/autoresearch.sh                  # run until stopped
#   ./benchmark/autoresearch.sh -n 5             # run 5 iterations
#   ./benchmark/autoresearch.sh --status         # show progress
#   ./benchmark/autoresearch.sh --stop           # graceful stop
#   ./benchmark/autoresearch.sh --baseline       # recompute baseline
#   ./benchmark/autoresearch.sh --baseline -n 5  # recompute then run 5
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${EDC_BENCH_WORKDIR:-/private/tmp/edc-bench}"
CURL_REPO="$WORK_DIR/curl-shared"

BASELINE_FILE="$SCRIPT_DIR/baseline-score.txt"
HASHES_FILE="$SCRIPT_DIR/tried-hashes.tsv"
RESULTS_LOG="$SCRIPT_DIR/autoresearch-log.tsv"
LOGFILE="$SCRIPT_DIR/autoresearch-output.log"
PIDFILE="$SCRIPT_DIR/.autoresearch.pid"
STOPFILE="$SCRIPT_DIR/.autoresearch.stop"

SKILL_FILES=(
    "plugins/edc/skills/edc-context/SKILL.md"
    "plugins/edc/skills/edc-review/methodology.md"
)

# 5 CVEs for fast iteration (~15min wall time in parallel)
FAST_CVES=(
    "CVE-2023-38545"   # heap-buffer-overflow / state machine
    "CVE-2020-8285"    # stack-overflow / recursion
    "CVE-2019-3822"    # stack-buffer-overflow / integer underflow
    "CVE-2021-22945"   # use-after-free / double-free
    "CVE-2018-0500"    # heap-overflow / wrong malloc size
)

# All 11 CVEs for full validation
ALL_CVES=(
    "CVE-2023-38545" "CVE-2016-8617" "CVE-2021-22945" "CVE-2019-3822"
    "CVE-2018-0500" "CVE-2020-8177" "CVE-2021-22947" "CVE-2018-16890"
    "CVE-2020-8285" "CVE-2022-27776" "CVE-2018-1000301"
)

MODEL="sonnet"

# ── Logging ──────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOGFILE"
}

# ── Stop handling ────────────────────────────────────────────────────────────

SHOULD_STOP=false
handle_stop() { SHOULD_STOP=true; }
trap handle_stop SIGTERM SIGINT

should_stop() { $SHOULD_STOP || [ -f "$STOPFILE" ]; }

# ── PID ──────────────────────────────────────────────────────────────────────

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

# ── Hash dedup ───────────────────────────────────────────────────────────────

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

# ── CVE analysis ─────────────────────────────────────────────────────────────

ensure_curl_repo() {
    if [ ! -d "$CURL_REPO/.git" ]; then
        log "Cloning shared curl repo..."
        git clone --quiet https://github.com/curl/curl.git "$CURL_REPO"
    fi
}

get_cve_info() {
    python3 "$SCRIPT_DIR/parse_gt.py" "$SCRIPT_DIR/curl/ground-truth.md" | grep "^$1|"
}

run_cve() {
    local cve="$1"
    local cve_info
    cve_info=$(get_cve_info "$cve") || { log "  SKIP: $cve not in ground truth"; return 1; }

    IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern description <<< "$cve_info"

    local cve_dir="$WORK_DIR/$cve_id"
    local out_dir="$cve_dir/.context"

    mkdir -p "$(dirname "$cve_dir")"
    [ ! -d "$cve_dir/.git" ] && git clone --quiet "$CURL_REPO" "$cve_dir"

    git -C "$cve_dir" checkout --quiet "${fix_commit}~1" 2>/dev/null || {
        log "  SKIP: cannot checkout ${fix_commit}~1"
        return 1
    }

    rm -rf "$out_dir" && mkdir -p "$out_dir"

    local file_list=""
    IFS=',' read -ra files <<< "$affected_files"
    for f in "${files[@]}"; do file_list+=" $(echo "$f" | xargs)"; done

    local prompt="Run the edc:edc-context skill on ONLY these files:$file_list

Security-focused analysis. Write the complete analysis to .context/full-context.md

Then create .context/issues.md listing ALL security issues found, with:
- issue title
- severity (critical/high/medium/low)
- category (buffer overflow, use-after-free, logic error, etc.)
- affected file:line
- description of the bug
- evidence (the specific code pattern)

Be thorough. Analyze every buffer operation, every length check, every pointer operation, every state transition."

    log "  [$cve_id] analyzing ($category)..."
    local t0
    t0=$(date +%s)

    (cd "$cve_dir" && timeout 1800 claude -p "$prompt" \
        --plugin-dir "$REPO_ROOT/plugins/edc" \
        --allowedTools "Read Grep Glob Write Bash Skill" \
        --max-turns 50 \
        --model "$MODEL" \
        --output-format text \
        --dangerously-skip-permissions) \
        > "$out_dir/claude-output.txt" 2>&1 || true

    local dur=$(( $(date +%s) - t0 ))

    [ ! -f "$out_dir/issues.md" ] && cp "$out_dir/claude-output.txt" "$out_dir/issues.md"

    log "  [$cve_id] done in ${dur}s"

    python3 "$SCRIPT_DIR/score.py" \
        --issues "$out_dir/issues.md" \
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
    python3 -c "
import sys
lines = open('$results_file').read().strip().split('\n')
if len(lines) <= 1: print('0.000'); sys.exit()
total = len(lines) - 1
exact  = sum(1 for l in lines[1:] if '\texact\t'   in l)
partial= sum(1 for l in lines[1:] if '\tpartial\t' in l)
print(f'{(exact + partial * 0.5) / total:.3f}')
"
}

# ── Parallel benchmark ───────────────────────────────────────────────────────

run_benchmark() {
    local label="$1"
    shift
    local cves=("$@")

    local results_file="$SCRIPT_DIR/results-${label}.tsv"
    echo -e "timestamp\tcve\tcategory\tseverity\tfound\tconfidence\tduration\tnotes" > "$results_file"

    local bench_dir="$WORK_DIR/bench-${label}"
    rm -rf "$bench_dir"
    mkdir -p "$bench_dir"

    log "Benchmarking [$label] — ${#cves[@]} CVEs in parallel..."

    local pids=()
    local tmp_files=()
    for cve in "${cves[@]}"; do
        local tmp
        tmp=$(mktemp "$SCRIPT_DIR/.result-XXXXXXXX")
        tmp_files+=("$tmp")
        (
            export EDC_RESULTS_FILE="$tmp"
            export WORK_DIR="$bench_dir"
            run_cve "$cve" || true
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Merge per-CVE results (skip headers)
    for tmp in "${tmp_files[@]}"; do
        [ -s "$tmp" ] && tail -n +2 "$tmp" >> "$results_file" 2>/dev/null || true
        rm -f "$tmp"
    done

    local score
    score=$(calc_score "$results_file")
    log "Score [$label]: $score"
    echo "$score" > "$SCRIPT_DIR/.score-${label}.tmp"
}

# ── Agent modification ───────────────────────────────────────────────────────

apply_change() {
    local iteration="$1"
    local prompt_file
    prompt_file=$(mktemp /tmp/edc-prompt-XXXXXXXX)

    # Build context from experiment history
    local history="(none yet)"
    [ -f "$HASHES_FILE" ] && history=$(tail -15 "$HASHES_FILE" | awk -F'\t' 'NR>1{printf "score=%s delta=%s | %s\n", $2, $3, $4}') || true

    local last_breakdown="(none yet)"
    local last_results=""
    last_results=$(ls -t "$SCRIPT_DIR"/results-iter*.tsv 2>/dev/null | head -1) || true
    [ -n "$last_results" ] && last_breakdown=$(cat "$last_results")

    local tried="(none)"
    [ -f "$HASHES_FILE" ] && tried=$(awk -F'\t' 'NR>1{print $1}' "$HASHES_FILE" | tr '\n' ' ') || true

    local baseline_score
    baseline_score=$(cat "$BASELINE_FILE" 2>/dev/null || echo "unknown")

    cat > "$prompt_file" << 'PROMPT_HEADER'
You are iteratively improving LLM security analysis skills through experimentation.

Read the current skill files to understand what they contain:
PROMPT_HEADER

    for f in "${SKILL_FILES[@]}"; do
        echo "  - $REPO_ROOT/$f" >> "$prompt_file"
    done

    cat >> "$prompt_file" << PROMPT_BODY

BASELINE SCORE: $baseline_score / 1.0
(exact=1.0pt, partial=0.5pt, missed=0pt, averaged across CVEs)

RECENT EXPERIMENT HISTORY (what was tried, what score it got):
$history

LAST CVE BREAKDOWN:
$last_breakdown

ALREADY-TRIED HASHES — do NOT produce a file state matching any of these:
$tried

YOUR TASK: Make ONE focused change to improve security vulnerability detection.
Read the skill files first, then edit them. You can:

ADDITIONS — new analysis techniques:
- Integer arithmetic: underflow/overflow/wrap in size calcs that feed memcpy/malloc
- Cross-function data flow: trace a value from assignment to every consumer
- Error path analysis: when a sub-call fails, is cleanup correct? dangling state?
- Allocation/free pairing: every malloc has exactly one free on every code path
- Pointer arithmetic: offset + length vs buffer bounds
- Time-of-check vs time-of-use: value valid at check, stale at use
- Null pointer propagation: what if allocation or lookup returns null?
- Protocol state confusion: out-of-order or repeated protocol messages
- Signedness mismatch: signed/unsigned comparison, signed used as size/index
- String handling: off-by-one in null terminator, unbounded copy, format strings

SUBTRACTIONS — things that may waste tokens without helping:
- Generic frameworks (5-Whys, rationale tables) that don't guide line-by-line analysis
- Vague instructions ("be thorough") that don't specify what to look for
- Output format requirements that constrain rather than guide
- Redundant reminders repeated across sections

REWORDING:
- Replace abstract guidance with specific code patterns to look for
- Add concrete examples of what the vulnerability looks like in code
- Specify exact questions to ask at each function boundary

RESTRUCTURING:
- Move highest-signal checks to top
- Group by how bugs manifest in code vs by vulnerability class
- Collapse multiple weak heuristics into one strong one

After making your change, output exactly one line:
HEURISTIC: <one sentence: what you changed and why you think it will help>

Only edit files in: ${SKILL_FILES[*]}
PROMPT_BODY

    local agent_out
    agent_out=$(cd "$REPO_ROOT" && claude -p "$(cat "$prompt_file")" \
        --allowedTools "Read Edit Write Grep Glob" \
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

# ── Status ───────────────────────────────────────────────────────────────────

print_status() {
    echo ""
    echo "=== Autoresearch Status ==="
    is_running && echo "State: RUNNING (PID $(cat "$PIDFILE"))" || echo "State: STOPPED"
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

# ── Main loop ────────────────────────────────────────────────────────────────

main() {
    local recompute_baseline=false
    local max_iterations=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --stop)
                is_running && { kill "$(cat "$PIDFILE")"; touch "$STOPFILE"; echo "Stop sent."; } || echo "Not running."
                exit 0 ;;
            --status) print_status; exit 0 ;;
            --baseline) recompute_baseline=true; shift ;;
            --iterations|--iters|-n) max_iterations="$2"; shift 2 ;;
            *) echo "Unknown: $1"; exit 1 ;;
        esac
    done

    if is_running; then
        echo "Already running (PID $(cat "$PIDFILE")). Use --stop or --status."
        exit 1
    fi

    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT

    mkdir -p "$WORK_DIR"
    ensure_curl_repo

    [ ! -f "$HASHES_FILE" ] && printf 'hash\tscore\tdelta\theuristic\n' > "$HASHES_FILE"
    [ ! -f "$RESULTS_LOG" ] && printf 'timestamp\titeration\tscore\tdelta\tstatus\theuristic\n' > "$RESULTS_LOG"

    # Baseline
    local baseline
    if [ -f "$BASELINE_FILE" ] && ! $recompute_baseline; then
        baseline=$(cat "$BASELINE_FILE")
        log "Loaded baseline: $baseline"
    else
        log "Computing baseline on ${#FAST_CVES[@]} fast CVEs..."
        run_benchmark "baseline" "${FAST_CVES[@]}"
        baseline=$(cat "$SCRIPT_DIR/.score-baseline.tmp")
        echo "$baseline" > "$BASELINE_FILE"
        log "Baseline: $baseline"
        log_hash "$(compute_hash)" "$baseline" "+0.000" "baseline"
    fi

    local iteration=0
    [ "$max_iterations" -gt 0 ] && log "Max iterations: $max_iterations" || log "Running until stopped"

    while ! should_stop; do
        iteration=$(( iteration + 1 ))
        [ "$max_iterations" -gt 0 ] && [ "$iteration" -gt "$max_iterations" ] && break

        log ""
        log "══════════════════════════════════════"
        log "Iteration $iteration  (baseline=$baseline)"
        log "══════════════════════════════════════"

        # Agent proposes a change
        log "Agent proposing change..."
        local heuristic
        heuristic=$(apply_change "$iteration")
        log "Heuristic: $heuristic"

        # No changes → skip
        if git -C "$REPO_ROOT" diff --quiet -- "${SKILL_FILES[@]}"; then
            log "No changes — skipping"
            continue
        fi

        # Hash dedup
        local new_hash
        new_hash=$(compute_hash)
        if hash_tried "$new_hash"; then
            log "Hash already tried — discarding"
            git -C "$REPO_ROOT" checkout -- "${SKILL_FILES[@]}"
            continue
        fi

        # Commit (will reset --hard if no improvement)
        git -C "$REPO_ROOT" add "${SKILL_FILES[@]}"
        git -C "$REPO_ROOT" -c commit.gpgsign=false commit -m "experiment: iter-$iteration — $heuristic" --quiet

        local old_baseline="$baseline"
        local new_score=""
        local status="discard"

        # Phase 1: fast benchmark (5 CVEs in parallel)
        run_benchmark "iter-${iteration}-fast" "${FAST_CVES[@]}"
        local fast_score
        fast_score=$(cat "$SCRIPT_DIR/.score-iter-${iteration}-fast.tmp")
        local fast_delta
        fast_delta=$(python3 -c "print(f'{$fast_score - $old_baseline:+.3f}')")
        log "Fast: $fast_score ($fast_delta)"
        new_score="$fast_score"

        if python3 -c "exit(0 if $fast_score > $old_baseline else 1)"; then
            # Phase 2: full validation (all 11 CVEs in parallel)
            log "Fast improved → full validation on ${#ALL_CVES[@]} CVEs..."
            run_benchmark "iter-${iteration}-full" "${ALL_CVES[@]}"
            local full_score
            full_score=$(cat "$SCRIPT_DIR/.score-iter-${iteration}-full.tmp")
            local full_delta
            full_delta=$(python3 -c "print(f'{$full_score - $old_baseline:+.3f}')")
            log "Full: $full_score ($full_delta)"
            new_score="$full_score"

            if python3 -c "exit(0 if $full_score > $old_baseline else 1)"; then
                status="keep"
                baseline="$full_score"
                echo "$baseline" > "$BASELINE_FILE"
                log "KEEP — $old_baseline → $baseline — $heuristic"
            else
                log "Full validation failed — discarding"
                git -C "$REPO_ROOT" reset --hard HEAD~1 --quiet
            fi
        else
            log "No fast improvement — discarding"
            git -C "$REPO_ROOT" reset --hard HEAD~1 --quiet
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

main "$@"
