#!/usr/bin/env bash
set -euo pipefail

# EDC Autoresearch Loop
#
# Fully autonomous: runs experiments, measures, keeps/discards.
# No human in the loop.
#
# Usage:
#   ./benchmark/autoresearch.sh                    # run all planned experiments
#   ./benchmark/autoresearch.sh --experiment 1     # run specific experiment
#   ./benchmark/autoresearch.sh --dry-run          # show what would run
#
# Each experiment:
#   1. Creates a branch experiment/<name>
#   2. Applies ONE skill change
#   3. Runs benchmark on all CVEs
#   4. Compares score against baseline
#   5. If improved → commits to research branch
#   6. If same/worse → discards branch
#   7. Logs result

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_LOG="$SCRIPT_DIR/autoresearch-log.tsv"
BASELINE_FILE="$SCRIPT_DIR/baseline-score.txt"
WORK_DIR="${EDC_BENCH_WORKDIR:-/private/tmp/edc-bench}"
CURL_REPO="$WORK_DIR/curl-shared"

# CVE test set — subset for fast iteration (full set too expensive per experiment)
# Use the 4 hardest CVEs: the miss, the partial, and 2 exact matches as regression guards
FAST_CVES=(
    "CVE-2023-38545"   # missed — primary improvement target
    "CVE-2020-8285"    # partial — secondary target
    "CVE-2019-3822"    # exact — regression guard (stack overflow)
    "CVE-2021-22945"   # exact — regression guard (UAF)
)

# All CVEs for full validation
ALL_CVES=(
    "CVE-2023-38545" "CVE-2016-8617" "CVE-2021-22945" "CVE-2019-3822"
    "CVE-2018-0500" "CVE-2020-8177" "CVE-2021-22947" "CVE-2018-16890"
    "CVE-2020-8285" "CVE-2022-27776" "CVE-2018-1000301"
)

# Experiment definitions
# Format: name|file_to_modify|description
EXPERIMENTS=(
    "fault-injection|plugins/edc/skills/edc-review/methodology.md|Add fault injection thinking prompts to review methodology"
    "security-checklist|plugins/edc/skills/edc-review/patterns.md|Add mandatory security checklist as structured prompts"
    "cognitive-complexity|plugins/edc/commands/edc-audit.md|Add cognitive complexity flagging beyond LOC"
    "unenforced-invariants|plugins/edc/skills/edc-context/SKILL.md|Add detection of invariants claimed but not enforced by code"
    "taint-tracing|plugins/edc/skills/edc-context/SKILL.md|Add manual taint tracing from untrusted input to sink"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

ensure_curl_repo() {
    if [ ! -d "$CURL_REPO/.git" ]; then
        log "Cloning shared curl repo..."
        git clone --quiet https://github.com/curl/curl.git "$CURL_REPO"
    fi
}

# Parse ground truth for a specific CVE
get_cve_info() {
    local cve="$1"
    python3 "$SCRIPT_DIR/parse_gt.py" "$SCRIPT_DIR/curl/ground-truth.md" | grep "^$cve|"
}

# Run analysis on a single CVE and score it
run_and_score_cve() {
    local cve="$1"
    local cve_info
    cve_info=$(get_cve_info "$cve")
    [ -z "$cve_info" ] && { log "  SKIP: $cve not found in ground truth"; return 1; }

    IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern description <<< "$cve_info"

    local cve_dir="$WORK_DIR/experiment-run/$cve_id"
    local output_dir="$cve_dir/.context"

    # Clone from shared repo
    if [ ! -d "$cve_dir/.git" ]; then
        git clone --quiet "$CURL_REPO" "$cve_dir"
    fi

    # Checkout vulnerable version
    git -C "$cve_dir" checkout --quiet "${fix_commit}~1" 2>/dev/null || {
        log "  SKIP: cannot checkout ${fix_commit}~1 for $cve_id"
        return 1
    }

    rm -rf "$output_dir"
    mkdir -p "$output_dir"

    # Build file list
    local file_list=""
    IFS=',' read -ra files <<< "$affected_files"
    for f in "${files[@]}"; do
        file_list="$file_list $(echo "$f" | xargs)"
    done

    local prompt="You are performing a security-focused code analysis. \
Analyze the following files for security vulnerabilities: $file_list

For each file, read it completely and analyze every function for:

MEMORY SAFETY: buffer overflows, integer overflows, use-after-free, double-free, \
null pointer dereferences, out-of-bounds reads/writes, size truncation on cast

STATE MACHINE LOGIC: state transitions that skip validation, variables set in one \
state but consumed in a different state with wrong assumptions, non-blocking re-entry \
bugs where decisions from a previous call become invalid

FLAG/BOOLEAN TRACING: for every flag that controls behavior, trace where it is set, \
where it is consumed, and whether any code path between those points can change it \
unexpectedly. If a flag controls local-vs-remote resolution, protocol variant, or \
buffer sizing, analyze what happens if it has the wrong value.

PROTOCOL LOGIC: trace data from external/network inputs through all transformations \
to sinks. Check all length/size validations for completeness.

Write your findings to .context/issues.md with this format for each issue:
### ISSUE-N: <title>
- **severity:** critical|high|medium|low
- **category:** <bug type>
- **file:** <path>:<line range>
- **description:** <what the bug is and why it's exploitable>
- **evidence:** <the specific code pattern that's wrong>

Be thorough. Do not skip functions. Do not assume code is safe."

    log "  Analyzing $cve_id ($category)..."
    local start_time=$(date +%s)

    claude -p "$prompt" \
        --cwd "$cve_dir" \
        --allowedTools "Read Grep Glob Write Bash" \
        --max-turns 40 \
        --output-format text \
        > "$output_dir/claude-output.txt" 2>&1 || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # If issues.md wasn't created, use claude output
    if [ ! -f "$output_dir/issues.md" ]; then
        cp "$output_dir/claude-output.txt" "$output_dir/issues.md"
    fi

    log "  Done in ${duration}s, scoring..."

    # Score with LLM judge
    python3 "$SCRIPT_DIR/score.py" \
        --issues "$output_dir/issues.md" \
        --cve "$cve_id" \
        --bug-pattern "$bug_pattern" \
        --category "$category" \
        --severity "$severity" \
        --affected-files "$affected_files" \
        --description "$description" \
        --duration "$duration"
}

# Calculate aggregate score from results.tsv
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
# Score: exact=1.0, partial=0.5, missed=0.0
score = (exact * 1.0 + partial * 0.5) / total
print(f'{score:.3f}')
"
}

