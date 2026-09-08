#!/usr/bin/env bash
# t14-resolve-prompt-decoupled: pin the contract that resolve_prompt is
# self-contained — emits SKILL.md content for all agents, never slash
# commands like `/edc:edc-build`. This guarantees the CLI works without
# any agent-side plugin/slash-command system installed.
#
# Also pins that review prompts embed the FULL skill bundle inline
# (SKILL.md + methodology + adversarial + reporting + patterns) so the
# subagent has zero room to improvise its own methodology.
#
# Run from repo root: bash tests/hardening/t14-resolve-prompt-decoupled.sh
set -uo pipefail

SCRIPT="plugins/edc/scripts/edc-lib.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }
SOURCE_ROOT="$(pwd)/plugins/edc"

# shellcheck source=lib/check.sh
. "$(dirname "$0")/lib/check.sh"
check_init

echo "=== T14: resolve_prompt CLI/plugin decoupling ==="

# Set up a hermetic trusted package layout so prompt resolution cannot depend
# on the user's global install or a repo-local legacy cache.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TRUSTED_PACKAGE="$TMP/trusted-package"
PROMPT_BUNDLES_DIR="$TRUSTED_PACKAGE/prompt-bundles"
PUBLIC_SKILLS_DIR="$TRUSTED_PACKAGE/skills"
mkdir -p "$TRUSTED_PACKAGE/scripts" "$TRUSTED_PACKAGE/hooks/lib" \
         "$PROMPT_BUNDLES_DIR/edc-build-impl" "$PROMPT_BUNDLES_DIR/edc-update-impl" \
         "$PROMPT_BUNDLES_DIR/edc-context-curator-impl" "$PROMPT_BUNDLES_DIR/edc-context-curator-edit-impl" \
         "$PUBLIC_SKILLS_DIR/edc-audit/references" "$PUBLIC_SKILLS_DIR/edc-review"
cp "$SOURCE_ROOT/scripts/edc-lib.sh" "$TRUSTED_PACKAGE/scripts/edc-lib.sh"
cp "$SOURCE_ROOT/hooks/lib/runtime-manifest.mjs" "$TRUSTED_PACKAGE/hooks/lib/runtime-manifest.mjs"
SCRIPT_ABS="$TRUSTED_PACKAGE/scripts/edc-lib.sh"

echo "BUILD_SKILL_MARKER" > "$PROMPT_BUNDLES_DIR/edc-build-impl/SKILL.md"
echo "UPDATE_SKILL_MARKER" > "$PROMPT_BUNDLES_DIR/edc-update-impl/SKILL.md"
echo "CURATOR_SKILL_MARKER" > "$PROMPT_BUNDLES_DIR/edc-context-curator-impl/SKILL.md"
echo "CURATOR_EDIT_SKILL_MARKER" > "$PROMPT_BUNDLES_DIR/edc-context-curator-edit-impl/SKILL.md"
echo "AUDIT_SKILL_MARKER" > "$PUBLIC_SKILLS_DIR/edc-audit/SKILL.md"
echo "AUDIT_SCOPE_MARKER" > "$PUBLIC_SKILLS_DIR/edc-audit/references/scope-and-standards.md"
echo "AUDIT_SMELL_MARKER" > "$PUBLIC_SKILLS_DIR/edc-audit/references/smell-baseline.md"
echo "AUDIT_CHECKS_MARKER" > "$PUBLIC_SKILLS_DIR/edc-audit/references/quality-checks.md"
echo "AUDIT_REPORTING_MARKER" > "$PUBLIC_SKILLS_DIR/edc-audit/references/reporting.md"
echo "REVIEW_SKILL_MARKER" > "$PUBLIC_SKILLS_DIR/edc-review/SKILL.md"
echo "METHODOLOGY_MARKER" > "$PUBLIC_SKILLS_DIR/edc-review/methodology.md"
echo "ADVERSARIAL_MARKER" > "$PUBLIC_SKILLS_DIR/edc-review/adversarial.md"
echo "REPORTING_MARKER" > "$PUBLIC_SKILLS_DIR/edc-review/reporting.md"
echo "PATTERNS_MARKER" > "$PUBLIC_SKILLS_DIR/edc-review/patterns.md"

