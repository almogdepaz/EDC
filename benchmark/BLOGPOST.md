**Autoresearch for Code Analysis: Using LLMs to Tune LLM Prompts**

---

most AI coding tools ship prompts based on vibes. someone writes "analyze this code for vulnerabilities," tries it on a few examples, says "looks good," ships it. no measurement, no iteration loop, no way to know if a prompt change helped or hurt.

we built the opposite: a closed-loop system that treats prompt engineering like hyperparameter tuning. modify one variable, measure the effect, keep or discard. repeat until the score stops improving.

**the setup**

EDC is a claude code plugin that builds deep architectural context for codebases and uses that context to find bugs. it works across languages — C, Go, Rust, TypeScript, whatever. the core is a set of skill files: markdown documents that tell the LLM how to think about code.

the question we couldn't answer: are these prompts actually good? are some sections deadweight? are we missing analysis techniques that would catch more bugs?

**building ground truth**

you can't optimize what you can't measure. we needed a scoring function.

we picked curl — 150k lines of C with 100+ CVEs, each meticulously documented by daniel stenberg with exact fix commits, affected files, and detailed writeups. the best-documented vulnerability history in open source.

we curated 11 CVEs across 9 bug categories: heap overflows, use-after-free, stack overflows, integer overflows, credential leaks, protocol injection, logic errors. for each one, we have the exact commit that introduced the fix, which means `fix_commit~1` is the vulnerable version.

**the benchmark**

for each CVE:
1. checkout the vulnerable code
2. run the analysis scoped to the affected files
3. check if the output identifies the known vulnerability

the scorer has two phases. first, a fast keyword filter catches obvious misses without burning API calls. if the keywords suggest a potential match, an LLM judge (a separate, clean-slate claude call) reads both the analysis output and the CVE description and classifies: **exact** (found the root cause), **partial** (found related issue, wrong root cause), or **missed**.

this two-phase approach matters. our first scorer was keyword-only and said we found 4/4 CVEs. the LLM judge corrected that to 3/4 — one "hit" was actually a different buffer overflow in the same file. keyword matching can't distinguish "found the right bug" from "found a bug nearby." garbage scoring means garbage optimization.

**baseline: 9/11 exact**

the initial run found 9 of 11 CVEs exactly. not bad for a general-purpose analysis prompt. the two misses were revealing:

- **CVE-2023-38545** (SOCKS5 heap overflow): a state machine bug where a flag gets set wrong during a slow non-blocking handshake. our prompts focused on memory safety but didn't explicitly analyze state transitions or flag lifecycles. standard buffer overflow analysis found a *different* overflow in the same file.

- **CVE-2020-8285** (FTP wildcard stack overflow): found unbounded recursion, but in `wc_statemach()` instead of the wildcard matching function. partial credit — right bug class, wrong location.

**the autoresearch loop**

inspired by karpathy's autoresearch: modify → measure → keep/discard → repeat.

each experiment changes ONE thing in the skill files. additions: "add fault injection thinking." "add taint tracing." subtractions: "remove the rationalizations table." "remove 5 Whys framework." then re-run the benchmark and compare.

the first experiment added explicit state machine analysis prompts: "trace every state transition," "for non-blocking re-entry, are decisions from the previous call still valid?" this moved CVE-2023-38545 from **missed** to **partial** — the analysis found the right code area and the state separation issue, but framed the root cause slightly wrong.

the second experiment added flag/boolean variable tracing: "for every flag that controls behavior, trace where it's set, where it's consumed, and whether anything between those points can flip it unexpectedly." same result — partial. the analysis found the `resolve_local` flag, documented its lifecycle, but concluded "no code path modifies it between states." close, but the actual bug is more subtle than what a single-file analysis can fully trace.

both additions got merged. the prompt is now strictly better for state machine code.

**testing subtractions too**

the key insight: if removing a prompt section doesn't hurt the score, that section is burning tokens without adding value. we queued 4 removal experiments alongside the additions. does the "Rationalizations (Do Not Skip)" table from the original trail of bits audit methodology actually improve findings? or is it just consuming context window? the benchmark will tell us.

**the ideas ledger**

experiments shouldn't be hardcoded by a human. after each round, an agent reads the results, sees which bug categories are weak, and proposes 1-3 new experiment ideas — appending them to a shared TSV file. before proposing, it reads existing ideas to avoid duplicates.

tested ideas get marked with their score delta and keep/discard status. the system builds institutional memory of what was tried and what worked. no experiment runs twice.

**what's running now**

9 experiments queued: 5 additions, 4 subtractions. the loop runs unattended — apply change, benchmark 4 CVEs, score with LLM judge, keep or discard, generate new ideas, repeat. expected runtime: ~5 hours.

improvements auto-merge and stack. the baseline ratchets up. at the end we'll know exactly which prompt sections earn their weight and which ones are noise.

**what this means**

the approach is language-agnostic and tool-agnostic. swap curl for a Go project with known CVEs and the same loop works. swap EDC for any LLM-based analysis tool and the same scorer works.

the meta-point: treating LLM prompts as experimentally tunable artifacts — not as one-shot creative writing — is how you get from "vibes-based" to "evidence-based" AI tooling. the prompts that survive the loop are the ones that actually find bugs. everything else gets cut.