# Run benchmark on CVE subset
run_benchmark() {
    local label="$1"
    shift
    local cves=("$@")

    # Clear results for this run
    local run_results="$SCRIPT_DIR/results-${label}.tsv"
    rm -f "$run_results"
    # Point scorer at run-specific results
    export EDC_RESULTS_FILE="$run_results"

    # Clean experiment work dir
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

# Apply an experiment's skill change
apply_experiment() {
    local exp_name="$1"
    local exp_desc="$2"

    # Use claude to make the skill change
    local prompt="You are modifying EDC skills to improve security analysis capabilities. \
The change to make: $exp_desc

Rules:
- Make the MINIMUM change needed — add a section, checklist, or prompt enhancement
- Do NOT remove existing content
- Do NOT refactor or reorganize existing sections
- Keep the addition focused and concise (10-30 lines max)
- The addition should be general-purpose, not CVE-specific

Make the change now. Edit the appropriate file in the plugins/edc/ directory."

    log "Applying experiment: $exp_name"
    claude -p "$prompt" \
        --cwd "$REPO_ROOT" \
        --allowedTools "Read Edit Grep Glob" \
        --max-turns 10 \
        --output-format text \
        > /dev/null 2>&1 || true
}

# Main autoresearch loop
main() {
    local dry_run=false
    local specific_exp=""
    local full_validation=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run) dry_run=true; shift ;;
            --experiment) specific_exp="$2"; shift 2 ;;
            --full) full_validation=true; shift ;;
            *) echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    mkdir -p "$WORK_DIR"
    ensure_curl_repo

    # Initialize log
    if [ ! -f "$RESULTS_LOG" ]; then
        echo -e "timestamp\texperiment\tbaseline_score\tnew_score\tdelta\tstatus\tdescription" > "$RESULTS_LOG"
    fi

    # Get or compute baseline
    local baseline_score
    if [ -f "$BASELINE_FILE" ]; then
        baseline_score=$(cat "$BASELINE_FILE")
    else
        log "Computing baseline score..."
        baseline_score=$(run_benchmark "baseline" "${FAST_CVES[@]}")
        echo "$baseline_score" > "$BASELINE_FILE"
    fi
    log "Baseline score: $baseline_score"

    # Run experiments
    local exp_index=0
    for exp_def in "${EXPERIMENTS[@]}"; do
        exp_index=$((exp_index + 1))

        IFS='|' read -r exp_name exp_file exp_desc <<< "$exp_def"

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

        # Log result
        echo -e "$(date -Iseconds)\t$exp_name\t$baseline_score\t$new_score\t$delta\t$status\t$exp_desc" >> "$RESULTS_LOG"

        log ""
    done

    log ""
    log "========================================="
    log "Autoresearch complete"
    log "Final score: $baseline_score"
    log "Results log: $RESULTS_LOG"
    log "========================================="
    column -t -s$'\t' "$RESULTS_LOG"
}

main "$@"
