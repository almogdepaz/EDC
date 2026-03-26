#!/usr/bin/env bash
set -euo pipefail

# EDC Benchmark Runner
# Runs edc analysis on vulnerable code for each CVE, then scores against ground truth.
#
# Usage: ./benchmark/run.sh [--cve CVE-ID] [--repo curl]
# Defaults to all CVEs in all repos.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_FILE="$SCRIPT_DIR/results.tsv"
WORK_DIR="${EDC_BENCH_WORKDIR:-/private/tmp/edc-bench}"

# Parse ground-truth.md and extract CVE entries
parse_ground_truth() {
    local gt_file="$1"
    python3 "$SCRIPT_DIR/parse_gt.py" "$gt_file"
}

# Run EDC analysis on a single CVE
run_single_cve() {
    local repo_name="$1"
    local cve_id="$2"
    local fix_commit="$3"
    local affected_files="$4"
    local category="$5"
    local severity="$6"
    local bug_pattern="$7"
    local repo_url="$8"

    local cve_dir="$WORK_DIR/$repo_name/$cve_id"
    local output_dir="$cve_dir/.context"

    echo "=== $cve_id ($category, $severity) ==="
    echo "    fix: $fix_commit | files: $affected_files"

    # Clone or reuse repo
    if [ ! -d "$cve_dir/.git" ]; then
        mkdir -p "$cve_dir"
        git clone --quiet "$repo_url" "$cve_dir" 2>/dev/null || {
            # If full clone is slow, try from bare cache
            if [ -d "/private/tmp/curl-bare" ]; then
                git clone --quiet /private/tmp/curl-bare "$cve_dir"
            else
                git clone --quiet "$repo_url" "$cve_dir"
            fi
        }
    fi

    # Checkout vulnerable version (parent of fix)
    git -C "$cve_dir" checkout --quiet "${fix_commit}~1" 2>/dev/null || {
        echo "    SKIP: cannot checkout ${fix_commit}~1"
        return 1
    }

    # Clean previous context
    rm -rf "$output_dir"
    mkdir -p "$output_dir"

    # Build the prompt — scoped to affected files
    local file_list=""
    IFS=',' read -ra files <<< "$affected_files"
    for f in "${files[@]}"; do
        f="$(echo "$f" | xargs)" # trim whitespace
        file_list="$file_list $f"
    done

    local prompt="You are performing a security-focused code analysis. \
Analyze the following files in this C project for security vulnerabilities: $file_list

For each file:
1. Read it completely
2. Analyze every function for: buffer overflows, integer overflows, use-after-free, \
double-free, null pointer dereferences, injection, logic errors, race conditions, \
credential leaks, missing validation, unbounded operations
3. Trace data flow from external inputs through transformations to sinks

Write your findings to .context/issues.md with this format for each issue:
### ISSUE-N: <title>
- **severity:** critical|high|medium|low
- **category:** <bug type>
- **file:** <path>:<line range>
- **description:** <what the bug is and why it's exploitable>
- **evidence:** <the specific code pattern that's wrong>

Be thorough. Do not skip functions. Do not assume code is safe."

    # Run claude in headless mode
    echo "    Running EDC analysis..."
    local start_time=$(date +%s)

    (cd "$cve_dir" && claude -p "$prompt" \
        --allowedTools "Read Grep Glob Write Bash" \
        --max-turns 40 \
        --output-format text \
        --dangerously-skip-permissions) \
        > "$output_dir/claude-output.txt" 2>&1 || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Check if issues.md was created
    if [ ! -f "$output_dir/issues.md" ]; then
        # Maybe claude wrote findings in stdout but not to file
        echo "    WARNING: .context/issues.md not created, extracting from stdout"
        cp "$output_dir/claude-output.txt" "$output_dir/issues.md"
    fi

    echo "    Done in ${duration}s"

    # Score this CVE
    python3 "$SCRIPT_DIR/score.py" \
        --issues "$output_dir/issues.md" \
        --cve "$cve_id" \
        --bug-pattern "$bug_pattern" \
        --category "$category" \
        --severity "$severity" \
        --affected-files "$affected_files"
}

# Main
main() {
    local filter_cve=""
    local filter_repo=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --cve) filter_cve="$2"; shift 2 ;;
            --repo) filter_repo="$2"; shift 2 ;;
            *) echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    mkdir -p "$WORK_DIR"

    # Initialize results file
    if [ ! -f "$RESULTS_FILE" ]; then
        echo -e "timestamp\tcve\tcategory\tseverity\tfound\tconfidence\tduration\tnotes" > "$RESULTS_FILE"
    fi

    # Iterate repos
    for repo_dir in "$SCRIPT_DIR"/*/; do
        local repo_name="$(basename "$repo_dir")"
        [ -n "$filter_repo" ] && [ "$repo_name" != "$filter_repo" ] && continue

        local gt_file="$repo_dir/ground-truth.md"
        [ ! -f "$gt_file" ] && continue

        # Determine repo URL
        local repo_url=""
        case "$repo_name" in
            curl) repo_url="https://github.com/curl/curl.git" ;;
            *) echo "Unknown repo: $repo_name"; continue ;;
        esac

        echo "Processing $repo_name..."
        echo ""

        # Parse and iterate CVEs
        while IFS='|' read -r cve_id fix_commit affected_files category severity bug_pattern; do
            [ -n "$filter_cve" ] && [ "$cve_id" != "$filter_cve" ] && continue

            run_single_cve "$repo_name" "$cve_id" "$fix_commit" "$affected_files" \
                "$category" "$severity" "$bug_pattern" "$repo_url" || true

            echo ""
        done < <(parse_ground_truth "$gt_file")
    done

    echo "=== Results ==="
    column -t -s$'\t' "$RESULTS_FILE"
}

main "$@"
