#!/bin/bash
# Security-review task planning and changed-file classification.
# Sourced by edc-review.sh after shared review helpers are defined.

build_mode_impl() {
  local candidate_pre_resolved="$1" target="$2"; shift 2
  local baseline=""
  local no_context_refresh=0
  local ignore_context=0
  local context_available=1
  local full_scope=0 policy=""
  local candidate_evidence_contract="Full review: inspect the repository source directly."
  local -a ignore_patterns=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full)
        full_scope=1
        shift
        ;;
      --base) baseline="$2"; shift 2 ;;
      --ignore)
        [ $# -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; exit 2; }
        ignore_patterns+=("$2")
        shift 2
        ;;
      --context-mode)
        [ $# -ge 2 ] || { echo "ERROR: --context-mode requires a value" >&2; exit 2; }
        shift 2
        ;;
      --include-working-tree)
        [ -z "$policy" ] || { echo "ERROR: choose only one dirty-state policy" >&2; exit 2; }
        policy=include-working-tree
        shift
        ;;
      --committed-only)
        [ -z "$policy" ] || { echo "ERROR: choose only one dirty-state policy" >&2; exit 2; }
        policy=committed-only
        shift
        ;;
      --no-context-refresh)
        no_context_refresh=1
        shift
        ;;
      --ignore-context)
        ignore_context=1
        shift
        ;;
      *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
  done

  # Step 1: resolve one immutable local candidate, then gate context.
  local head evidence_base
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "ERROR: not a git repo" >&2; exit 2; }
  if [ "$candidate_pre_resolved" -ne 1 ] && [ "$full_scope" -ne 1 ] && [[ "$target" != https://* ]] && [[ "$target" != pr:* ]] && [ ! -f "$target" ]; then
    local candidate_file
    candidate_file=$(mktemp "${TMPDIR:-/tmp}/edc-security-plan-candidate-$$.XXXXXX") || exit 1
    edc_candidate_resolve "$target" "$baseline" "$policy" > "$candidate_file" || { local rc=$?; rm -f "$candidate_file"; exit "$rc"; }
    target=$(cat "$candidate_file")
    rm -f "$candidate_file"
    evidence_base="${baseline:-${target}^}"
    candidate_evidence_contract="The immutable candidate commit is \`$target\`. Treat \`git diff ${evidence_base}...${target}\` and blobs read with \`git show ${target}:<path>\` as the sole source evidence. Do not read changed or adjacent source from the mutable working tree. For a deleted path, inspect its baseline blob. For a changed gitlink, resolve the baseline and candidate gitlink SHAs from the parent commits, inspect bytes with \`git -C <submodule-path> diff <baseline-submodule>...<candidate-submodule>\` and \`git -C <submodule-path> show <candidate-submodule>:<path>\`, and repeat for nested gitlinks; when the baseline has no gitlink, enumerate the candidate with \`git -C <submodule-path> ls-tree -r <candidate-submodule>\`. Never use mutable submodule working-tree source as evidence."
  elif [ "$candidate_pre_resolved" -ne 1 ] && [ "$full_scope" -ne 1 ]; then
    edc_candidate_resolve_external "$target" "$baseline" "$policy" || exit $?
    candidate_evidence_contract="The external target/diff named above is the sole differential authority. Do not incorporate local working-tree changes into the review."
  elif [ "$full_scope" -ne 1 ] && git rev-parse --verify "${target}^{commit}" >/dev/null 2>&1; then
    evidence_base="${baseline:-${target}^}"
    candidate_evidence_contract="The immutable candidate commit is \`$target\`. Treat \`git diff ${evidence_base}...${target}\` and blobs read with \`git show ${target}:<path>\` as the sole source evidence. Do not read changed or adjacent source from the mutable working tree. For a deleted path, inspect its baseline blob. For a changed gitlink, resolve the baseline and candidate gitlink SHAs from the parent commits, inspect bytes with \`git -C <submodule-path> diff <baseline-submodule>...<candidate-submodule>\` and \`git -C <submodule-path> show <candidate-submodule>:<path>\`, and repeat for nested gitlinks; when the baseline has no gitlink, enumerate the candidate with \`git -C <submodule-path> ls-tree -r <candidate-submodule>\`. Never use mutable submodule working-tree source as evidence."
  elif [ "$full_scope" -ne 1 ]; then
    candidate_evidence_contract="The external target/diff named above is the sole differential authority. Do not incorporate local working-tree changes into the review."
  fi

  if [ "$ignore_context" -ne 1 ]; then
    if [ ! -f "$MANIFEST" ]; then
      if [ "$no_context_refresh" -eq 1 ]; then
        context_available=0
      else
        echo "CONTEXT_MISSING"
        echo "No $MANIFEST found. Run edc-build before reviewing."
        exit 1
      fi
    fi

    # Structural check: index.md must exist and contain ## headings. Absent or
    # stubbed index.md means edc-build never finished (or wrote junk). In
    # --no-context-refresh mode, do not recover; fall back to a direct review
    # task instead.
    local ctx="$EDC_INDEX"
    if [ "$context_available" -eq 1 ] && { [ ! -f "$ctx" ] || ! grep -q '^##' "$ctx"; }; then
      if [ "$no_context_refresh" -eq 1 ]; then
        context_available=0
      else
        echo "CONTEXT_MISSING"
        echo "$ctx is missing or has no '## ' headings (stub). Run edc-build before reviewing."
        exit 1
      fi
    fi

    local source_commit=""
    if [ "$context_available" -eq 1 ]; then
      source_commit=$(read_manifest_source_commit)
      if [ "$source_commit" != "$head" ] && [ "$no_context_refresh" -ne 1 ]; then
        echo "CONTEXT_STALE"
        echo "Context is stale (built at: $source_commit, HEAD: $head). Run edc-update before reviewing."
        exit 1
      fi
      if [ "$source_commit" != "$head" ] && [ "$no_context_refresh" -eq 1 ]; then
        echo "WARNING: context is stale (built at: $source_commit, HEAD: $head); using it because --no-context-refresh was requested" >&2
      fi
    fi
  fi

  if [ "$full_scope" -eq 1 ] && [ -n "$baseline" ]; then
    echo "ERROR: --full cannot be combined with --base" >&2
    exit 2
  fi

  # Step 2: get changed files, or all tracked files for full scope.
  local files
  if [ "$full_scope" -eq 1 ]; then
    target="HEAD"
    files=$(git ls-files -z | tr '\0' '\n')
  elif [[ "$target" == https://* ]]; then
    local gh_err
    gh_err=$(mktemp "${TMPDIR:-/tmp}/edc-gh-pr-diff-$$.XXXXXX") || exit 1
    if ! files=$(gh pr diff "$target" --name-only 2>"$gh_err"); then
      echo "ERROR: gh pr diff failed for target: $target" >&2
      sed 's/^/gh: /' "$gh_err" >&2
      rm -f "$gh_err"
      exit 2
    fi
    rm -f "$gh_err"
  elif [[ "$target" == pr:* ]]; then
    local gh_err
    gh_err=$(mktemp "${TMPDIR:-/tmp}/edc-gh-pr-diff-$$.XXXXXX") || exit 1
    if ! files=$(gh pr diff "${target#pr:}" --name-only 2>"$gh_err"); then
      echo "ERROR: gh pr diff failed for target: $target" >&2
      sed 's/^/gh: /' "$gh_err" >&2
      rm -f "$gh_err"
      exit 2
    fi
    rm -f "$gh_err"
  elif [ -f "$target" ]; then
    files=$(grep '^+++ b/' "$target" | sed 's|^+++ b/||' || true)
    if [ -z "$files" ]; then
      echo "ERROR: no '+++ b/' lines found in diff file: $target" >&2
      exit 2
    fi
  else
    local base="${baseline:-${target}^}"
    files=$(git diff -z "${base}...${target}" --name-only | tr '\0' '\n')
  fi

  if [ -z "$files" ]; then
    if [ "$full_scope" -eq 1 ]; then
      echo "ERROR: no tracked files found for full security review" >&2
      echo "HINT: add tracked files or run review from the repository root." >&2
    else
      echo "ERROR: no changed files found for target: $target" >&2
      echo "HINT: the resolved candidate has no changes against this base. run 'edc review full --agent <agent>' for a full repo review, or choose another base." >&2
    fi
    exit 2
  fi

  # Filter out tool-internal paths. These are edc scratch state - reviewing
  # them would make the tool eat its own tail (review the context dir,
  # $EDC_REVIEW_TASKS_DIR/ - itself under $EDC_CONTEXT_DIR/ - or prior
  # review-*.md files as if they were source).
  files=$(echo "$files" | grep -Ev "^(${EDC_CONTEXT_DIR}/|review-[^/]+\.md$)" || true)
  files=$(edc_filter_ignored_files "$files" ${ignore_patterns[@]+"${ignore_patterns[@]}"})

  if [ -z "$files" ]; then
    echo "ERROR: no reviewable files after filtering tool output and ignore rules" >&2
    if [ "$full_scope" -eq 1 ]; then
      echo "HINT: full review found only EDC scratch files or files matched by --ignore/.edcignore." >&2
    else
      echo "HINT: target may contain only edc scratch files or files matched by --ignore/.edcignore." >&2
    fi
    exit 2
  fi

  if [ "$ignore_context" -eq 1 ] || [ "$context_available" -eq 0 ]; then
    rm -rf "$EDC_REVIEW_TASKS_DIR"
    mkdir -p "$EDC_REVIEW_TASKS_DIR"

    local file_list context_mode direct_module instruction_1 extra_instruction
    file_list=$(echo "$files" | grep -v '^$' | sed 's/^/- /')

    if [ "$ignore_context" -eq 1 ]; then
      context_mode="ignored"
      direct_module="ignore-context"
      instruction_1="Do not read \`${EDC_INDEX}\`, \`${EDC_ISSUES}\`, or any \`${EDC_CONTEXT_DIR}/\` module docs."
      extra_instruction=$'DO NOT use prebuilt EDC context, even if it exists in this repository.'
    else
      context_mode="no-refresh"
      direct_module="no-context-refresh"
      instruction_1="No usable EDC context was available without building/updating. Review the changed files directly."
      extra_instruction=""
    fi

    printf '%s\n' "$files" | grep -v '^$' | node "$EDC_JSON_CLI" review-direct-manifest "$target" "$baseline" "$head" "$context_mode" "$direct_module" \
      > "$EDC_REVIEW_TASKS_MANIFEST"

    cat > "$EDC_REVIEW_TASKS_DIR/${direct_module}.md" <<TASK
# Review Task: \`${direct_module}\`

## Target
${target}

## Files to review
${file_list}

## Candidate evidence contract
${candidate_evidence_contract}

## Instructions

1. ${instruction_1}
2. Review only the changed files listed above and whatever adjacent source files are necessary to understand the diff.
3. Use the embedded edc-review methodology to perform the full review on the files listed above.
4. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${direct_module}.md\`

DO NOT build or update EDC context.
${extra_instruction}
TASK

    echo "routing summary: context=$context_mode files=$(echo "$files" | grep -cve '^$') modules=1" >&2
    echo ""
    echo "Review tasks ready."
    echo ""
    echo "TASK $EDC_REVIEW_TASKS_DIR/${direct_module}.md"
    return 0
  fi

  # Step 3: classify changed files through the shared batch coverage classifier.
  # Real modules get normal module-review tasks. Contextless paths follow their
  # deterministic reviewPolicy and never load fake module docs.
  if [ ! -f "$CLASSIFY_CLI" ]; then
    echo "ERROR: classify-cli.mjs not found at $CLASSIFY_CLI" >&2
    exit 2
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: node is required for review path classification" >&2
    exit 2
  fi

  local unmatched_policy
  unmatched_policy=$(node "$EDC_JSON_CLI" unmatched-policy "$MANIFEST")
  case "$unmatched_policy" in
    warn-allow|allow|fail) ;;
    *)
      echo "ERROR: invalid policy.unmatchedPathPolicy in $MANIFEST: '$unmatched_policy'" >&2
      echo "HINT: must be one of: warn-allow, allow, fail" >&2
      exit 2
      ;;
  esac

  local ambiguous_count=0 uncovered_count=0 mapped_count=0 contextless_count=0 allowed_unmapped_count=0
  local -a unmapped_unexpected=()
  local -a ambiguous_lines=()
  local -a module_names=()
  local -a module_files=()
  local -a module_types=()
  local -a module_policies=()
  local -a module_contextless_ids=()

  local module_index_result=""

  _module_index() {
    local needle="$1" i
    i=0
    while [ "$i" -lt "${#module_names[@]}" ]; do
      if [ "${module_names[$i]}" = "$needle" ]; then
        module_index_result="$i"
        return 0
      fi
      i=$((i + 1))
    done
    module_index_result=""
    return 1
  }

  _ensure_module() {
    local module="$1" type="${2:-module}" policy="${3:-}" contextless_id="${4:-}" idx
    if _module_index "$module"; then
      idx="$module_index_result"
      module_types[$idx]="$type"
      module_policies[$idx]="$policy"
      module_contextless_ids[$idx]="$contextless_id"
    else
      idx=${#module_names[@]}
      module_names[$idx]="$module"
      module_files[$idx]=""
      module_types[$idx]="$type"
      module_policies[$idx]="$policy"
      module_contextless_ids[$idx]="$contextless_id"
    fi
    module_index_result="$idx"
  }

  _append_module_file() {
    local module="$1" file="$2" type="${3:-module}" policy="${4:-}" contextless_id="${5:-}" idx
    _ensure_module "$module" "$type" "$policy" "$contextless_id"
    idx="$module_index_result"
    module_files[$idx]="${module_files[$idx]}${file}"$'\n'
  }

  _record_contextless() {
    local id="$1" policy="$2" file="$3" module contextless_id
    contextless_id="$id"
    case "$policy" in
      account-only)
        if [ "$id" = "legacy-unmapped" ]; then
          module="allowed-unmapped"
          allowed_unmapped_count=$((allowed_unmapped_count + 1))
        else
          module="contextless-${id}"
        fi
        ;;
      promotion-check)
        module="contextless-promotion-check"
        contextless_id="promotion-check"
        ;;
      no-context-review)
        module="contextless-${id}"
        ;;
      *)
        echo "ERROR: invalid contextless reviewPolicy from classifier: $policy" >&2
        exit 2
        ;;
    esac
    _append_module_file "$module" "$file" "contextless" "$policy" "$contextless_id"
  }

  local classifications
  classifications=$(printf '%s\n' "$files" | node "$CLASSIFY_CLI" "$MANIFEST") || {
    echo "ERROR: classify-cli.mjs failed" >&2
    exit 2
  }

  while IFS=$'\t' read -r file state; do
    [ -z "$file" ] && continue

    case "$state" in
      context-module:*)
        module="${state#context-module:}"
        _append_module_file "$module" "$file" "module"
        mapped_count=$((mapped_count + 1))
        ;;
      contextless:*)
        rest="${state#contextless:}"
        contextless_id="${rest%:*}"
        review_policy="${rest##*:}"
        _record_contextless "$contextless_id" "$review_policy" "$file"
        contextless_count=$((contextless_count + 1))
        ;;
      uncovered)
        uncovered_count=$((uncovered_count + 1))
        _append_module_file "unmapped" "$file" "unmapped"
        unmapped_unexpected+=("$file")
        ;;
      ambiguous)
        ambiguous_count=$((ambiguous_count + 1))
        ambiguous_lines+=("$file")
        ;;
      ignored)
        ;;
      *)
        echo "ERROR: invalid classifier state for $file: $state" >&2
        exit 2
        ;;
    esac
  done <<< "$classifications"

  if [ "$ambiguous_count" -gt 0 ]; then
    echo "ERROR: $ambiguous_count file(s) match multiple modules or contextless entries:" >&2
    local line
    for line in ${ambiguous_lines[@]+"${ambiguous_lines[@]}"}; do
      echo "  $line" >&2
    done
    echo "HINT: edit $MANIFEST - bump priority, tighten match rules, or remove overlapping contextless globs" >&2
    exit 2
  fi

  if [ "${#unmapped_unexpected[@]}" -gt 0 ]; then
    case "$unmatched_policy" in
      fail)
        echo "ERROR: ${#unmapped_unexpected[@]} changed file(s) not mapped to any module or contextless entry (policy=fail):" >&2
        local f
        for f in ${unmapped_unexpected[@]+"${unmapped_unexpected[@]}"}; do
          echo "  $f" >&2
        done
        echo "HINT: add a module rule or contextless.entries coverage in $MANIFEST, then re-run." >&2
        exit 2
        ;;
      warn-allow)
        echo "WARNING: ${#unmapped_unexpected[@]} changed file(s) not mapped to any module or contextless entry (will review under 'unmapped'):" >&2
        local f
        for f in ${unmapped_unexpected[@]+"${unmapped_unexpected[@]}"}; do
          echo "  $f" >&2
        done
        ;;
      allow)
        :
        ;;
    esac
  fi

  echo "routing summary: mapped=$mapped_count contextless=$contextless_count uncovered=$uncovered_count allowed-unmapped=$allowed_unmapped_count modules=${#module_names[@]}" >&2

  # Step 4: write $EDC_REVIEW_TASKS_DIR/
  rm -rf "$EDC_REVIEW_TASKS_DIR"
  mkdir -p "$EDC_REVIEW_TASKS_DIR"

  local sorted_modules
  sorted_modules=$(printf '%s\n' ${module_names[@]+"${module_names[@]}"} | sort)

  # manifest.json (script-internal source of truth for consolidate/verify)
  local context_mode
  if [ "$no_context_refresh" -eq 1 ]; then
    context_mode="no-refresh"
  else
    context_mode="context"
  fi

  local manifest_meta_dir manifest_meta
  manifest_meta_dir="$EDC_REVIEW_TASKS_DIR/.manifest-files"
  manifest_meta="$manifest_meta_dir/modules.tsv"
  mkdir -p "$manifest_meta_dir"
  : > "$manifest_meta"

  while IFS= read -r module; do
    local module_doc="${EDC_MODULES_DIR}/${module}.md"
    local module_idx module_type module_policy module_contextless_id module_file_blob
    _module_index "$module"
    module_idx="$module_index_result"
    module_type="${module_types[$module_idx]:-module}"
    module_policy="${module_policies[$module_idx]:-}"
    module_contextless_id="${module_contextless_ids[$module_idx]:-}"
    module_file_blob="${module_files[$module_idx]}"
    if [ "$module_type" != "module" ]; then
      module_doc=""
    fi
    printf '%s' "$module_file_blob" > "$manifest_meta_dir/$module_idx.files"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$module_idx" "$module" "$module_type" "$module_policy" "$module_contextless_id" "$module_doc" >> "$manifest_meta"
  done <<< "$sorted_modules"

  node "$EDC_JSON_CLI" review-routed-manifest "$target" "$baseline" "$head" "$context_mode" "$manifest_meta" "$manifest_meta_dir" \
    > "$EDC_REVIEW_TASKS_MANIFEST"
  rm -rf "$manifest_meta_dir"

  # per-module task files
  while IFS= read -r module; do
    local file_list baseline_line module_context_line module_idx module_type module_policy module_contextless_id module_file_blob
    _module_index "$module"
    module_idx="$module_index_result"
    module_type="${module_types[$module_idx]:-module}"
    module_policy="${module_policies[$module_idx]:-}"
    module_contextless_id="${module_contextless_ids[$module_idx]:-}"
    module_file_blob="${module_files[$module_idx]}"
    file_list=$(echo "$module_file_blob" | grep -v '^$' | sed 's/^/- /')

    if [ "$module" = "allowed-unmapped" ]; then
      write_allowed_unmapped_report "$module_file_blob"
      continue
    fi

    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "account-only" ]; then
      write_contextless_account_report "$module" "$module_contextless_id" "$module_file_blob"
      continue
    fi

    baseline_line=""
    [ -n "$baseline" ] && baseline_line=$'\n'"## Baseline"$'\n'"${baseline}"

    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "promotion-check" ]; then
      cat > "$EDC_REVIEW_TASKS_DIR/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Candidate evidence contract
${candidate_evidence_contract}

## Instructions

1. This is a promotion check only, not a full module review.
2. Do not read generated module docs; these paths are intentionally contextless.
3. Inspect only the listed diff and the smallest adjacent source needed to decide whether durable agent context now exists.
4. Write a human-readable promotion check report to \`$EDC_REVIEW_TASKS_DIR/report-${module}.md\`.
5. Write the machine-readable result to \`$EDC_REVIEW_TASKS_DIR/result-${module}.json\` with these fields:
   - \`schemaVersion\`: \`1\`
   - \`kind\`: \`"contextless-promotion-check"\`
   - \`status\`: \`"success"\`
   - \`promotionDecision\`: either \`"promote"\` or \`"keep-contextless"\`
   - \`targetModule\`: non-empty module name when \`promotionDecision\` is \`"promote"\`
   - \`reportPath\`: \`"$EDC_REVIEW_TASKS_DIR/report-${module}.md"\`

DO NOT edit \`edc-context/manifest.json\`, \`edc-context/index.md\`, or \`edc-context/modules/*.md\`.
DO NOT perform a full module review.
TASK
      continue
    fi

    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "no-context-review" ]; then
      cat > "$EDC_REVIEW_TASKS_DIR/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Candidate evidence contract
${candidate_evidence_contract}

## Instructions

1. These files are intentionally contextless but risk-bearing.
2. Do not read generated module docs; there is no module context for these paths.
3. Review only the changed files listed above and the smallest adjacent source needed to understand the diff.
4. Use the edc-review skill to perform the full review on the files listed above.
5. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${module}.md\`

DO NOT build or update EDC context.
DO NOT edit \`edc-context/manifest.json\`, \`edc-context/index.md\`, or \`edc-context/modules/*.md\`.
TASK
      continue
    fi

    if [ "$module" = "unmapped" ]; then
      module_context_line="3. NOTE: these files are not matched by the current ${EDC_MANIFEST} routing or contextless coverage. Use only \`${EDC_INDEX}\` for repo-level context; there is no per-module deep context for these paths. State this limitation clearly in the report."
    else
      module_context_line="3. Read \`${EDC_MODULES_DIR}/${module}.md\` if it exists - deep per-module context, invariants, call graphs"
    fi

    cat > "$EDC_REVIEW_TASKS_DIR/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Candidate evidence contract
${candidate_evidence_contract}

## Instructions

1. Read \`${EDC_INDEX}\` - module map, invariants, trust boundaries
2. Read \`${EDC_ISSUES}\` if it exists - cross-reference known issues against the files above
${module_context_line}
4. Use the edc-review skill to perform the full review on the files listed above
5. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${module}.md\`

DO NOT write your own review methodology.
DO NOT skip reading the context files.
USE the edc-review skill.
TASK
  done <<< "$sorted_modules"

  # Done - emit TASK lines for the agent to iterate. Deterministic skipped
  # reports are already complete and must not spawn an agent subprocess.
  echo ""
  echo "Review tasks ready."
  echo ""
  while IFS= read -r module; do
    local module_idx module_type module_policy
    _module_index "$module"
    module_idx="$module_index_result"
    module_type="${module_types[$module_idx]:-module}"
    module_policy="${module_policies[$module_idx]:-}"
    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "account-only" ]; then
      continue
    fi
    echo "TASK $EDC_REVIEW_TASKS_DIR/${module}.md"
  done <<< "$sorted_modules"
}

build_mode() {
  build_mode_impl 0 "$@"
}

build_mode_resolved() {
  build_mode_impl 1 "$@"
}
