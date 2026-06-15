# EDC for pi X thread

**1/**
EDC for pi: repo context + code review plugin.

this came out of working on chia. agents were fine with isolated files, but kept losing the plot across protocol flows, consensus assumptions, wallet/node interactions, and all the “you only know this if you know the system” stuff.

**2/**
EDC builds an `edc-context/` tree for a repo: overview, module docs, routing manifest, build metadata, audit/review reports.

the module docs capture structure, invariants, trust boundaries, and data flow — the stuff agents otherwise rediscover badly on every new task.

**3/**
after context is built, reviews run *using* it.

PR diffs get routed through the manifest, so the agent loads the relevant module context instead of dumping a giant maybe-irrelevant context blob into the chat.

**4/**
when the code changes, EDC can update context from a diff instead of rebuilding everything from scratch.

so you get persistent repo understanding, but it can keep up with normal branch/PR movement.

**5/**
the review flow is based on Trail of Bits’ differential review methodology, and the context-building side is inspired by their context-aware skill.

the difference is EDC is meant to run across larger/general repos, not just smart contract codebases.

**6/**
i also built a benchmark loop around it using real CVEs from repos like curl and redis.

the point was to avoid “this prompt feels better” development. review changes get scored against known bugs, regressions, and misses.

**7/**
working with detailed whole-project context made reviews, debugging, and build tasks noticeably better.

agents are much more useful when they understand the system, not just the current patch.
