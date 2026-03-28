#!/usr/bin/env bash
set -euo pipefail

# EDC Autoresearch Loop
#
# Runs forever (until SIGTERM/SIGINT) — each iteration:
#   1. Agent freely modifies skill files (add, remove, reword, anything)
#   2. Hash the result — skip if already tried
#   3. Benchmark on ALL CVEs
#   4. Keep if improved, discard otherwise
#   5. Log hash + heuristic + score
#
# Usage:
#   ./benchmark/autoresearch.sh              # run until stopped
#   ./benchmark/autoresearch.sh --status     # show progress
#   ./benchmark/autoresearch.sh --stop       # graceful stop
#   ./benchmark/autoresearch.sh --baseline   # recompute baseline

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${EDC_BENCH_WORKDIR:-/private/tmp/edc-bench}"
CURL_REPO="$WORK_DIR/curl-shared"

BASELINE_FILE="$SCRIPT_DIR/baseline-score.txt"
HASHES_FILE="$SCRIPT_DIR/tried-hashes.tsv"   # hash<TAB>score<TAB>delta<TAB>heuristic
RESULTS_LOG="$SCRIPT_DIR/autoresearch-log.tsv"
PIDFILE="$SCRIPT_DIR/.autoresearch.pid"
STOPFILE="$SCRIPT_DIR/.autoresearch.stop"

# Skill files the agent can freely modify
SKILL_FILES=(
    "plugins/edc/skills/edc-context/SKILL.md"
    "plugins/edc/skills/edc-review/methodology.md"
)

# Full CVE set — run all every iteration
ALL_CVES=(
    "CVE-2023-38545" "CVE-2016-8617" "CVE-2021-22945" "CVE-2019-3822"
    "CVE-2018-0500" "CVE-2020-8177" "CVE-2021-22947" "CVE-2018-16890"
    "CVE-2020-8285" "CVE-2022-27776" "CVE-2018-1000301"
)

# ── Logging ──────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >&2
    echo "$msg" >> "$SCRIPT_DIR/autoresearch-output.log"
}

# ── Stop/resume ───────────────────────────────────────────────────────────────

SHOULD_STOP=false

handle_stop() {
    log "STOP signal — finishing current iteration then exiting"
    SHOULD_STOP=true
}

trap handle_stop SIGTERM SIGINT

should_stop() {
    $SHOULD_STOP || [ -f "$STOPFILE" ]
}

# ── PID ───────────────────────────────────────────────────────────────────────

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

# ── Hash ─────────────────────────────────────────────────────────────────────

compute_hash() {
    local content=""
    for f in "${SKILL_FILES[@]}"; do
        content+="$(cat "$REPO_ROOT/$f" 2>/dev/null)"
    done
    echo "$content" | sha256sum | cut -d' ' -f1
}

hash_tried() {
    local h="$1"
    [ -f "$HASHES_FILE" ] && grep -q "^$h	" "$HASHES_FILE" 2>/dev/null
}

log_hash() {
    local h="$1" score="$2" delta="$3" heuristic="$4"
    echo -e "$h\t$score\t$delta\t$heuristic" >> "$HASHES_FILE"
}

# ── CVE benchmark ─────────────────────────────────────────────────────────────

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

    local cve_dir="$WORK_DIR/bench-run/$cve_id"
    local out_dir="$cve_dir/.context"

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

    (cd "$cve_dir" && claude -p "$prompt" \
        --plugin-dir "$REPO_ROOT/plugins/edc" \
        --allowedTools "Read Grep Glob Write Bash Skill" \
        --max-turns 50 \
        --output-format text \
        --dangerously-skip-permissions) \
        > "$out_dir/claude-output.txt" 2>&1 || true

    local dur=$(( $(date +%s) - t0 ))

    [ ! -f "$out_dir/issues.md" ] && cp "$out_dir/claude-output.txt" "$out_dir/issues.md"

    log "  [$cve_id] done in ${dur}s, scoring..."

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

run_benchmark() {
    local label="$1"
    local results_file="$SCRIPT_DIR/results-${label}.tsv"
    rm -f "$results_file"
    export EDC_RESULTS_FILE="$results_file"
    rm -rf "$WORK_DIR/bench-run"

    log "Benchmarking [$label] on ${#ALL_CVES[@]} CVEs..."
    for cve in "${ALL_CVES[@]}"; do
        run_cve "$cve" || true
        should_stop && { log "Stop requested mid-benchmark"; break; }
    done

    local score
    score=$(calc_score "$results_file")
    log "Score [$label]: $score"
    echo "$score" > "$SCRIPT_DIR/.score-${label}.tmp"
}