TASK_FILE="$TMP/task.md"
echo "TASK_CONTENT_MARKER" > "$TASK_FILE"
WORK="$TMP/work"
mkdir -p "$WORK/.edc/skills/edc-build-impl"
echo "REPO_SKILL_DECOY" > "$WORK/.edc/skills/edc-build-impl/SKILL.md"

OCTOCODE_BIN="$TMP/octocode-bin"
mkdir -p "$OCTOCODE_BIN"
cat > "$OCTOCODE_BIN/octocode" <<'MOCK'
#!/usr/bin/env bash
[ -z "${OCTOCODE_PROBE_LOG:-}" ] || printf 'probe\n' >> "$OCTOCODE_PROBE_LOG"
if [ "${OCTOCODE_FAKE_FAIL:-0}" = "1" ]; then
  [ "${OCTOCODE_FAKE_DIAGNOSTIC:-0}" = "1" ] && printf 'OCTOCODE_FAKE_PROBE_DIAGNOSTIC\n' >&2
  exit 1
fi
if [ "${OCTOCODE_FAKE_HANG:-0}" = "1" ]; then
  while :; do :; done
fi
path_probe_kind=""
case "${1:-}:${2:-}" in
  tools:localSearch) path_probe_kind="unified" ;;
  tools:localViewStructure) path_probe_kind="legacy" ;;
esac
if [ -n "$path_probe_kind" ]; then
  [ "${3:-}" = "--queries" ] || exit 2
  node -e '
const payload = JSON.parse(process.argv[1]);
const query = payload?.queries?.[0];
const operationMatches = process.argv[2] === "unified"
  ? query?.operation === "tree"
  : query?.operation === undefined;
if (payload.queries.length !== 1 || query?.path !== process.cwd() || query?.maxDepth !== 1 || !operationMatches) process.exit(1);
' "${4:-}" "$path_probe_kind" || exit 2
  if [ "${OCTOCODE_FAKE_PATH_REJECT:-0}" = "1" ]; then
    [ "${OCTOCODE_FAKE_DIAGNOSTIC:-0}" = "1" ] && printf 'OCTOCODE_FAKE_PATH_DIAGNOSTIC\n' >&2
    printf '%s\n' '{"results":[{"index":0,"status":"error","data":{"errorCode":"pathValidationFailed"}}]}'
    exit 5
  fi
  printf '%s\n' '{"results":[{"index":0,"data":{"files":[]}}]}'
  exit 0
