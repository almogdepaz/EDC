#!/usr/bin/env bash
set -euo pipefail

# EDC Autoresearch Loop
#
# Fully autonomous: runs experiments, measures, keeps/discards.
# No human in the loop. Supports graceful stop and resume.
#
# Usage:
#   ./benchmark/autoresearch.sh                    # run (or resume) all experiments
#   ./benchmark/autoresearch.sh --experiment NAME   # run specific experiment
#   ./benchmark/autoresearch.sh --dry-run          # show what would run
#   ./benchmark/autoresearch.sh --stop             # graceful stop after current experiment
#   ./benchmark/autoresearch.sh --status           # show current progress
#
# Stop/Resume:
#   - Send SIGTERM or SIGINT (ctrl-c) for graceful stop
#   - Or: ./benchmark/autoresearch.sh --stop
#   - Resume: just run ./benchmark/autoresearch.sh again
#   - State is persisted in: ideas.tsv, baseline-score.txt, autoresearch-log.tsv
#   - In-progress experiment is marked "running" → reverted to "queued" on resume

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_LOG="$SCRIPT_DIR/autoresearch-log.tsv"
BASELINE_FILE="$SCRIPT_DIR/baseline-score.txt"
WORK_DIR="${EDC_BENCH_WORKDIR:-/private/tmp/edc-bench}"
CURL_REPO="$WORK_DIR/curl-shared"
PIDFILE="$SCRIPT_DIR/.autoresearch.pid"
STOPFILE="$SCRIPT_DIR/.autoresearch.stop"
LOGFILE="$SCRIPT_DIR/autoresearch-output.log"
IDEAS_FILE="$SCRIPT_DIR/ideas.tsv"

# CVE test set — subset for fast iteration
FAST_CVES=(
    "CVE-2023-38545"   # missed — primary improvement target
    "CVE-2020-8285"    # partial — secondary target
    "CVE-2019-3822"    # exact — regression guard (stack overflow)
    "CVE-2021-22945"   # exact — regression guard (UAF)
)

ALL_CVES=(
    "CVE-2023-38545" "CVE-2016-8617" "CVE-2021-22945" "CVE-2019-3822"
    "CVE-2018-0500" "CVE-2020-8177" "CVE-2021-22947" "CVE-2018-16890"
    "CVE-2020-8285" "CVE-2022-27776" "CVE-2018-1000301"
)

# --- Logging ---

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOGFILE"
}

# --- Signal handling for graceful stop ---

SHOULD_STOP=false

handle_stop() {
    log "STOP signal received — will finish current experiment then exit"
    SHOULD_STOP=true
}

trap handle_stop SIGTERM SIGINT

check_stop() {
    # Check both signal and stop file
    if $SHOULD_STOP || [ -f "$STOPFILE" ]; then
        rm -f "$STOPFILE"
        return 0  # should stop
    fi
    return 1  # continue
}

# --- PID management ---

write_pid() {
    echo $$ > "$PIDFILE"
}

clear_pid() {
    rm -f "$PIDFILE"
}

is_running() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0  # running
        fi
        rm -f "$PIDFILE"  # stale pid
    fi
    return 1  # not running
}

# --- Ideas ledger ---

get_queued_experiments() {
    tail -n +2 "$IDEAS_FILE" | awk -F'\t' '$1 == "queued" { print $2 "|" $3 "|" $4 }'
}

mark_idea() {
    local name="$1"
    local new_status="$2"
    local score_delta="${3:-}"
    local tested_by="${4:-}"
    python3 -c "
import csv
rows = []
with open('$IDEAS_FILE', 'r') as f:
    reader = csv.reader(f, delimiter='\t')
    for row in reader:
        if len(row) >= 2 and row[1] == '$name':
            row[0] = '$new_status'
            while len(row) < 6: row.append('')
            if '$score_delta': row[4] = '$score_delta'
            if '$tested_by': row[5] = '$tested_by'
        rows.append(row)
with open('$IDEAS_FILE', 'w') as f:
    writer = csv.writer(f, delimiter='\t')
    writer.writerows(rows)
"
}

