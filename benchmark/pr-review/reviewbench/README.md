# offline ReviewBench B-only adapter

this adapter runs the **production combined security + delivery + quality coordinator**, not a benchmark-specific review method. it uses only Python standard libraries and the installed EDC runtime prerequisites. it does not install dependencies, build context, select PRs, judge findings, make repair calls, or enforce network/budget isolation.

## pinned scope

- EDC: `d634519851b9bba41ae7a7b66b90a95681c0ab36`.
- ReviewBench contract: `f223ce33558a6d211fd222b1f7ff2fd7b44403d4`, `AGENT_CONTRACT.md` and `docs/OFFLINE_EVAL.md`.
- exactly two parent-selected PR identities; B only, `--ignore-context`.
- reviewer: `openai-codex/gpt-6.1-sol:high`, Pi, serial execution.
- no production prompt changes or append-only output instruction.

## parent prerequisites

before running this entrypoint, the parent must provide an isolated disposable checkout, pinned runtime checkout, approved Pi installation and credentials, provider-only network policy, disabled hosted research/connectors, resource limits and enforceable accounting/budget policy. keep all golden/reference findings, upstream discussions, later commits, host instructions, unrelated artifacts and generated EDC context unavailable. remove Octocode from the isolated executable search path; the production coordinator probes available tools. `--ignore-context` is a prompt/runtime policy, **not** filesystem or network isolation.

retain both the artifact volume and disposable checkout (including `.git/edc`) after process/container interruption. the adapter sets `TMPDIR` to its durable `tmp/` directory for production in-flight capture files. completed worker traces live under Git-private run state until worker-state copying happens after the coordinator returns. do not discard either volume before reconciliation. do not configure the upstream runner to automatically retry an ambiguous attempt. the adapter is not a hard budget guard, provider supervisor, or source sandbox. the parent owns these controls and its decision to permit execution.

runtime identity supports either a pinned Git checkout or a metadata-free export with `<runtime>/runtime-provenance.json`. configuration still names the **package root**, `/opt/edc`; the real package CLI/bootstrap resolves the production plugin-source preflight at `/opt/edc/plugins/edc`. unrelated source-checkout work is not modified. the runtime must be read-only in the container. backend version and isolation identity are parent assertions, recorded in the receipt; the adapter does not inspect credential state or invoke Pi for preflight.

### exported runtime provenance

use the conventional `/opt/edc/runtime-provenance.json` file, with this exact schema:

```json
{"revision":"d634519851b9bba41ae7a7b66b90a95681c0ab36","files":{"package.json":"<sha256>","pi/index.mjs":"<sha256>","plugins/edc/scripts/edc":"<sha256>"}}
```

the example abbreviates the inventory; all **73** pinned files under `package.json`, `pi/` and `plugins/` are required. the adapter validates relative paths, the complete protected file set, regular single-link files, non-symlink directories and SHA256 bytes. missing, extra, changed, escaping or linked protected files stop execution. other package-root content, such as `install.sh` or the benchmark adapter, is outside this runtime inventory and is not executed as the EDC review coordinator.

a revision string is not proof. `run.py` anchors the canonical inventory digest to `ef8e901b0cd7389d7fc7da72395bf4a5ab09e73bcf727106639a451b978ab242`, independently computed from the pinned Git blobs. canonical encoding is Python `json.dumps(files, sort_keys=True, indent=2)` followed by a newline. rehashing altered files in a manifest that still claims the pin is rejected. the receipt includes both the verified inventory digest and the SHA256 of the exact supplied manifest bytes; formatting changes therefore invalidate receipt reuse without changing the trusted inventory.

the manifest is not a signature or a general package provenance service. the parent owns its generation, the immutable image digest/mount, trusted adapter bytes and enforcement that neither runtime nor adapter changes after validation. the pinned inventory anchor proves the covered file bytes, not the installed Node/Pi binaries, environment, credential isolation or budget policy. Git-checkout mode verifies the same protected bytes and requires the pinned HEAD, without needing a provenance file.

## entrypoint

use `python3 /path/to/benchmark/pr-review/reviewbench/run.py` as the container entrypoint. provide standard `RB_*` contract variables, plus:

| variable | meaning |
| --- | --- |
| `RB_EDC_CONFIG` | absolute path to the parent-authored JSON configuration below |
| `RB_ARTIFACT_DIR` | absent job directory under an existing private mounted artifact parent; stable across resume |
| `RB_REPO` | optional checkout path; default `/work/repo` |

`RB_OUT` must be outside the artifact directory. its parent must already exist. each PR needs its own artifact directory and output. the adapter only executes the PR named by the environment; it does not loop over the pilot manifest.

configuration example (replace placeholders with full lowercase SHAs):

```json
{
  "pilot": [
    {"repo": "https://github.com/owner/repo", "pr_number": 1, "base": "<40-character SHA>", "head": "<40-character SHA>"},
    {"repo": "https://github.com/owner/repo", "pr_number": 2, "base": "<40-character SHA>", "head": "<40-character SHA>"}
  ],
  "runtime": "/opt/edc",
  "model": "openai-codex/gpt-6.1-sol:high",
  "backend_version": "<parent-verified Pi version>",
  "isolation_id": "<parent-frozen policy/image identity>",
  "runtime_settings": {
    "EDC_REVIEW_TIMEOUT": "1800",
    "EDC_AUDIT_TIMEOUT": "1800"
  }
}
```

`runtime_settings` also permits `EDC_PI_EXTENSION_PATH` for a parent-prepared absolute observer entrypoint. its bytes enter identity; extension imports and external policy dependencies must enter the parent isolation identity. no extension is supplied here. parent `PI_CODING_AGENT_DIR` is preserved and its path enters identity, without reading credential/configuration files. the parent must freeze and identify that directory's effective configuration through `isolation_id`; changing bytes at the same path is not detected by this adapter. parent `EDC_PI_MODEL` is preserved when it equals the approved model; a conflicting value stops before review rather than being silently overwritten. other ambient `EDC_*` settings are removed. the adapter disables global EDC config loading, fixes serial/context settings and enables durable production transcript/intermediate retention. it prints effective model/context settings and saves the exact command:

```text
bash /opt/edc/plugins/edc/scripts/edc review --diff BASE...HEAD --committed-only --ignore-context --agent pi
```

PR metadata is retained in identity; `RB_DIFF` must byte-match `git diff BASE...HEAD`. no additional PR-description prompt is injected. normal production delivery/spec discovery remains unchanged.

## final product contract and conversion

verified sources before implementation:

- `plugins/edc/scripts/edc-review-all.sh`: three phase coordinators; four promoted final reports; structured aggregate result.
- `plugins/edc/scripts/edc-review.sh`: final security report concatenates module reports without another model rewrite.
- `plugins/edc/skills/edc-review/reporting.md`: `## Findings`, severity subsections, `- where: file:line`.
- `plugins/edc/skills/edc-delivery-review/references/reporting.md`: two independent axes with `### Findings`, severity subsections and implementation evidence.
- `plugins/edc/skills/edc-audit/references/reporting.md`: synthesized `complexity.md` and `issues.md`.
- `plugins/edc/hooks/lib/json-result-commands.mjs`: phase statuses, outputs, candidate/head identity.
- `tests/unit/no-build-reviews.test.mjs`: production no-context execution and fake-provider boundary.

accepted deterministic subset:

- security: each `## Findings` contains `### [optional severity emoji] CRITICAL|HIGH|MEDIUM|LOW: title` with exactly one `- where:` field, or a sole `### No security findings` with explanation.
- delivery: both `## Goal / Spec Delivery` and `## Architecture Fit` must contain one `### Findings`. accept `#### BLOCKER|IMPORTANT|ADVISORY — title` with exactly one `- implementation evidence:` field, or the explicit body `No findings.`. that zero wording is an accepted adapter convention, not a production guarantee.
- complexity: documented section headings, compact `- file:Lx-Ly: explanation` bullets; accept `None.` or the production no-actionable-findings sentence as explicit empty sections. summary and LOC tables are metrics, not findings. other lists/tables/heading shapes fail conversion rather than disappear.
- issues: `## SEVERITY — title` with one `- where:` field; or `# Known Issues` followed by `No actionable code-quality findings in the inspected scope.`. generated-by comments are permitted.
- the exact deterministic `ignored` context notice is metadata, not a finding.