fi
[ "${1:-}" = "tools" ] && [ "${2:-}" = "--json" ] && [ "${3:-}" = "--compact" ] || exit 2
case "${OCTOCODE_FAKE_CATALOG:-unified}" in
  legacy)
    printf '%s\n' '{"kind":"octocode.toolCatalog","version":1,"toolCount":15,"tools":[{"name":"ghSearchCode"},{"name":"ghSearchRepos"},{"name":"ghSearchPullRequests"},{"name":"ghSearchIssues"},{"name":"ghSearchCommits"},{"name":"ghGetFileContent"},{"name":"ghViewRepoStructure"},{"name":"ghCloneRepo"},{"name":"localSearchCode"},{"name":"localFindFiles"},{"name":"localFindDeadCode"},{"name":"localGetFileContent"},{"name":"localViewStructure"},{"name":"lspGetSemantics"},{"name":"npmSearch"}]}'
    ;;
  unified)
    printf '%s\n' '{"kind":"octocode.toolCatalog","version":1,"toolCount":10,"tools":[{"name":"ghSearch","availability":{"enabled":true}},{"name":"ghGetFileContent","availability":{"enabled":true}},{"name":"ghSearchHistory","availability":{"enabled":true}},{"name":"ghGetHistoryItem","availability":{"enabled":true}},{"name":"npmSearch","availability":{"enabled":true}},{"name":"ghCloneRepo","availability":{"enabled":false}},{"name":"localSearch","availability":{"enabled":true}},{"name":"localAnalyzeGraph","availability":{"enabled":true}},{"name":"localGetFileContent","availability":{"enabled":true}},{"name":"lspGetSemantics","availability":{"enabled":true}}]}'
    ;;
  partial)
    printf '%s\n' '{"kind":"octocode.toolCatalog","version":1,"tools":[{"name":"localSearch","availability":{"enabled":true}},{"name":"localAnalyzeGraph","availability":{"enabled":true}}]}'
    ;;
  legacy-disabled)
    printf '%s\n' '{"kind":"octocode.toolCatalog","version":1,"toolCount":15,"tools":[{"name":"ghSearchCode"},{"name":"ghSearchRepos"},{"name":"ghSearchPullRequests"},{"name":"ghSearchIssues"},{"name":"ghSearchCommits"},{"name":"ghGetFileContent"},{"name":"ghViewRepoStructure"},{"name":"ghCloneRepo"},{"name":"localSearchCode","availability":{"enabled":false}},{"name":"localFindFiles"},{"name":"localFindDeadCode"},{"name":"localGetFileContent"},{"name":"localViewStructure"},{"name":"lspGetSemantics"},{"name":"npmSearch"}]}'
    ;;
  nul-smuggled)
    printf '%s\0%s\n' '{"kind":"octocode.tool' 'Catalog","version":1,"toolCount":10,"tools":[{"name":"ghSearch","availability":{"enabled":true}},{"name":"ghGetFileContent","availability":{"enabled":true}},{"name":"ghSearchHistory","availability":{"enabled":true}},{"name":"ghGetHistoryItem","availability":{"enabled":true}},{"name":"npmSearch","availability":{"enabled":true}},{"name":"ghCloneRepo","availability":{"enabled":false}},{"name":"localSearch","availability":{"enabled":true}},{"name":"localAnalyzeGraph","availability":{"enabled":true}},{"name":"localGetFileContent","availability":{"enabled":true}},{"name":"lspGetSemantics","availability":{"enabled":true}}]}'
    ;;
  unified-fail)
    printf '%s\n' '{"kind":"octocode.toolCatalog","version":1,"toolCount":10,"tools":[{"name":"ghSearch","availability":{"enabled":true}},{"name":"ghGetFileContent","availability":{"enabled":true}},{"name":"ghSearchHistory","availability":{"enabled":true}},{"name":"ghGetHistoryItem","availability":{"enabled":true}},{"name":"npmSearch","availability":{"enabled":true}},{"name":"ghCloneRepo","availability":{"enabled":false}},{"name":"localSearch","availability":{"enabled":true}},{"name":"localAnalyzeGraph","availability":{"enabled":true}},{"name":"localGetFileContent","availability":{"enabled":true}},{"name":"lspGetSemantics","availability":{"enabled":true}}]}'
    exit 1
    ;;
  malformed)
    printf '%s\n' '{not-json'
    ;;
  *)
    exit 2
    ;;
esac
MOCK
chmod +x "$OCTOCODE_BIN/octocode"

# HOME agent skill trees contain only decoys; expected markers exist solely in
# the trusted package fixture above.
HOME_DECOY_SKILLS="$TMP/home-decoy-skills"
mkdir -p "$TMP/home/.edc/skills" "$TMP/home/.cursor/skills" "$TMP/home/.codex/skills" \
         "$HOME_DECOY_SKILLS/edc-build-impl"