# ── Branch helpers ───────────────────────────────────────────────────────────

return_to_research() {
    # Restore any skill-file changes, then switch back to research
    git -C "$REPO_ROOT" checkout -- "${SKILL_FILES[@]}" 2>/dev/null || true
    git -C "$REPO_ROOT" checkout research --quiet 2>/dev/null || true
}

# ── Agent modification ────────────────────────────────────────────────────────

apply_change() {
    local iteration="$1"
    local prompt_file
    prompt_file=$(mktemp /tmp/edc-prompt-XXXXX.txt)

    # Build context
    local history="(none yet)"
    [ -f "$HASHES_FILE" ] && history=$(tail -15 "$HASHES_FILE" | awk -F'\t' 'NR>1{printf "score=%s delta=%s | %s\n", $2, $3, $4}')

    local last_breakdown="(none yet)"
    local last_results
    last_results=$(ls -t "$SCRIPT_DIR"/results-iter*.tsv 2>/dev/null | head -1 || true)
    [ -n "$last_results" ] && last_breakdown=$(cat "$last_results")

    local tried="(none)"
    [ -f "$HASHES_FILE" ] && tried=$(awk -F'\t' 'NR>1{print $1}' "$HASHES_FILE" | tr '\n' ' ')

    local baseline_score
    baseline_score=$(cat "$BASELINE_FILE" 2>/dev/null || echo "not computed")

    # Write prompt to temp file to avoid bash special-char issues
    cat > "$prompt_file" << 'PROMPT_EOF'
You are iteratively improving LLM security analysis skills through experimentation.

Read the current skill files to understand what they contain:
PROMPT_EOF

    for f in "${SKILL_FILES[@]}"; do
        echo "  - $REPO_ROOT/$f" >> "$prompt_file"
    done

    cat >> "$prompt_file" << PROMPT_EOF

BASELINE SCORE: $baseline_score / 1.0
(exact=1.0pt, partial=0.5pt, missed=0pt, averaged across ${#ALL_CVES[@]} CVEs)

RECENT EXPERIMENT HISTORY (what was tried, what score it got):
$history

LAST CVE BREAKDOWN:
$last_breakdown

ALREADY TRIED — do NOT reproduce a file state whose sha256 hash is in this list:
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
- Re-entrancy: function called again before previous call completes — shared state?

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
PROMPT_EOF

    local agent_out
    agent_out=$(cd "$REPO_ROOT" && claude -p "$(cat "$prompt_file")" \
        --allowedTools "Read Edit Write Grep Glob" \
        --max-turns 15 \
        --output-format text \
        --dangerously-skip-permissions 2>/dev/null || echo "")

    rm -f "$prompt_file"

    local heuristic
    heuristic=$(echo "$agent_out" | grep "^HEURISTIC:" | head -1 | sed 's/^HEURISTIC: //')
    [ -z "$heuristic" ] && heuristic="iter-$iteration no description"

    echo "$heuristic"
}

# ── Status ────────────────────────────────────────────────────────────────────

print_status() {
    echo ""
    echo "=== Autoresearch Status ==="
    is_running && echo "State: RUNNING (PID $(cat "$PIDFILE"))" || echo "State: STOPPED"
    [ -f "$BASELINE_FILE" ] && echo "Baseline: $(cat "$BASELINE_FILE")" || echo "Baseline: not computed"

    if [ -f "$HASHES_FILE" ]; then
        local total kept
        total=$(wc -l < "$HASHES_FILE")
        kept=$(awk -F'\t' '$3 > 0' "$HASHES_FILE" | wc -l | xargs)
        echo "Iterations: $total total, $kept improved"
        echo ""
        echo "Recent history:"
        tail -5 "$HASHES_FILE" | awk -F'\t' '{printf "  score=%-6s delta=%-7s %s\n", $2, $3, $4}'
    fi
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    local recompute_baseline=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --stop)
                is_running && { kill "$(cat "$PIDFILE")"; touch "$STOPFILE"; echo "Stop sent."; } || echo "Not running."
                exit 0 ;;
            --status) print_status; exit 0 ;;
            --baseline) recompute_baseline=true; shift ;;
            *) echo "Unknown: $1"; exit 1 ;;
        esac
    done

    if is_running; then
        echo "Already running (PID $(cat "$PIDFILE")). Use --stop or --status."
        exit 1
    fi

    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"; handle_stop' EXIT

    mkdir -p "$WORK_DIR"
    ensure_curl_repo

    # Init files
    [ ! -f "$HASHES_FILE" ] && echo -e "hash\tscore\tdelta\theuristic" > "$HASHES_FILE"
    [ ! -f "$RESULTS_LOG" ] && echo -e "timestamp\titeration\tscore\tdelta\tstatus\theuristic" > "$RESULTS_LOG"

    # Baseline
    local baseline
    if [ -f "$BASELINE_FILE" ] && ! $recompute_baseline; then
        baseline=$(cat "$BASELINE_FILE")
        log "Loaded baseline: $baseline"
    else
        log "Computing baseline..."
        run_benchmark "baseline"
        baseline=$(cat "$SCRIPT_DIR/.score-baseline.tmp")
        echo "$baseline" > "$BASELINE_FILE"
        log "Baseline: $baseline"

        # Log baseline hash
        local base_hash
        base_hash=$(compute_hash)
        log_hash "$base_hash" "$baseline" "+0.000" "baseline"
    fi

    local iteration=0

    while ! should_stop; do
        iteration=$(( iteration + 1 ))
        log ""
        log "══════════════════════════════════════"
        log "Iteration $iteration  (baseline=$baseline)"
        log "══════════════════════════════════════"

        # Save current state
        git -C "$REPO_ROOT" stash --quiet 2>/dev/null || true

        # Create experiment branch
        local branch="experiment/iter-$iteration"
        git -C "$REPO_ROOT" checkout -b "$branch" --quiet 2>/dev/null || \
            git -C "$REPO_ROOT" checkout "$branch" --quiet 2>/dev/null || true

        # Let agent modify freely
        log "Applying agent change..."
        local heuristic
        heuristic=$(apply_change "$iteration")
        log "Heuristic: $heuristic"

        # Check if agent made any changes
        if git -C "$REPO_ROOT" diff --quiet; then
            log "No changes made — skipping"
            return_to_research
            git -C "$REPO_ROOT" branch -D "$branch" --quiet 2>/dev/null || true
            continue
        fi

        # Hash check
        local new_hash
        new_hash=$(compute_hash)
        if hash_tried "$new_hash"; then
            log "Hash already tried — skipping"
            return_to_research
            git -C "$REPO_ROOT" branch -D "$branch" --quiet 2>/dev/null || true
            continue
        fi

        # Commit
        git -C "$REPO_ROOT" add -A
        git -C "$REPO_ROOT" -c commit.gpgsign=false commit -m "experiment: iter-$iteration — $heuristic" --quiet

        # Benchmark
        run_benchmark "iter-$iteration"
        local new_score
        new_score=$(cat "$SCRIPT_DIR/.score-iter-${iteration}.tmp")

        local delta
        delta=$(python3 -c "print(f'{$new_score - $baseline:+.3f}')")

        local status="discard"
        if python3 -c "exit(0 if $new_score > $baseline else 1)"; then
            status="keep"
            log "IMPROVED: $baseline → $new_score ($delta) — $heuristic"
            return_to_research
            git -C "$REPO_ROOT" merge "$branch" --no-edit --quiet
            baseline="$new_score"
            echo "$baseline" > "$BASELINE_FILE"
        else
            log "No improvement: $baseline → $new_score ($delta)"
            return_to_research
        fi

        git -C "$REPO_ROOT" branch -D "$branch" --quiet 2>/dev/null || true

        # Log
        log_hash "$new_hash" "$new_score" "$delta" "$heuristic"
        echo -e "$(date -Iseconds)\t$iteration\t$new_score\t$delta\t$status\t$heuristic" >> "$RESULTS_LOG"

        log "Progress: iteration $iteration done, baseline now $baseline"
    done

    log ""
    log "Autoresearch stopped. Final baseline: $baseline. Iterations: $iteration."
    rm -f "$PIDFILE"
}

main "$@"