one finding is emitted per logical subsection/bullet. full finding text is retained as its message; exact output duplicates are removed in first-seen order. no semantic consolidation occurs. quality findings repeated with different wording in both final reports remain separate, not selectively dropped.

locations must be a single explicit `file:line`, `file:start-end` or `file:Lstart-Lend` reference. paths must be repository-relative forward-slash paths without `.`/`..` components. the immutable head Git tree must contain a regular file, and its blob must contain every referenced line. symlinks, binary blobs, deleted/missing files, ambiguous multiple locations and annotated base-relative locations fail conversion. the production candidate contract establishes head-relative evidence; no diff-based or working-tree line guessing occurs.

all four final reports are required. failed phases, warning statuses, coverage-gap markers, unsupported reports, absent usage, wrong observed provider/model and corrupt outputs stop publication. a parse failure can never become `findings: []`. raw reports remain available for diagnosis. this deliberately narrow parser may reject otherwise reasonable production prose; do not weaken it or add a model repair call after a paid failure without approval.

## artifacts and resume

`RB_ARTIFACT_DIR` retains:

- `settings.json`, `result.json`, `exit.json`, stdout/stderr;
- `reports/{security,delivery,complexity,issues}.md` final products;
- `worker-state/`: all production Git-private EDC runs, prompts, task/phase results, intermediate and staged reports;
- `transcripts/*.jsonl`: unchanged delivery Pi event streams, including retries/failures;
- `worker-state/**/transcripts/*.jsonl`: unchanged security/quality worker and synthesis Pi event streams; production worker pools override transcript destinations, so usage validation enumerates these too;
- `tmp/`: durable production scratch/capture location; normal production cleanup removes temporary files after their retained outputs are written;
- production `spawn-log.jsonl` at the job root and in worker-state when emitted (production metrics are best-effort and do not reliably normalize Pi);
- `usage-inventory.json`: availability/model checks, not token/cost totals;
- `findings.json`, `receipt.json`, or structured `failure.json`.

Pi usage comes from raw assistant events across delivery and every retained worker transcript. the adapter does not sum duplicated `message_end`/`agent_end` messages or report unknown cost as zero. the parent must account for every call/retry and distinguish subscription quota, list price and cash cost.

exclusive directory creation is the job claim. source/base/head/tree, metadata/diff, runtime digest, configuration, producer, converter and observer identity must match on resume. every retained artifact is hashed; partial, missing, corrupt or linked artifacts are not reusable successes. a valid completed receipt republishes the same findings without another coordinator invocation. any incomplete/failed claim blocks automatic retry, even if its recorded process no longer exists. absence of a process does not prove provider inactivity.

changing converter/config/source identity blocks reuse in that job directory. do not use a fresh directory to evade this stop. the parent can run `convert_reports` against retained final reports and immutable head bounds for an explicitly approved conversion-only recovery; keep the original attempt and receipt untouched. no automatic model rerun or generic job/cache framework is provided.

## offline checks

fetch full Git history before running these checks; they read the frozen EDC revision, not the harness HEAD. coordinator fixtures create local temporary clones checked out at that revision. the gateway tests require Node 24 for native zstd decoding; CI runs them on Node 24 and the Python/coordinator tests on both supported Node versions.

```sh
python3 -m unittest discover -s benchmark/tests -p 'test_reviewbench*.py'
# only with permission for git init/add/commit inside temporary test directories:
REVIEWBENCH_TEST_GIT_FIXTURES=1 python3 -m unittest discover -s benchmark/tests -p 'test_reviewbench*.py'
node --test benchmark/tests/test_reviewbench_gateway.mjs
```

the integration tests replace only the Pi executable and optional research probe. real production CLI/bootstrap, coordinator, all three lenses, quality synthesis, staging/promotion, structured results and conversion remain active, in both Git-checkout and manifest-verified exported-runtime modes. an unexpected worker/context-build prompt makes the fake provider fail. no real Pi executable or model is called.

## remaining limitations

- live output-format compatibility, container isolation, provider/budget enforcement, pricing, credentials and judging require parent verification.
- no unsupported Markdown repair or semantic file/line mapping; such cases require a product/mapping decision.
- process death can leave complete evidence without a completed receipt. this is deliberately blocked, not automatically retried.
- full repository test suite and live two-PR pilot are not part of these offline checks.