echo "HOME_SKILL_DECOY" > "$HOME_DECOY_SKILLS/edc-build-impl/SKILL.md"
cp -R "$HOME_DECOY_SKILLS/." "$TMP/home/.edc/skills/"
cp -R "$HOME_DECOY_SKILLS/." "$TMP/home/.cursor/skills/"
cp -R "$HOME_DECOY_SKILLS/." "$TMP/home/.codex/skills/"

run_resolve() {
  local agent="$1"; shift
  (cd "$WORK" && HOME="$TMP/home" EDC_AGENT_CLI="$agent" \
    bash -c '. "$1" && shift && resolve_prompt "$@"' fixture "$SCRIPT_ABS" "$@" 2>&1)
}

# ── 14.1: claude branch never emits slash commands ──────────────────────────
for action in build update curator curator-edit audit; do
  out=$(run_resolve claude "$action")
  if echo "$out" | grep -q '^/edc:'; then
    check "claude $action: no slash command in output" 0
    echo "  output preview: $(echo "$out" | head -3)"
  else
    check "claude $action: no slash command in output" 1
  fi
done

# review prompt should also not contain slash commands
out=$(run_resolve claude review "$TASK_FILE")
if echo "$out" | grep -q '/edc:'; then
  check "claude review: no slash command in output" 0
else
  check "claude review: no slash command in output" 1
fi

# ── 14.2: claude branch emits skill content for build/update/curator/audit ──
for action_skill in "build:BUILD_SKILL_MARKER" \
                    "update:UPDATE_SKILL_MARKER" \
                    "curator:CURATOR_SKILL_MARKER" \
                    "curator-edit:CURATOR_EDIT_SKILL_MARKER" \
                    "audit:AUDIT_SKILL_MARKER"; do
  action="${action_skill%%:*}"
  marker="${action_skill##*:}"
  out=$(run_resolve claude "$action")
  if echo "$out" | grep -qF "$marker"; then
    check "claude $action: emits SKILL.md content ($marker)" 1
  else
    check "claude $action: emits SKILL.md content ($marker)" 0
  fi
done

# ── 14.2b: audit prompt embeds the full audit bundle ───────────────────────
out=$(run_resolve claude audit)
all_audit_present=1
for marker in "AUDIT_SKILL_MARKER" \
              "AUDIT_SCOPE_MARKER" \
              "AUDIT_SMELL_MARKER" \
              "AUDIT_CHECKS_MARKER" \
              "AUDIT_REPORTING_MARKER"; do
  echo "$out" | grep -qF "$marker" || all_audit_present=0
done
check "claude audit: embeds full audit bundle (5 markers)" "$all_audit_present"

# ── 14.3: build/update arg-string forwarding ────────────────────────────────
out=$(run_resolve claude build --force --focus broker)
if echo "$out" | grep -Eq "HOME_SKILL_DECOY|REPO_SKILL_DECOY"; then
  check "claude build: ignores HOME and repo skill decoys" 0
else
  check "claude build: ignores HOME and repo skill decoys" 1
fi
if echo "$out" | grep -qF 'CLI ARGUMENTS (JSON argv): ["--force","--focus","broker"]'; then
  check "claude build: arg-string prefixed when args provided" 1
else
  check "claude build: arg-string prefixed when args provided" 0
fi

out=$(run_resolve claude build)
if echo "$out" | grep -qF "CLI ARGUMENTS (JSON argv):"; then
  check "claude build: NO arg-string prefix when no args" 0
else
  check "claude build: NO arg-string prefix when no args" 1
fi

# ── 14.4: review prompt embeds the FULL skill bundle ────────────────────────
out=$(run_resolve claude review "$TASK_FILE")
for marker in "TASK_CONTENT_MARKER" \
              "REVIEW_SKILL_MARKER" \
              "METHODOLOGY_MARKER" \
              "ADVERSARIAL_MARKER" \
              "REPORTING_MARKER" \
              "PATTERNS_MARKER"; do
  if echo "$out" | grep -qF "$marker"; then
    check "claude review: embeds $marker" 1
  else
    check "claude review: embeds $marker" 0
  fi