# Reset any "running" ideas back to "queued" (from interrupted runs)
recover_running_ideas() {
    if grep -q "^running" "$IDEAS_FILE" 2>/dev/null; then
        log "Recovering interrupted experiments..."
        python3 -c "
import csv
rows = []
with open('$IDEAS_FILE', 'r') as f:
    reader = csv.reader(f, delimiter='\t')
    for row in reader:
        if len(row) >= 1 and row[0] == 'running':
            row[0] = 'queued'
        rows.append(row)
with open('$IDEAS_FILE', 'w') as f:
    writer = csv.writer(f, delimiter='\t')
    writer.writerows(rows)
"
    fi
}

# Clean up any leftover experiment branches
recover_git_state() {
    local current_branch
    current_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
    if [[ "$current_branch" == experiment/* ]]; then
        log "Recovering from interrupted experiment branch: $current_branch"
        git -C "$REPO_ROOT" checkout research --quiet 2>/dev/null || true
        git -C "$REPO_ROOT" branch -D "$current_branch" --quiet 2>/dev/null || true
    fi
}

generate_new_ideas() {
    local current_ideas
    current_ideas=$(cat "$IDEAS_FILE")

    local prompt="You are an autoresearch agent improving code analysis skills for a security tool called EDC.

CURRENT IDEAS LEDGER (already proposed — do NOT repeat these):
$current_ideas

RECENT BENCHMARK RESULTS:
$(cat "$RESULTS_LOG" 2>/dev/null || echo "no results yet")

TASK: Propose 1-3 NEW experiment ideas that are NOT already in the ledger. Each idea should be:
- A single, atomic change to one skill file
- Either an addition (new analysis technique) or a subtraction (removing something that may be deadweight)
- Informed by the benchmark results — what bug categories are we weak on? what might help?

Output ONLY tab-separated lines in this exact format (no headers, no explanation):
queued\tname\ttarget_file\tone sentence description

Example:
queued\tcall-chain-depth\tplugins/edc/skills/edc-context/SKILL.md\tAdd explicit call chain depth tracing — follow callee chains 3+ levels deep instead of stopping at 1-hop"

    local new_ideas
    new_ideas=$(claude -p "$prompt" --output-format text 2>/dev/null || echo "")

    if [ -n "$new_ideas" ]; then
        echo "$new_ideas" | grep "^queued" >> "$IDEAS_FILE" || true
        local count
        count=$(echo "$new_ideas" | grep -c "^queued" || echo "0")
        log "Generated $count new experiment ideas"
    fi
}

# --- Benchmark ---

ensure_curl_repo() {
    if [ ! -d "$CURL_REPO/.git" ]; then
        log "Cloning shared curl repo..."
        git clone --quiet https://github.com/curl/curl.git "$CURL_REPO"
    fi
}

get_cve_info() {
    local cve="$1"
    python3 "$SCRIPT_DIR/parse_gt.py" "$SCRIPT_DIR/curl/ground-truth.md" | grep "^$cve|"
}

run_and_score_cve() {
    local cve="$1"
    local cve_info
    cve_info=$(get_cve_info "$cve")
    [ -z "$cve_info" ] && { log "  SKIP: $cve not found in ground truth"; return 1; }

    IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern description <<< "$cve_info"

    local cve_dir="$WORK_DIR/experiment-run/$cve_id"
    local output_dir="$cve_dir/.context"

    if [ ! -d "$cve_dir/.git" ]; then
        git clone --quiet "$CURL_REPO" "$cve_dir"
    fi

    git -C "$cve_dir" checkout --quiet "${fix_commit}~1" 2>/dev/null || {
        log "  SKIP: cannot checkout ${fix_commit}~1 for $cve_id"
        return 1
    }

    rm -rf "$output_dir"
    mkdir -p "$output_dir"

    local file_list=""
    IFS=',' read -ra files <<< "$affected_files"
    for f in "${files[@]}"; do
        file_list="$file_list $(echo "$f" | xargs)"
    done

    local prompt="Run the edc:edc-context skill on ONLY these files: $file_list

This is a security-focused analysis. Perform ultra-granular line-by-line analysis \
looking for all vulnerabilities including memory safety issues, state machine logic \
errors, flag/boolean corruption, protocol injection, and data flow problems.

Write the complete analysis to .context/full-context.md

Then create .context/issues.md listing ALL security issues you find, with:
- issue title
- severity (critical/high/medium/low)
- category (buffer overflow, use-after-free, logic error, etc.)
- affected file:line
- description of the bug
- evidence (the specific code pattern)

Be thorough. Do not skip any function. Analyze every buffer operation, every length \
check, every pointer operation, every state transition."

    log "  Analyzing $cve_id ($category)..."
    local start_time=$(date +%s)

    (cd "$cve_dir" && claude -p "$prompt" \
        --plugin-dir "$REPO_ROOT/plugins/edc" \
        --allowedTools "Read Grep Glob Write Bash Skill" \
        --max-turns 50 \
        --output-format text \
        --dangerously-skip-permissions) \
        > "$output_dir/claude-output.txt" 2>&1 || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ ! -f "$output_dir/issues.md" ]; then
        cp "$output_dir/claude-output.txt" "$output_dir/issues.md"
    fi

    log "  Done in ${duration}s, scoring..."

    python3 "$SCRIPT_DIR/score.py" \
        --issues "$output_dir/issues.md" \
        --cve "$cve_id" \
        --bug-pattern "$bug_pattern" \
        --category "$category" \
        --severity "$severity" \
        --affected-files "$affected_files" \
        --description "$description" \
        --duration "$duration" >&2
}

calc_score() {
    local results_file="$1"
    python3 -c "
import sys
lines = open('$results_file').read().strip().split('\n')
if len(lines) <= 1:
    print('0.0')
    sys.exit()
total = len(lines) - 1
exact = sum(1 for l in lines[1:] if '\texact\t' in l)
partial = sum(1 for l in lines[1:] if '\tpartial\t' in l)
score = (exact * 1.0 + partial * 0.5) / total
print(f'{score:.3f}')
"
}

run_benchmark() {
    local label="$1"
    shift
    local cves=("$@")

    local run_results="$SCRIPT_DIR/results-${label}.tsv"
    rm -f "$run_results"
    export EDC_RESULTS_FILE="$run_results"

    rm -rf "$WORK_DIR/experiment-run"

    log "Running benchmark [$label] on ${#cves[@]} CVEs..."
    for cve in "${cves[@]}"; do
        run_and_score_cve "$cve" || true
    done

    local score
    score=$(calc_score "$run_results")
    log "Score [$label]: $score"
    echo "$score"
}

# --- Experiment application ---

apply_experiment() {
    local exp_name="$1"
    local exp_desc="$2"

    local prompt="You are modifying EDC skills to improve security analysis capabilities. \
The change to make: $exp_desc

Rules:
- Make the MINIMUM change needed — add a section, checklist, or prompt enhancement
- Do NOT remove existing content unless the description says to remove something
- Do NOT refactor or reorganize existing sections
- Keep the addition focused and concise (10-30 lines max)
- The addition should be general-purpose, not CVE-specific

Make the change now. Edit the appropriate file in the plugins/edc/ directory."

    log "  Applying experiment: $exp_name"
    (cd "$REPO_ROOT" && claude -p "$prompt" \
        --allowedTools "Read Edit Grep Glob" \
        --max-turns 10 \
        --output-format text \
        --dangerously-skip-permissions) \
        > /dev/null 2>&1 || true
}

# --- Status ---

print_status() {
    echo ""
    echo "=== Autoresearch Status ==="

    if is_running; then
        echo "State: RUNNING (PID $(cat "$PIDFILE"))"
    else
        echo "State: STOPPED"
    fi

    if [ -f "$BASELINE_FILE" ]; then
        echo "Baseline: $(cat "$BASELINE_FILE")"
    else
        echo "Baseline: not computed yet"
    fi

    local queued=0 tested=0 running=0 kept=0
    if [ -f "$IDEAS_FILE" ]; then
        queued=$(grep -c "^queued" "$IDEAS_FILE" || echo "0")
        tested=$(grep -c "^tested" "$IDEAS_FILE" || echo "0")
        running=$(grep -c "^running" "$IDEAS_FILE" || echo "0")
        kept=$(awk -F'\t' '$1=="tested" && $6=="keep"' "$IDEAS_FILE" | wc -l | xargs)
    fi
    echo "Ideas: $tested tested ($kept kept), $queued queued, $running in-progress"

    if [ -f "$RESULTS_LOG" ]; then
        local total_exp
        total_exp=$(tail -n +2 "$RESULTS_LOG" | wc -l | xargs)
        echo "Experiments completed: $total_exp"
        echo ""
        echo "Recent results:"
        tail -5 "$RESULTS_LOG" | column -t -s$'\t'
    fi

    if [ -f "$LOGFILE" ]; then
        echo ""
        echo "Last log lines:"
        tail -5 "$LOGFILE"
    fi
    echo ""
}

# --- Main ---

main() {
    local dry_run=false
    local specific_exp=""
    local full_validation=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run) dry_run=true; shift ;;
            --experiment) specific_exp="$2"; shift 2 ;;
            --full) full_validation=true; shift ;;
            --stop)
                if is_running; then
                    kill "$(cat "$PIDFILE")" 2>/dev/null
                    touch "$STOPFILE"
                    echo "Stop signal sent. Current experiment will finish then exit."
                else
                    echo "Not running."
                fi
                exit 0
                ;;
            --status) print_status; exit 0 ;;
            *) echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    # Prevent double-run
    if is_running; then
        echo "Already running (PID $(cat "$PIDFILE")). Use --stop to stop, --status to check."
        exit 1
    fi

    write_pid
    trap 'clear_pid; handle_stop' EXIT

    # Recovery from interrupted run
    recover_running_ideas
    recover_git_state

    mkdir -p "$WORK_DIR"
    ensure_curl_repo

    # Initialize results log
    if [ ! -f "$RESULTS_LOG" ]; then
        echo -e "timestamp\texperiment\tbaseline_score\tnew_score\tdelta\tstatus\tdescription" > "$RESULTS_LOG"
    fi

    # Get or compute baseline
    local baseline_score
    if [ -f "$BASELINE_FILE" ]; then
        baseline_score=$(cat "$BASELINE_FILE")
        log "Loaded baseline score: $baseline_score"
    else
        log "Computing baseline score..."
        baseline_score=$(run_benchmark "baseline" "${FAST_CVES[@]}")
        echo "$baseline_score" > "$BASELINE_FILE"
        log "Baseline score: $baseline_score"
    fi

    # Run experiments from ideas ledger
    local exp_index=0
    while IFS='|' read -r exp_name exp_file exp_desc; do
        exp_index=$((exp_index + 1))
        [ -z "$exp_name" ] && continue

        # Check for stop signal
        if check_stop; then
            log "Stopping gracefully after $((exp_index - 1)) experiments"
            break
        fi

        # Filter if specific experiment requested
        if [ -n "$specific_exp" ] && [ "$specific_exp" != "$exp_index" ] && [ "$specific_exp" != "$exp_name" ]; then
            continue
        fi

        log ""
        log "========================================="
        log "Experiment $exp_index: $exp_name"
        log "  File: $exp_file"
        log "  Desc: $exp_desc"
        log "========================================="

        if $dry_run; then
            log "  [DRY RUN] Would apply and test"
            continue
        fi

        # Mark as running so we can recover on interrupt
        mark_idea "$exp_name" "running"

        # Save current state
        git -C "$REPO_ROOT" stash --quiet 2>/dev/null || true

        # Create experiment branch
        git -C "$REPO_ROOT" checkout -b "experiment/$exp_name" 2>/dev/null || {
            git -C "$REPO_ROOT" checkout "experiment/$exp_name" 2>/dev/null || true
        }

        # Apply the skill change
        apply_experiment "$exp_name" "$exp_desc"

        # Check if anything changed
        if git -C "$REPO_ROOT" diff --quiet; then
            log "  No changes made, skipping"
            git -C "$REPO_ROOT" checkout research --quiet
            git -C "$REPO_ROOT" branch -D "experiment/$exp_name" --quiet 2>/dev/null || true
            mark_idea "$exp_name" "tested" "no-change" "skipped"
            continue
        fi

        # Commit the change
        git -C "$REPO_ROOT" add -A
        git -C "$REPO_ROOT" -c commit.gpgsign=false commit -m "experiment: $exp_name — $exp_desc" --quiet

        # Run benchmark
        local new_score
        new_score=$(run_benchmark "$exp_name" "${FAST_CVES[@]}")

        # Compare
        local delta
        delta=$(python3 -c "print(f'{$new_score - $baseline_score:+.3f}')")
        local status="discard"

        if python3 -c "exit(0 if $new_score > $baseline_score else 1)"; then
            status="keep"
            log "  IMPROVED: $baseline_score → $new_score ($delta)"

            if $full_validation; then
                log "  Running full validation on all ${#ALL_CVES[@]} CVEs..."
                local full_score
                full_score=$(run_benchmark "${exp_name}-full" "${ALL_CVES[@]}")
                log "  Full validation score: $full_score"
            fi

            # Merge to research
            git -C "$REPO_ROOT" checkout research --quiet
            git -C "$REPO_ROOT" merge "experiment/$exp_name" --no-edit --quiet
            baseline_score="$new_score"
            echo "$baseline_score" > "$BASELINE_FILE"
        else
            log "  NO IMPROVEMENT: $baseline_score → $new_score ($delta), discarding"
            git -C "$REPO_ROOT" checkout research --quiet
        fi

        # Clean up experiment branch
        git -C "$REPO_ROOT" branch -D "experiment/$exp_name" --quiet 2>/dev/null || true

        # Update ideas ledger
        mark_idea "$exp_name" "tested" "$delta" "$status"

        # Log result
        echo -e "$(date -Iseconds)\t$exp_name\t$baseline_score\t$new_score\t$delta\t$status\t$exp_desc" >> "$RESULTS_LOG"

        # Progress summary
        local queued_count tested_count kept_count
        queued_count=$(grep -c "^queued" "$IDEAS_FILE" || echo "0")
        tested_count=$(grep -c "^tested" "$IDEAS_FILE" || echo "0")
        kept_count=$(awk -F'\t' '$1=="tested" && $6=="keep"' "$IDEAS_FILE" | wc -l | xargs)
        log "--- PROGRESS: $tested_count tested, $kept_count kept, $queued_count remaining, baseline=$baseline_score ---"
        log ""
    done < <(get_queued_experiments)

    # Generate new ideas for next run (only if we didn't stop early)
    if ! check_stop; then
        log "Generating new experiment ideas..."
        generate_new_ideas
    fi

    log ""
    log "========================================="
    log "Autoresearch $(if check_stop; then echo "paused"; else echo "complete"; fi)"
    log "Final score: $baseline_score"
    log "Results log: $RESULTS_LOG"
    log "========================================="

    clear_pid
}

main "$@"
