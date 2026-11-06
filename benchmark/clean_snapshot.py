#!/usr/bin/env python3
"""Snapshot isolation for the clean benchmark (plan 041).

A snapshot is a fresh one-commit git repo whose tree is the vulnerable state:
  cve     -> tree of fix_commit~1
  planted -> tree of base_commit with the entry's patch applied (git apply)
The source history lives only in a partial-clone cache outside the snapshot;
no object from the cache is reachable from (or stored in) the snapshot.
"""

import os
import subprocess
import tempfile
from pathlib import Path

# Snapshot commits are deterministic and carry nothing about the entry.
SNAPSHOT_MESSAGE = "snapshot"
SNAPSHOT_IDENTITY = {
    "GIT_AUTHOR_NAME": "bench", "GIT_AUTHOR_EMAIL": "bench@localhost",
    "GIT_COMMITTER_NAME": "bench", "GIT_COMMITTER_EMAIL": "bench@localhost",
    "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
}


class SnapshotError(RuntimeError):
    pass


def _git(args, cwd=None, env=None, isolated=False, check=True, input=None):
    full_env = dict(os.environ)
    if isolated:
        # Snapshot-side git must not pick up user hooks, templates, autocrlf,
        # signing or other config that could alter the tree or the commit.
        full_env.update({"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})
    if env:
        full_env.update(env)
    proc = subprocess.run(["git", *args], cwd=cwd, env=full_env, capture_output=True, text=True, input=input)
    if check and proc.returncode != 0:
        raise SnapshotError(f"git {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()}")
    return proc


def ensure_cache(repo_url: str, cache: Path) -> Path:
    """Bare blob:none clone of repo_url at `cache` (created once, reused)."""
    cache = Path(cache)
    if not (cache / "HEAD").exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        _git(["clone", "--quiet", "--bare", "--filter=blob:none", repo_url, str(cache)])
    return cache


def resolve_commit(cache: Path, rev: str) -> str:
    """Full sha for rev in the cache; fetches once if the commit is missing."""
    probe = ["--git-dir", str(cache), "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"]
    proc = _git(probe, check=False)
    if proc.returncode != 0:
        _git(["--git-dir", str(cache), "fetch", "--quiet", "--filter=blob:none", "origin",
              "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"])
        proc = _git(probe, check=False)
    if proc.returncode != 0:
        raise SnapshotError(f"commit {rev} not found in {cache}")
    return proc.stdout.strip()


def vulnerable_commit(cache: Path, entry: dict) -> str:
    if entry["kind"] == "cve":
        fix = resolve_commit(cache, entry["fix_commit"])
        return resolve_commit(cache, f"{fix}~1")
    if entry["kind"] == "planted":
        return resolve_commit(cache, entry["base_commit"])
    raise SnapshotError(f"unknown entry kind {entry['kind']}")


def _prefetch_blobs(cache: Path, commit: str) -> None:
    """Fetch the tree's missing blobs in one batch. Per-blob lazy fetches from
    checkout-index are slow and failed on the real curl cache."""
    listing = _git(["--git-dir", str(cache), "rev-list", "--objects", "--missing=print", f"{commit}^{{tree}}"])
    missing = [line[1:] for line in listing.stdout.splitlines() if line.startswith("?")]
    if missing:
        _git(["--git-dir", str(cache), "-c", "fetch.negotiationAlgorithm=noop", "fetch", "--quiet", "origin",
              "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", "--stdin"],
             input="\n".join(missing) + "\n")


def _extract_tree(cache: Path, commit: str, dest: Path) -> None:
    """Write commit's tree into dest via a throwaway index (no git archive:
    export-ignore attributes would silently drop files)."""
    _prefetch_blobs(cache, commit)
    with tempfile.TemporaryDirectory() as tmp:
        env = {"GIT_INDEX_FILE": str(Path(tmp) / "index")}
        base = ["--git-dir", str(cache), "--work-tree", str(dest)]
        _git([*base, "read-tree", commit], env=env, isolated=True)
        _git([*base, "checkout-index", "--all", "--force"], env=env, isolated=True)


def make_snapshot(cache: Path, entry: dict, project_dir: Path, dest: Path) -> str:
    """Create the one-commit snapshot repo at dest; returns its commit sha."""
    dest = Path(dest)
    if dest.exists() and any(dest.iterdir()):
        raise SnapshotError(f"snapshot dir not empty: {dest}")
    dest.mkdir(parents=True, exist_ok=True)
    commit = vulnerable_commit(Path(cache), entry)
    _extract_tree(Path(cache), commit, dest)

    _git(["init", "--quiet", "--template=", "--initial-branch=main"], cwd=dest, isolated=True)
    if entry["kind"] == "planted":
        project_dir = Path(project_dir).resolve()
        patch = (project_dir / entry["patch"]).resolve()
        if project_dir not in patch.parents or not patch.is_file():
            raise SnapshotError(f"patch {entry['patch']} not found under {project_dir}")
        _git(["apply", "--whitespace=nowarn", str(patch)], cwd=dest, isolated=True)

    missing = [f for f in entry["affected_files"] if not (dest / f).is_file()]
    if missing:
        raise SnapshotError(f"affected files missing from snapshot: {', '.join(missing)}")

    # -f: files tracked upstream but matched by .gitignore must stay in the tree.
    _git(["add", "--all", "--force", "."], cwd=dest, isolated=True)
    _git(["-c", "commit.gpgsign=false", "commit", "--quiet", "--no-verify", "-m", SNAPSHOT_MESSAGE],
         cwd=dest, env=SNAPSHOT_IDENTITY, isolated=True)
    return _git(["rev-parse", "HEAD"], cwd=dest, isolated=True).stdout.strip()