done

# ── 14.5: review prompt has the strict no-improvise prefix ──────────────────
if echo "$out" | grep -qF "Do not improvise"; then
  check "claude review: includes 'Do not improvise' directive" 1
else
  check "claude review: includes 'Do not improvise' directive" 0
fi

# ── 14.6: cursor and codex follow the same contract ─────────────────────────
for agent in cursor codex; do
  for action_skill in "build:BUILD_SKILL_MARKER" \
                      "update:UPDATE_SKILL_MARKER" \
                      "curator:CURATOR_SKILL_MARKER" \
                      "curator-edit:CURATOR_EDIT_SKILL_MARKER" \
                      "audit:AUDIT_SKILL_MARKER"; do
    action="${action_skill%%:*}"
    marker="${action_skill##*:}"
    out=$(run_resolve "$agent" "$action")
    if echo "$out" | grep -qF "$marker"; then
      check "$agent $action: emits SKILL.md content ($marker)" 1
    else
      check "$agent $action: emits SKILL.md content ($marker)" 0
    fi
  done

  out=$(run_resolve "$agent" audit)
  all_audit_present=1
  for marker in "AUDIT_SKILL_MARKER" "AUDIT_SCOPE_MARKER" \
                "AUDIT_SMELL_MARKER" "AUDIT_CHECKS_MARKER" \
                "AUDIT_REPORTING_MARKER"; do
    echo "$out" | grep -qF "$marker" || all_audit_present=0
  done
  check "$agent audit: embeds full audit bundle (5 markers)" "$all_audit_present"

  out=$(run_resolve "$agent" review "$TASK_FILE")
  all_present=1
  for marker in "TASK_CONTENT_MARKER" "REVIEW_SKILL_MARKER" \
                "METHODOLOGY_MARKER" "ADVERSARIAL_MARKER" \
                "REPORTING_MARKER" "PATTERNS_MARKER"; do
    echo "$out" | grep -qF "$marker" || all_present=0
  done
  check "$agent review: embeds full skill bundle (6 markers)" "$all_present"
done

# ── 14.7: coordinator detects a supported structured Octocode catalog ───────
for action in update audit; do
  out=$(OCTOCODE_FAKE_CATALOG=unified PATH="$OCTOCODE_BIN:$PATH" run_resolve claude "$action")
  unified_contract=1
  for marker in "OCTOCODE_STATUS: available" \
                'octocode tools localSearch --queries '\''{"queries":[{"path":"<assigned-absolute-path>","operation":"tree","maxDepth":2},{"path":"<assigned-absolute-path>","operation":"text","searchText":"<symbol-or-pattern>"}]}'\'' --compact --no-color' \
                'octocode tools localSearch --queries '\''{"queries":[{"path":"<assigned-absolute-path>","operation":"structural","pattern":"<ast-pattern-from-lexical-anchor>"}]}'\'' --compact --no-color' \
                'octocode tools lspGetSemantics --queries '\''{"queries":[{"uri":"<absolute-file-path>","type":"references","symbolName":"<symbol-from-exact-read>","lineHint":123}]}'\'' --compact --no-color' \
                'octocode tools localAnalyzeGraph --queries '\''{"queries":[{"path":"<assigned-absolute-repository-root>","operation":"dependencies","file":"<repository-relative-file>","depth":2},{"path":"<assigned-absolute-repository-root>","operation":"dependents","file":"<repository-relative-file>","depth":2}]}'\'' --compact --no-color' \
                "AST/structural search only for JavaScript, TypeScript, or Python syntax questions" \
                "lexical search and native exact reads for shell or unsupported languages" \
                "lexical search" \
                "native exact reads" \
                "smallest runnable verification" \
                "must not prove dead code or zero references" \
                "Graph analysis is bounded to importable files and does not observe shell execution edges or dynamic entrypoints" \
                "Confirm those relationships with lexical search, exact reads, and the smallest runnable verification" \
                "existing Read, Grep, Glob, and Bash tools"; do
    echo "$out" | grep -qF "$marker" || unified_contract=0
  done
  echo "$out" | grep -qF 'localViewStructure' && unified_contract=0
  echo "$out" | grep -qF 'localSearchCode' && unified_contract=0
  check "claude $action: emits v19 unified catalog guidance" "$unified_contract"
