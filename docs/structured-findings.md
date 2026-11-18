# opt-in structured review findings

`edc review` and `edc review-all` can publish machine records alongside the existing human reports:

```sh
edc review --agent pi --diff BASE...HEAD --committed-only --ignore-context --findings-json /absolute/new/findings.json
```

`--findings-json` requires an explicit differential base (`--base`, `--diff`, or the canonical `review diff [base]` form). the coordinator resolves the base to a commit before dispatch. committed candidates and immutable `--include-working-tree` snapshots are supported. `--full` is rejected before model dispatch because working-tree source is mutable. default reviews and legacy report consumers do not change.

the destination must not exist. its parent must exist and paths must not traverse symlink directories; use physical paths, including on macOS. existing files, symlinks, and hardlinks are never overwritten. collisions with the effective combined result path, canonical reports, spawn log, and known generated-context destinations reject before dispatch. in this opt-in mode, reserved coordinator output paths (including `EDC_RESULT_FILE`) must not contain raw parent-directory (`..`) components. these paths reject before normalization or dispatch, even when the traversed directories do not exist; the error identifies the unsupported destination. supply an unambiguous path without parent traversal. ordinary relative/absolute paths, missing ordinary suffixes, and noncolliding symlink aliases without `..` remain supported. native resolution of existing ancestors still detects alias collisions; unresolved reserved links fail closed. this does not relax findings-path containment or change default/legacy writers. raw worker reports and phase results remain under `.git/edc/runs/`. this feature does not install dependencies or make an extra model call.

## worker record contract

source workers append exactly one declared block to their existing staged Markdown report:

````markdown
```edc-findings-v1
{"schemaVersion":1,"status":"complete","findings":[],"limitations":[]}
```
````

`status` describes completion of the **assigned source review**, not the implementation's correctness, delivery verdict, or execution of tests:

| status | meaning |
| --- | --- |
| `complete` | all assigned source and necessary supporting evidence were inspected and scoped analysis finished; findings and limitations may both be nonempty |
| `partial` | some assigned source or necessary supporting evidence was not inspected, or analysis did not finish; limitations identify unreviewed paths or contracts and their effect |
| `unavailable` | no substantive assigned-source review was possible; limitations explain the blocker and findings must be empty |

`No spec available`, `partially delivered`, or unresolved requirement intent does not itself make source review partial. review observable claims without inventing requirements. unexecuted tests/builds/external services, ignored generated context, and unavailable optional tools remain explicit limitations. they require `partial` only when they actually prevent necessary source inspection or analysis. `complete` does not claim runtime verification, exhaustive bug discovery, or complete architectural understanding.

an empty array with `complete` is an explicit no-findings declaration, not a fallback for missing output. `partial` and `unavailable` require nonempty limitations. missing, malformed, duplicate-key, duplicate-block, or invalid records fail machine validation. human formatting outside the block is not parsed. validators preserve explicit partial/unavailable declarations; they never infer complete status from prose. prompt guidance and format validation cannot prove that a model's completeness or no-findings declaration is semantically correct.

each finding has exactly these fields:

| field | contract |
| --- | --- |
| `id` | local token or assigned `phase:module:local` ID; coordinator supplies deterministic namespacing |
| `title`, `description`, `impact`, `recommendation` | complete, nonempty strings |
| `severity` | lowercase `critical`, `high`, `medium`, `low`, `blocker`, `important`, or `advisory` |
| `primaryLocation` | `{ "path": "src/example.js", "startLine": 1, "endLine": 2 }` |
| `relatedLocations` | array of locations with the same schema |
| `verification` | `{ "evidence": ["concrete source/check evidence"], "limitations": ["unexecuted checks or other limits"] }`; evidence is nonempty |

all locations must identify regular UTF-8, nonbinary blobs in the immutable candidate tree. every inclusive line range is validated against those blobs, never the current working tree. paths cannot be absolute, contain traversal components, or refer to symlinks. deleted/base-only files and files inside gitlinks cannot currently serve as machine anchors; use a valid candidate source anchor with an explicit evidence limitation, or retain the invalid record as a reported validation failure. do not invent an anchor to bypass validation.

independently repairable defects use separate records. a shared defect across callers uses related locations, not a separate record per caller. independent lenses remain separately namespaced; there is no deterministic semantic deduplication across lenses.

for input/output contract findings, `description` retains already-established expected versus actual input arity/types and output shape/types. `impact` identifies the affected consumer and consequence. grouping a shared defect or shortening prose must preserve these distinctions; `relatedLocations` identify callers but do not replace the explanation. distinguish source-observed behavior from conditional downstream consequences, retaining concrete support in `verification.evidence` and genuine evidence limits in `verification.limitations`. this guidance uses existing fields; it does not require invented contract facts, effects, extra findings, runtime execution or another model pass.

## consolidation and completeness

security registers every expected module report, including explicit deterministic account-only reports. module-local IDs cannot collide across modules. account-only entries retain provenance and state that they were not reviewed; they are not model-authored zero findings.

quality source workers use canonical IDs. synthesis preserves source completeness declarations and all limitations: nonempty limitations alone do not downgrade complete source reviews, and synthesis cannot upgrade partial/unavailable source reviews. an unfinished synthesis must declare its own incomplete status. synthesis copies all machine records unchanged into one block in `issues.md`, including maintainability records. `complexity.md` contains human summaries referencing those IDs, not another machine block. validation compares synthesis against every expected source report; loss, mutation, or duplication fails. human report placement otherwise retains its existing lens responsibility.

coordinator-generated coverage gaps carry `unavailable` blocks. missing or invalid machine blocks never become empty successful reviews. failed phases, partial source coverage, and available valid findings remain visible. raw reports and existing phase results are retained even when machine validation fails. opt-in machine validation runs before any canonical report promotion; failure preserves prior canonical bytes and publishes an explicit failed findings artifact. final aggregation checks the same sources and current phase statuses, including promotion failures. this does not make filesystem promotion failures transactional.

## published artifact and combined result

the version-1 artifact has `kind: "edc-findings"`, coordinator-supplied `candidate: {commit, base, kind}`, `status`, `phases`, `reports`, `findings`, and `errors`. each finding includes its `phase` and `report` provenance. each report includes its path, SHA256 digest, phase, namespace, status, and limitations. synthesis uses a null namespace. source paths in provenance are run artifacts, not model-authored identity.

`status` is `success`, `success-with-warning`, or `failed`. a failed artifact can contain validated findings from available reports; consumers must inspect status and errors, not just count records. publication/validation failure fails the combined command while preserving all child phase results. the combined result adds `findings: {path, sha256, schemaVersion, status}` when publication succeeds and includes that path in `outputs`. publication failure leaves no success receipt.

these checks establish format, source bounds, provenance, and deterministic completeness. static prompt tests and fake-agent runtime tests do **not** establish improved model recall. a held-out model evaluation requires separate authorization. worker prompts remain permissions, not a filesystem or network sandbox.
