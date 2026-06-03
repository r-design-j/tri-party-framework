#!/usr/bin/env python3
"""Local HTTP adapter for the tri-party portable core."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


ROOT_DIR = Path(__file__).resolve().parents[2]
REPO_RUNS_DIR = Path(os.environ.get("TRIPARTY_REPO_RUNS_DIR", ROOT_DIR / "docs" / "framework" / "runs"))
FALLBACK_RUNS_DIR = Path(os.environ.get("TRIPARTY_RUNS_FALLBACK_DIR", Path(tempfile.gettempdir()) / "triparty-runs"))
TRIPARTY = ROOT_DIR / "scripts" / "triparty.sh"
VERSION_FILE = ROOT_DIR / "VERSION"
MAX_BODY_BYTES = 1024 * 1024


def version() -> str:
    if VERSION_FILE.exists():
        return VERSION_FILE.read_text(encoding="utf-8").strip()
    return "0.0.0-dev"


def is_writable_dir(path: Path) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
        probe = path / f".triparty-write-test.{os.getpid()}"
        probe.write_text("", encoding="utf-8")
        probe.unlink(missing_ok=True)
        return True
    except OSError:
        return False


def resolve_runs_dir() -> Path:
    preferred = Path(os.environ.get("TRIPARTY_RUNS_DIR", str(REPO_RUNS_DIR)))
    if is_writable_dir(preferred):
        return preferred.resolve()
    if is_writable_dir(FALLBACK_RUNS_DIR):
        return FALLBACK_RUNS_DIR.resolve()
    return preferred.resolve()


RUNS_DIR = resolve_runs_dir()


def candidate_runs_dirs() -> list[Path]:
    if os.environ.get("TRIPARTY_RUNS_DIR"):
        return [RUNS_DIR]
    candidates = [RUNS_DIR, REPO_RUNS_DIR.resolve(), FALLBACK_RUNS_DIR.resolve()]
    unique: list[Path] = []
    for candidate in candidates:
        if candidate not in unique:
            unique.append(candidate)
    return unique


def latest_run_dir() -> Path | None:
    runs: list[Path] = []
    for runs_dir in candidate_runs_dirs():
        if runs_dir.exists():
            runs.extend(path for path in runs_dir.glob("review-*") if path.is_dir())
    runs = sorted(set(runs), key=lambda path: path.name)
    if not runs:
        return None
    return runs[-1]


def ensure_under(path: Path, parent: Path) -> Path:
    resolved = path.resolve()
    parent_resolved = parent.resolve()
    if resolved == parent_resolved or parent_resolved in resolved.parents:
        return resolved
    raise ValueError(f"path outside allowed root: {path}")


def ensure_under_any(path: Path, parents: list[Path]) -> Path:
    resolved = path.resolve()
    for parent in parents:
        parent_resolved = parent.resolve()
        if resolved == parent_resolved or parent_resolved in resolved.parents:
            return resolved
    allowed = ", ".join(str(parent) for parent in parents)
    raise ValueError(f"path outside allowed roots: {path}; allowed={allowed}")


def resolve_run_dir(value: str | None) -> Path:
    if not value:
        latest = latest_run_dir()
        if latest is None:
            raise ValueError("no review run exists")
        return latest.resolve()

    path = Path(value)
    if not path.is_absolute():
        path = ROOT_DIR / path
    resolved = ensure_under_any(path, candidate_runs_dirs())
    if not resolved.is_dir():
        raise ValueError(f"run directory does not exist: {value}")
    return resolved


def resolve_context_files(values: list[str]) -> list[str]:
    resolved: list[str] = []
    for value in values:
        path = Path(value)
        if not path.is_absolute():
            path = ROOT_DIR / path
        safe = ensure_under(path, ROOT_DIR)
        if not safe.exists():
            raise ValueError(f"context file does not exist: {value}")
        resolved.append(str(safe))
    return resolved


def run_command(args: list[str], timeout: int) -> dict:
    started = time.time()
    try:
        completed = subprocess.run(
            [str(TRIPARTY), *args],
            cwd=str(ROOT_DIR),
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return {
            "ok": completed.returncode == 0,
            "exit_code": completed.returncode,
            "duration_ms": int((time.time() - started) * 1000),
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "exit_code": 124,
            "duration_ms": int((time.time() - started) * 1000),
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or f"command timed out after {timeout}s",
        }


def read_json_file(path: Path) -> dict | None:
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_state(run_dir: Path) -> dict | None:
    return read_json_file(run_dir / "state.json")


def sha256_file(path: Path) -> str:
    if not path.exists():
        return "missing"
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def merge_conclusion(run_dir: Path) -> str:
    merge_status = run_dir / "merge-status.md"
    if not merge_status.exists():
        return ""
    for line in merge_status.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("Conclusion label: "):
            return line.split(": ", 1)[1].strip()
    return ""


def validate_state(run_dir: Path, state: dict | None) -> dict:
    errors: list[str] = []
    if state is None:
        return {"ok": False, "errors": ["missing state.json"]}

    if state.get("schema_version") != "triparty.state.v1":
        errors.append("invalid schema_version")

    parties = state.get("parties")
    if not isinstance(parties, dict):
        errors.append("missing parties")
        parties = {}

    expected = {
        "claude": {
            "review_sha256": run_dir / "claude-review.md",
            "cross_audit_sha256": run_dir / "claude-cross-audit.md",
        },
        "gemini": {
            "review_sha256": run_dir / "gemini-review.md",
            "cross_audit_sha256": run_dir / "gemini-cross-audit.md",
        },
    }

    for party, fields in expected.items():
        party_state = parties.get(party)
        if not isinstance(party_state, dict):
            errors.append(f"missing party state: {party}")
            continue
        for field, artifact in fields.items():
            recorded = party_state.get(field, "")
            actual = sha256_file(artifact)
            if recorded != actual:
                errors.append(f"{party}.{field} mismatch: recorded={recorded} actual={actual}")

    conclusion = merge_conclusion(run_dir)
    if state.get("true_triparty_ready") is True and conclusion != "Ready for true tri-party synthesis":
        errors.append("true_triparty_ready disagrees with merge-status.md")
    if state.get("phase") == "merged_ready" and state.get("true_triparty_ready") is not True:
        errors.append("merged_ready phase without true_triparty_ready")

    return {"ok": not errors, "errors": errors}


def attach_state_from_stdout(result: dict) -> dict:
    for line in str(result.get("stdout", "")).splitlines():
        if not line.startswith("State: "):
            continue
        state_path = Path(line.split("State: ", 1)[1].strip())
        if not state_path.is_absolute():
            state_path = ROOT_DIR / state_path
        try:
            safe_state = ensure_under_any(state_path, candidate_runs_dirs())
            state = read_json_file(safe_state)
            if state is not None:
                result["state"] = state
                result["state_validation"] = validate_state(safe_state.parent, state)
                if not result["state_validation"]["ok"]:
                    result["ok"] = False
        except Exception:
            pass
        break
    return result


def command_with_state(args: list[str], run_dir: Path | None, timeout: int) -> dict:
    result = run_command(args, timeout)
    if run_dir is not None:
        state = load_state(run_dir)
        if state is not None:
            result["state"] = state
            result["state_validation"] = validate_state(run_dir, state)
            if not result["state_validation"]["ok"]:
                result["ok"] = False
    else:
        attach_state_from_stdout(result)
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "TripartyHTTPAdapter/0.1"

    def log_message(self, fmt: str, *args) -> None:
        if getattr(self.server, "quiet", False):
            return
        super().log_message(fmt, *args)

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str) -> None:
        self._send(status, {"ok": False, "error": message})

    def _authorized(self) -> bool:
        token = getattr(self.server, "auth_token", "")
        if not token:
            return True
        auth = self.headers.get("Authorization", "")
        header_token = self.headers.get("X-Triparty-Token", "")
        return auth == f"Bearer {token}" or header_token == token

    def _query(self) -> dict[str, list[str]]:
        return parse_qs(urlparse(self.path).query)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > MAX_BODY_BYTES:
            raise ValueError("request body too large")
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_OPTIONS(self) -> None:
        self._send(200, {"ok": True})

    def do_GET(self) -> None:
        try:
            if not self._authorized():
                self._error(401, "unauthorized")
                return

            path = urlparse(self.path).path
            query = self._query()

            if path == "/health":
                self._send(
                    200,
                    {
                        "ok": True,
                        "adapter": "triparty-http",
                        "version": version(),
                        "root_dir": str(ROOT_DIR),
                        "runs_dir": str(RUNS_DIR),
                    },
                )
                return

            if path == "/runs":
                limit = int(query.get("limit", ["20"])[0])
                runs = []
                for runs_dir in candidate_runs_dirs():
                    if runs_dir.exists():
                        runs.extend(path for path in runs_dir.glob("review-*") if path.is_dir())
                runs = sorted(set(runs), key=lambda path: path.name)[-limit:]
                payload = []
                for run_dir in runs:
                    state = load_state(run_dir)
                    payload.append(
                        {
                            "run_dir": str(run_dir),
                            "state": state,
                            "state_validation": validate_state(run_dir, state),
                        }
                    )
                self._send(200, {"ok": True, "runs": payload})
                return

            if path == "/stats":
                result = run_command(["stats"], timeout=120)
                self._send(200 if result["ok"] else 500, result)
                return

            if path in {"/status", "/state"}:
                run_dir = resolve_run_dir(query.get("run_dir", [""])[0])
                result = command_with_state(["status", str(run_dir)], run_dir, timeout=120)
                status = 200 if result["ok"] else 500
                self._send(status, result)
                return

            self._error(404, f"unknown endpoint: {path}")
        except Exception as exc:  # noqa: BLE001 - return adapter errors as JSON
            self._error(400, str(exc))

    def do_POST(self) -> None:
        try:
            if not self._authorized():
                self._error(401, "unauthorized")
                return

            path = urlparse(self.path).path
            data = self._body()
            timeout = int(data.get("timeout_seconds", 3600))

            if path == "/run":
                question = data.get("question")
                if not question:
                    raise ValueError("missing question")
                context_files = resolve_context_files(data.get("context_files", []))
                result = command_with_state(["run", question, *context_files], None, timeout=timeout)
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/review":
                question = data.get("question")
                if not question:
                    raise ValueError("missing question")
                context_files = resolve_context_files(data.get("context_files", []))
                result = command_with_state(["review", question, *context_files], None, timeout=timeout)
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/cross-audit":
                run_dir = resolve_run_dir(data.get("run_dir"))
                result = command_with_state(["cross-audit", str(run_dir)], run_dir, timeout=timeout)
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/merge":
                run_dir = resolve_run_dir(data.get("run_dir"))
                result = command_with_state(["merge", str(run_dir)], run_dir, timeout=timeout)
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/inject":
                stage = data.get("stage", "review")
                party = data.get("party")
                run_dir = resolve_run_dir(data.get("run_dir"))
                artifact_file = data.get("artifact_file")
                if not party or not artifact_file:
                    raise ValueError("missing party or artifact_file")
                artifact_path = Path(artifact_file)
                if not artifact_path.is_absolute():
                    artifact_path = ROOT_DIR / artifact_path
                safe_artifact = ensure_under(artifact_path, ROOT_DIR)
                result = command_with_state(
                    ["inject", stage, party, str(run_dir), str(safe_artifact)],
                    run_dir,
                    timeout=min(timeout, 300),
                )
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/resume":
                run_dir = resolve_run_dir(data.get("run_dir"))
                result = command_with_state(["resume", str(run_dir)], run_dir, timeout=timeout)
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/archive":
                args = ["archive"]
                if "keep" in data:
                    args.extend(["--keep", str(data["keep"])])
                if data.get("dry_run", True):
                    args.append("--dry-run")
                result = run_command(args, timeout=min(timeout, 300))
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/preflight":
                out_dir = data.get("out_dir")
                args = ["preflight"]
                if out_dir:
                    out_path = Path(out_dir)
                    if not out_path.is_absolute():
                        out_path = ROOT_DIR / out_path
                    args.append(str(ensure_under_any(out_path, candidate_runs_dirs())))
                result = run_command(args, timeout=min(timeout, 300))
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/lint":
                result = run_command(["lint"], timeout=min(timeout, 300))
                self._send(200 if result["ok"] else 500, result)
                return

            if path == "/regression":
                result = run_command(["regression"], timeout=min(timeout, 300))
                self._send(200 if result["ok"] else 500, result)
                return

            self._error(404, f"unknown endpoint: {path}")
        except Exception as exc:  # noqa: BLE001 - return adapter errors as JSON
            self._error(400, str(exc))


def is_loopback_host(host: str) -> bool:
    if host in {"localhost", "localhost.localdomain"}:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Run the local tri-party HTTP adapter.")
    parser.add_argument("--host", default=os.environ.get("TRIPARTY_ADAPTER_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("TRIPARTY_ADAPTER_PORT", "8765")))
    parser.add_argument("--auth-token", default=os.environ.get("TRIPARTY_ADAPTER_AUTH_TOKEN", ""))
    parser.add_argument("--allow-non-loopback", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    if not is_loopback_host(args.host):
        if not args.allow_non_loopback:
            print("refusing non-loopback bind without --allow-non-loopback", file=sys.stderr)
            return 2
        if not args.auth_token:
            print("refusing non-loopback bind without --auth-token", file=sys.stderr)
            return 2

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.quiet = args.quiet  # type: ignore[attr-defined]
    server.auth_token = args.auth_token  # type: ignore[attr-defined]
    print(f"triparty http adapter listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