done

out=$(OCTOCODE_FAKE_CATALOG=legacy PATH="$OCTOCODE_BIN:$PATH" run_resolve claude review "$TASK_FILE")
legacy_contract=1
for marker in "OCTOCODE_STATUS: available" \
              'octocode tools localViewStructure --queries '\''{"queries":[{"path":"<assigned-absolute-path>","maxDepth":2},{"path":"<focused-absolute-subpath>","maxDepth":2}]}'\'' --compact --no-color' \
              'octocode tools localSearchCode --queries '\''{"queries":[{"path":"<assigned-absolute-path>","searchText":"<symbol-or-pattern>"},{"path":"<assigned-absolute-path>","searchText":"<related-symbol-or-pattern>"}]}'\'' --compact --no-color'; do
  echo "$out" | grep -qF "$marker" || legacy_contract=0
done
echo "$out" | grep -qF 'tools localSearch --queries' && legacy_contract=0
check "claude review: emits v18 legacy catalog guidance" "$legacy_contract"

for catalog in partial malformed legacy-disabled nul-smuggled unified-fail; do
  out=$(OCTOCODE_FAKE_CATALOG="$catalog" PATH="$OCTOCODE_BIN:$PATH" run_resolve claude update)
  unavailable_catalog_contract=1
  echo "$out" | grep -qF "OCTOCODE_STATUS: unavailable" || unavailable_catalog_contract=0
  echo "$out" | grep -qF "Do not install or configure Octocode" || unavailable_catalog_contract=0
  echo "$out" | grep -qF 'octocode tools ' && unavailable_catalog_contract=0
  check "$catalog Octocode catalog emits unavailable fallback state" "$unavailable_catalog_contract"
done

out=$(OCTOCODE_FAKE_FAIL=1 OCTOCODE_FAKE_DIAGNOSTIC=1 PATH="$OCTOCODE_BIN:$PATH" run_resolve claude update)
unavailable_contract=1
for marker in "OCTOCODE_STATUS: unavailable" \
              "Do not install or configure Octocode" \
              "existing Read, Grep, Glob, and Bash tools"; do
  echo "$out" | grep -qF "$marker" || unavailable_contract=0
done
if echo "$out" | grep -qF "OCTOCODE_STATUS: available" \
  || echo "$out" | grep -qF "OCTOCODE_FAKE_PROBE_DIAGNOSTIC"; then
  unavailable_contract=0
fi
check "broken Octocode CLI quietly emits unavailable fallback state" "$unavailable_contract"

for catalog in unified legacy; do
  path_probe_log="$TMP/$catalog-path-probes"
  out=$(OCTOCODE_FAKE_CATALOG="$catalog" OCTOCODE_FAKE_PATH_REJECT=1 OCTOCODE_FAKE_DIAGNOSTIC=1 \
    OCTOCODE_PROBE_LOG="$path_probe_log" PATH="$OCTOCODE_BIN:$PATH" run_resolve claude update)
  path_rejection_contract=1
  path_probe_count=0
  [ ! -f "$path_probe_log" ] || path_probe_count=$(wc -l < "$path_probe_log" | tr -d ' ')
  [ "$path_probe_count" -eq 2 ] || path_rejection_contract=0
  echo "$out" | grep -qF "OCTOCODE_STATUS: unavailable" || path_rejection_contract=0
  echo "$out" | grep -qF "Do not install or configure Octocode" || path_rejection_contract=0
  if echo "$out" | grep -qF "OCTOCODE_STATUS: available" \
    || echo "$out" | grep -qF "OCTOCODE_FAKE_PATH_DIAGNOSTIC"; then
    path_rejection_contract=0
  fi
  check "$catalog Octocode repository-path rejection quietly emits unavailable fallback state" "$path_rejection_contract"
