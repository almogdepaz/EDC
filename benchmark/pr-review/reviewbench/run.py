#!/usr/bin/env python3
"""ReviewBench container entrypoint. Parent must prepare isolation before use."""
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

from adapter import (AdapterError, EDC_REVISION, REVIEWBENCH_REVISION, atomic_json,
                     begin_job, complete_job, convert_reports, digest, encoded,
                     regular_files, safe_relative, validate_result)

MODEL = "openai-codex/gpt-6.1-sol:high"
# SHA256 of encoded({path: SHA256(blob)}) for all 73 package.json/pi/plugins
# blobs read independently from EDC_REVISION. Not a manifest-supplied assertion.
PINNED_RUNTIME_INVENTORY = "ef8e901b0cd7389d7fc7da72395bf4a5ab09e73bcf727106639a451b978ab242"


def git(repo, *args):
    result = subprocess.run(["git", "--no-optional-locks", "-C", str(repo), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise AdapterError("git inspection failed: " + result.stderr.decode(errors="replace"))
    return result.stdout


class HeadBounds:
    """Read only the immutable head blobs referenced by final findings."""
    def __init__(self, repo, head):
        self.repo, self.head = repo, head
        self.files = {}
        for entry in git(repo, "ls-tree", "-rz", head).split(b"\0"):
            if not entry:
                continue
            meta, name = entry.split(b"\t", 1)
            mode, kind, sha = meta.split()
            if kind == b"blob" and mode in (b"100644", b"100755"):
                self.files[name.decode()] = sha.decode()

    def __contains__(self, key):
        return key in self.files

    def __getitem__(self, key):
        blob = git(self.repo, "cat-file", "blob", self.files[key])
        if b"\0" in blob:
            raise AdapterError("binary head evidence")
        return blob.count(b"\n") + int(bool(blob) and not blob.endswith(b"\n"))


def regular_bytes(path):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise AdapterError("expected a regular single-link file: " + str(path))
    return path.read_bytes()


def runtime_inventory(runtime):
    files = {"package.json": digest(regular_bytes(runtime / "package.json"))}
    for name in ("pi", "plugins"):
        root = runtime / name
        if root.is_symlink() or not root.is_dir():
            raise AdapterError("missing or linked runtime directory: " + name)
        for path in root.rglob("*"):
            if path.is_symlink():
                raise AdapterError("linked runtime path: " + str(path))
            if not path.is_dir():
                files[path.relative_to(runtime).as_posix()] = digest(regular_bytes(path))
    return files


def runtime_identity(runtime):
    """Verify pinned bytes; parent still owns immutable image/mount provenance.

    The manifest is not a signature. Its inventory must match the independent
    pinned digest above, and its exact bytes enter the durable review identity.
    """
    manifest_path = runtime / "runtime-provenance.json"
    manifest_bytes = None
    if manifest_path.exists() or manifest_path.is_symlink():
        manifest_bytes = regular_bytes(manifest_path)
        try:
            manifest = json.loads(manifest_bytes)
        except (ValueError, UnicodeError) as error:
            raise AdapterError("invalid runtime provenance JSON") from error
        if not isinstance(manifest, dict) or set(manifest) != {"revision", "files"} or manifest["revision"] != EDC_REVISION:
            raise AdapterError("runtime provenance has an unsupported schema or revision")
        files = manifest["files"]
        if not isinstance(files, dict) or not files:
            raise AdapterError("runtime provenance needs a complete file inventory")
        for name, sha256 in files.items():
            safe_relative(name)
            if name != "package.json" and not name.startswith(("pi/", "plugins/")):
                raise AdapterError("runtime manifest path outside protected inventory")
            if not isinstance(sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", sha256):
                raise AdapterError("invalid runtime SHA256")
        if digest(encoded(files)) != PINNED_RUNTIME_INVENTORY:
            raise AdapterError("runtime manifest inventory does not match the pinned source")
        if runtime_inventory(runtime) != files:
            raise AdapterError("runtime file set or bytes differ from pinned manifest")
    else:
        if git(runtime, "rev-parse", "HEAD").decode().strip() != EDC_REVISION:
            raise AdapterError("runtime checkout is not pinned EDC")
        files = runtime_inventory(runtime)
        if digest(encoded(files)) != PINNED_RUNTIME_INVENTORY:
            raise AdapterError("runtime file set or bytes differ from the pinned source")
    identity = dict(revision=EDC_REVISION, sha256=digest(encoded(files)))
    if manifest_bytes is not None:
        identity["manifest_sha256"] = digest(manifest_bytes)
    return identity


def read_inputs(env):
    config = json.loads(Path(env["RB_EDC_CONFIG"]).read_text())
    required = {"pilot", "runtime", "model", "backend_version", "isolation_id", "runtime_settings"}
    if set(config) != required or config["model"] != MODEL:
        raise AdapterError("unsupported pilot configuration/model")
    if env.get("EDC_PI_MODEL", MODEL) != config["model"]:
        raise AdapterError("parent EDC_PI_MODEL conflicts with the approved model")
    if not all(isinstance(config[key], str) and config[key] for key in ("backend_version", "isolation_id", "runtime")):
        raise AdapterError("missing backend/isolation/runtime identity")
    pilot = config["pilot"]
    if not isinstance(pilot, list) or len(pilot) != 2 or pilot[0] == pilot[1]:
        raise AdapterError("pilot must contain exactly two distinct PR identities")
    for pr in pilot:
        if set(pr) != {"repo", "pr_number", "base", "head"} or type(pr["pr_number"]) is not int or pr["pr_number"] < 1:
            raise AdapterError("invalid pilot PR identity")
        if not isinstance(pr["repo"], str) or not pr["repo"]:
            raise AdapterError("missing source identity")
        if not all(re.fullmatch(r"[a-f0-9]{40}", pr[key]) for key in ("base", "head")):
            raise AdapterError("base/head must be full immutable SHAs")
    if len({(p["repo"], p["pr_number"]) for p in pilot}) != 2:
        raise AdapterError("pilot repeats a PR")
    metadata = json.loads(Path(env["RB_PR_JSON"]).read_text())
    pr = {key: metadata[key] for key in ("repo", "pr_number", "base", "head")}
    if pr not in pilot or pr["head"] != env["RB_HEAD"] or pr["base"] != env["RB_BASE"] or str(pr["pr_number"]) != env["RB_PR_NUMBER"]:
        raise AdapterError("PR is not in the approved two-PR manifest")
    if metadata.get("nwo") != env["RB_NWO"]:
        raise AdapterError("PR source mismatch")
    settings = config["runtime_settings"]
    allowed = {"EDC_REVIEW_TIMEOUT", "EDC_AUDIT_TIMEOUT", "EDC_PI_EXTENSION_PATH"}
    if not isinstance(settings, dict) or set(settings) - allowed:
        raise AdapterError("unsupported runtime settings")
    for key, value in settings.items():
        if not isinstance(value, str) or not value:
            raise AdapterError("settings must be nonempty strings")
        if key.endswith("TIMEOUT") and (not value.isdigit() or not 1 <= int(value) <= 3600):
            raise AdapterError("invalid runtime timeout")
    return config, metadata, pr


def usage_inventory(directory):
    # Worker pools deliberately redirect their own traces under Git-private
    # run directories, retained here under worker-state. Delivery is top-level.
    traces = sorted(directory.glob("**/transcripts/*.jsonl"))
    if not traces:
        raise AdapterError("missing raw usage traces")
    inventory = []
    for trace in traces:
        events = [json.loads(line) for line in regular_bytes(trace).decode().splitlines() if line.strip()]
        messages = []
        for event in events:
            if event.get("type") == "message_end":
                messages.append(event.get("message", {}))
            elif event.get("type") == "agent_end":
                messages.extend(event.get("messages", []))
        # Do not sum message_end and agent_end copies, or infer missing tokens as 0.
        observed = [m for m in messages if m.get("role") == "assistant"]
        if any(not isinstance(m.get("usage"), dict) for m in observed):
            raise AdapterError("an assistant attempt has unknown usage in " + trace.name)
        if not observed:
            raise AdapterError("usage unknown in " + trace.name)
        for message in observed:
            if message.get("provider") != "openai-codex" or message.get("model") != "gpt-6.1-sol":
                raise AdapterError("observed provider/model mismatch in " + trace.name)
            for field in ("input", "output", "cacheRead", "cacheWrite", "totalTokens"):
                value = message["usage"].get(field)
                if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                    raise AdapterError("usage field unknown/invalid: " + field + " in " + trace.name)
        inventory.append({"trace": trace.relative_to(directory).as_posix(), "usage_present": True,
                          "models": sorted({str(m.get("model", "unknown")) for m in observed}),
                          "accounting": "raw Pi events; parent must deduplicate and price all attempts"})
    return inventory


def preserve(repo, job, head):
    """Retain failed phases as well as successful reports before any validation."""
    run_root = Path(git(repo, "rev-parse", "--absolute-git-dir").decode().strip()) / "edc"
    if run_root.is_symlink():
        raise AdapterError("linked production run root")
    if run_root.exists():
        shutil.copytree(run_root, job / "worker-state", symlinks=True)
    names = {"security": "review-" + head + ".md", "delivery": "delivery-review-" + head + ".md",
             "complexity": "edc-context/reports/complexity.md", "issues": "edc-context/reports/issues.md"}
    (job / "reports").mkdir()
    for name, relative in names.items():
        path = repo / relative
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != repo and repo in parent.parents):
            raise AdapterError("linked final report path")
        if path.is_file():
            if path.stat().st_nlink != 1:
                raise AdapterError("hard-linked final report")
            shutil.copyfile(path, job / "reports" / (name + ".md"))


def execute(env):
    config, metadata, pr = read_inputs(env)
    repo = Path(env.get("RB_REPO", "/work/repo")).resolve()
    runtime = Path(config["runtime"]).resolve()
    out = Path(env["RB_OUT"]).absolute()
    job = Path(env["RB_ARTIFACT_DIR"]).absolute()
    if repo == runtime or repo in job.parents or job in repo.parents or out == job or job in out.parents:
        raise AdapterError("source, artifacts and published output must be separate")
    if git(repo, "rev-parse", "HEAD").decode().strip() != pr["head"]:
        raise AdapterError("checkout is not the selected head")
    source_tree = git(repo, "rev-parse", pr["head"] + "^{tree}").decode().strip()
    git(repo, "cat-file", "-e", pr["base"] + "^{commit}")
    patch = git(repo, "diff", pr["base"] + "..." + pr["head"])
    if patch != Path(env["RB_DIFF"]).read_bytes():
        raise AdapterError("mounted diff is not base...head")
    identity = {"source": pr, "source_tree": source_tree, "metadata": digest(encoded(metadata)),
                "diff": digest(patch), "runtime": runtime_identity(runtime), "config": config,
                "converter": digest(Path(__file__).read_bytes() + Path(__file__).with_name("adapter.py").read_bytes()),
                "reviewbench": REVIEWBENCH_REVISION, "producer": env["RB_AGENT"],
                "pi_coding_agent_dir": env.get("PI_CODING_AGENT_DIR")}
    extension = config["runtime_settings"].get("EDC_PI_EXTENSION_PATH")
    if extension:
        path = Path(extension)
        if not path.is_absolute() or path.is_symlink() or not path.is_file():
            raise AdapterError("invalid parent observer extension")
        identity["observer_sha256"] = digest(path.read_bytes())
    if git(repo, "diff", "HEAD", "--").strip():
        raise AdapterError("tracked source differs from the immutable head")
    if begin_job(job, identity):
        findings = json.loads((job / "findings.json").read_text())
        publish(out, findings)
        return "resumed"
    try:
        if out.exists():
            raise AdapterError("published output already exists without a matching success receipt")
        if git(repo, "status", "--porcelain", "--untracked-files=all").strip():
            raise AdapterError("review requires a fresh clean disposable checkout")
        if (repo / "edc-context").exists():
            raise AdapterError("generated context must not be mounted for B")
        git_dir = Path(git(repo, "rev-parse", "--absolute-git-dir").decode().strip())
        if (git_dir / "edc").exists():
            raise AdapterError("prior EDC run state must not be mounted")
        # Keep the production backend's in-flight raw capture on the durable
        # artifact volume too; completed worker traces remain Git-private.
        scratch = job / "tmp"
        scratch.mkdir()
        run_env = {key: value for key, value in env.items() if not key.startswith("EDC_")}
        run_env["TMPDIR"] = str(scratch)
        run_env.update(config["runtime_settings"])
        run_env.update(EDC_CONFIG_FILE="/dev/null", EDC_PI_MODEL=env.get("EDC_PI_MODEL", MODEL), EDC_REVIEW_MODEL=MODEL,
                       EDC_PARALLEL="0", EDC_KEEP_REVIEW_TASKS="1", EDC_KEEP_AUDIT_TASKS="1",
                       EDC_RESULT_FILE=str(job / "result.json"), EDC_SPAWN_LOG=str(job / "spawn-log.jsonl"),
                       EDC_TRANSCRIPT_DIR=str(job / "transcripts"), EDC_PRESERVE_TRANSCRIPTS="1")
        command = ["bash", str(runtime / "plugins/edc/scripts/edc"), "review", "--diff",
                   pr["base"] + "..." + pr["head"], "--committed-only", "--ignore-context", "--agent", "pi"]
        atomic_json(job / "settings.json", {"command": command, "model": MODEL,
                    "pi_coding_agent_dir": run_env.get("PI_CODING_AGENT_DIR"), "tmpdir": str(scratch),
                    "runtime_settings": {k: v for k, v in run_env.items() if k.startswith("EDC_")},
                    "identity": identity})
        print("model=" + MODEL + " agent=pi parallel=0 context=ignored", flush=True)
        with (job / "stdout.log").open("wb") as stdout, (job / "stderr.log").open("wb") as stderr:
            result = subprocess.run(command, cwd=repo, env=run_env, stdout=stdout, stderr=stderr, check=False)
        preserve(repo, job, pr["head"])
        atomic_json(job / "exit.json", {"returncode": result.returncode})
        if result.returncode:
            raise AdapterError("production coordinator failed; raw artifacts retained")
        validate_result(json.loads((job / "result.json").read_text()), pr["head"], pr["base"])
        if git(repo, "diff", "HEAD", "--").strip() or git(repo, "rev-parse", "HEAD").decode().strip() != pr["head"]:
            raise AdapterError("source changed during review")
        reports = {name: (job / "reports" / (name + ".md")).read_text() for name in ("security", "delivery", "complexity", "issues")}
        findings = {"pr": pr, "agent": env["RB_AGENT"], "findings": convert_reports(reports, HeadBounds(repo, pr["head"]), env["RB_AGENT"])}
        atomic_json(job / "usage-inventory.json", usage_inventory(job))
        atomic_json(job / "findings.json", findings)
        complete_job(job, identity)
        publish(out, findings)
        return "completed"
    except Exception as error:
        atomic_json(job / "failure.json", {"type": type(error).__name__, "message": str(error),
                                           "retry": "blocked; parent reconciliation required"})
        raise


def publish(out, findings):
    if out.exists():
        if out.is_symlink() or out.read_bytes() != encoded(findings):
            raise AdapterError("existing output differs; refusing overwrite")
        return
    atomic_json(out, findings)


def main():
    try:
        print(execute(dict(os.environ)))
        return 0
    except (AdapterError, OSError, ValueError, KeyError) as error:
        print("reviewbench adapter stopped: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