done

preseeded_probe_log="$TMP/preseeded-probes"
out=$(EDC_OCTOCODE_CAPABILITY_STATE=available OCTOCODE_PROBE_LOG="$preseeded_probe_log" OCTOCODE_FAKE_FAIL=1 PATH="$OCTOCODE_BIN:$PATH" run_resolve claude update)
preseeded_contract=1
preseeded_probe_count=0
[ ! -f "$preseeded_probe_log" ] || preseeded_probe_count=$(wc -l < "$preseeded_probe_log" | tr -d ' ')
[ "$preseeded_probe_count" -eq 1 ] || preseeded_contract=0
echo "$out" | grep -qF "OCTOCODE_STATUS: unavailable" || preseeded_contract=0
if echo "$out" | grep -qF "OCTOCODE_STATUS: available"; then
  preseeded_contract=0
fi
check "caller-preseeded Octocode state is ignored and probed once" "$preseeded_contract"

SECONDS=0
out=$(OCTOCODE_FAKE_HANG=1 PATH="$OCTOCODE_BIN:$PATH" run_resolve claude update)
hanging_duration=$SECONDS
hanging_contract=1
for marker in "OCTOCODE_STATUS: unavailable" \
              "Do not install or configure Octocode" \
              "existing Read, Grep, Glob, and Bash tools"; do
  echo "$out" | grep -qF "$marker" || hanging_contract=0
done
[ "$hanging_duration" -lt 5 ] || hanging_contract=0
check "hanging Octocode CLI promptly emits unavailable fallback state" "$hanging_contract"

NO_OCTOCODE_PATH="$TMP/no-octocode-bin"
mkdir -p "$NO_OCTOCODE_PATH"
out=$(EDC_AGENT_CLI=claude bash -c '
  . "$1"
  cat() { /bin/cat "$@"; }
  PATH="$2"
  _emit_octocode_research_guidance
' bash "$SCRIPT_ABS" "$NO_OCTOCODE_PATH")
absent_contract=1
for marker in "OCTOCODE_STATUS: unavailable" \
              "Do not install or configure Octocode" \
              "existing Read, Grep, Glob, and Bash tools"; do
  echo "$out" | grep -qF "$marker" || absent_contract=0
done
check "absent Octocode command emits unavailable fallback state" "$absent_contract"

# ── 14.8: missing skill produces clear error ────────────────────────────────
rm "$PROMPT_BUNDLES_DIR/edc-build-impl/SKILL.md"
out=$(run_resolve claude build 2>&1 || true)
if echo "$out" | grep -q "skill 'edc-build-impl' not found"; then
  check "claude build: missing skill produces clear error" 1
else
  check "claude build: missing skill produces clear error" 0
fi

# ── 14.9: missing review supporting file produces clear error ───────────────
echo "REVIEW_SKILL_MARKER" > "$PUBLIC_SKILLS_DIR/edc-review/SKILL.md"  # restore
echo "BUILD_SKILL_MARKER" > "$PROMPT_BUNDLES_DIR/edc-build-impl/SKILL.md"   # restore
rm "$PUBLIC_SKILLS_DIR/edc-review/methodology.md"
out=$(run_resolve claude review "$TASK_FILE" 2>&1 || true)
if echo "$out" | grep -q "review skill bundle incomplete"; then
  check "claude review: missing methodology.md produces clear error" 1
else
  check "claude review: missing methodology.md produces clear error" 0
fi

check_summary "T14"
