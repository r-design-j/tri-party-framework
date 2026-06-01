#!/usr/bin/env python3
"""Validate tri-party state.json without external Python dependencies."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path


PHASES = {
    "created",
    "review_partial",
    "review_failed",
    "reviewed",
    "cross_audit_failed",
    "cross_audited",
    "merged_partial",
    "merged_ready",
}

READY_CONCLUSION = "Ready for true tri-party synthesis"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RUNTIME_NOISE_RE = re.compile(
    r"GaxiosError|MODEL_CAPACITY_EXHAUSTED|RESOURCE_EXHAUSTED|No capacity available|"
    r"Warning: True color|Warning: Basic terminal|Warning: 256-color support|"
    r"Ripgrep is not available|ignored by configured ignore patterns|"
    r"Error executing tool read_file|Unauthorized tool call|Tool \".*\" not found|"
    r"LocalAgentExecutor.*Blocked call",
    re.IGNORECASE,
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def require_type(errors: list[str], obj: object, typ: type, label: str) -> bool:
    if not isinstance(obj, typ):
        fail(errors, f"{label} must be {typ.__name__}")
        return False
    return True


def validate_provenance(errors: list[str], value: object, label: str) -> None:
    if not require_type(errors, value, dict, label):
        return
    required = ["origin", "injected_at", "source_path", "source_sha256", "artifact_sha256"]
    for key in required:
        if key not in value:
            fail(errors, f"{label}.{key} is required")
    origin = value.get("origin")
    if origin not in {"automated_cli", "user_supplied"}:
        fail(errors, f"{label}.origin must be automated_cli or user_supplied")
    artifact_sha = value.get("artifact_sha256")
    if not isinstance(artifact_sha, str) or not SHA256_RE.match(artifact_sha):
        fail(errors, f"{label}.artifact_sha256 must be a sha256 hex string")


def validate_external_party(errors: list[str], value: object, label: str) -> None:
    if not require_type(errors, value, dict, label):
        return
    required = [
        "preflight",
        "preflight_path",
        "preflight_version",
        "preflight_binary_sha256",
        "review",
        "review_error_code",
        "review_provenance",
        "review_provenance_detail",
        "review_sha256",
        "cross_audit",
        "cross_audit_error_code",
        "cross_audit_provenance",
        "cross_audit_provenance_detail",
        "cross_audit_sha256",
    ]
    for key in required:
        if key not in value:
            fail(errors, f"{label}.{key} is required")
    for key in required:
        if key.endswith("_detail"):
            continue
        if key in value and not isinstance(value[key], str):
            fail(errors, f"{label}.{key} must be string")
    validate_provenance(errors, value.get("review_provenance_detail"), f"{label}.review_provenance_detail")
    validate_provenance(errors, value.get("cross_audit_provenance_detail"), f"{label}.cross_audit_provenance_detail")


def validate_gemini_diagnostics(errors: list[str], value: object, label: str) -> None:
    if not require_type(errors, value, dict, label):
        return
    for key in ["final_attempt", "capacity_events", "tool_block_events", "sanitized"]:
        if key not in value:
            fail(errors, f"{label}.{key} is required")
        elif not isinstance(value[key], int):
            fail(errors, f"{label}.{key} must be integer")
    if not isinstance(value.get("sanitizer_version"), str) or not value.get("sanitizer_version"):
        fail(errors, f"{label}.sanitizer_version must be non-empty string")


def validate_state_shape(errors: list[str], state: object) -> None:
    if not require_type(errors, state, dict, "state"):
        return
    required = [
        "schema_version",
        "core_version",
        "generated_at",
        "run_dir",
        "phase",
        "true_triparty_ready",
        "conclusion",
        "model_binding_sha256",
        "errors",
        "parties",
        "artifacts",
    ]
    for key in required:
        if key not in state:
            fail(errors, f"{key} is required")
    if state.get("schema_version") != "triparty.state.v1":
        fail(errors, "schema_version must be triparty.state.v1")
    if state.get("phase") not in PHASES:
        fail(errors, "phase is invalid")
    if not isinstance(state.get("true_triparty_ready"), bool):
        fail(errors, "true_triparty_ready must be boolean")
    if not isinstance(state.get("errors"), list):
        fail(errors, "errors must be array")
    else:
        for index, item in enumerate(state["errors"]):
            if not isinstance(item, dict):
                fail(errors, f"errors[{index}] must be object")
                continue
            for key in ["stage", "party", "code", "message"]:
                if not isinstance(item.get(key), str):
                    fail(errors, f"errors[{index}].{key} must be string")

    parties = state.get("parties")
    if not require_type(errors, parties, dict, "parties"):
        return
    for party in ["codex", "claude", "gemini"]:
        if party not in parties:
            fail(errors, f"parties.{party} is required")
    if isinstance(parties.get("codex"), dict):
        if not isinstance(parties["codex"].get("status"), str):
            fail(errors, "parties.codex.status must be string")
        if parties["codex"].get("role") != "final_synthesis":
            fail(errors, "parties.codex.role must be final_synthesis")
    validate_external_party(errors, parties.get("claude"), "parties.claude")
    validate_external_party(errors, parties.get("gemini"), "parties.gemini")
    if isinstance(parties.get("gemini"), dict):
        if not isinstance(parties["gemini"].get("preflight_policy_sha256"), str):
            fail(errors, "parties.gemini.preflight_policy_sha256 must be string")
        validate_gemini_diagnostics(errors, parties["gemini"].get("review_diagnostics"), "parties.gemini.review_diagnostics")
        validate_gemini_diagnostics(errors, parties["gemini"].get("cross_audit_diagnostics"), "parties.gemini.cross_audit_diagnostics")

    artifacts = state.get("artifacts")
    if require_type(errors, artifacts, dict, "artifacts"):
        for key in ["source_status", "cross_audit_status", "merge_status", "merge_input"]:
            if not isinstance(artifacts.get(key), str):
                fail(errors, f"artifacts.{key} must be string")


def validate_release(errors: list[str], state: dict, repo_root: Path) -> None:
    if state.get("true_triparty_ready") is not True:
        fail(errors, "release requires true_triparty_ready=true")
    if state.get("conclusion") != READY_CONCLUSION:
        fail(errors, f"release requires conclusion={READY_CONCLUSION!r}")
    if state.get("errors") != []:
        fail(errors, "release requires errors=[]")

    model_binding = repo_root / "docs/framework/model-binding.yaml"
    if model_binding.exists() and state.get("model_binding_sha256") != sha256(model_binding):
        fail(errors, "model_binding_sha256 does not match docs/framework/model-binding.yaml")
    gemini_policy = repo_root / "docs/framework/gemini-headless-policy.toml"

    run_dir = Path(str(state.get("run_dir", "")))
    parties = state.get("parties", {})
    try:
        max_capacity = int(os.environ.get("TRIPARTY_RELEASE_MAX_GEMINI_CAPACITY_EVENTS", "3"))
    except ValueError:
        fail(errors, "TRIPARTY_RELEASE_MAX_GEMINI_CAPACITY_EVENTS must be an integer")
        max_capacity = 3
    for name in ["claude", "gemini"]:
        party = parties.get(name, {})
        label = f"parties.{name}"
        if party.get("preflight") != "Available":
            fail(errors, f"{label}.preflight must be Available for release")
        for field in ["preflight_path", "preflight_version", "preflight_binary_sha256"]:
            if not party.get(field) or party.get(field) == "missing":
                fail(errors, f"{label}.{field} must be present for release")
        if not SHA256_RE.match(str(party.get("preflight_binary_sha256", ""))):
            fail(errors, f"{label}.preflight_binary_sha256 must be sha256 hex")
        for stage in ["review", "cross_audit"]:
            if party.get(stage) != "Completed":
                fail(errors, f"{label}.{stage} must be Completed for release")
            provenance = party.get(f"{stage}_provenance")
            if provenance != "automated_cli":
                fail(errors, f"{label}.{stage}_provenance must be automated_cli for release")
            detail = party.get(f"{stage}_provenance_detail", {})
            declared = party.get(f"{stage}_sha256")
            if isinstance(detail, dict) and detail.get("artifact_sha256") != declared:
                fail(errors, f"{label}.{stage}_provenance_detail artifact sha mismatch")

        artifact_names = {
            "review": run_dir / f"{name}-review.md",
            "cross_audit": run_dir / f"{name}-cross-audit.md",
        }
        for stage, path in artifact_names.items():
            if not path.exists():
                fail(errors, f"missing artifact {path}")
                continue
            actual_sha = sha256(path)
            if actual_sha != party.get(f"{stage}_sha256"):
                fail(errors, f"{path} sha mismatch")
            text = path.read_text(encoding="utf-8", errors="replace")
            if RUNTIME_NOISE_RE.search(text):
                fail(errors, f"{path} contains runtime noise")

    gemini = parties.get("gemini", {})
    if gemini_policy.exists() and gemini.get("preflight_policy_sha256") != sha256(gemini_policy):
        fail(errors, "parties.gemini.preflight_policy_sha256 does not match docs/framework/gemini-headless-policy.toml")
    for label in ["review_diagnostics", "cross_audit_diagnostics"]:
        diagnostics = gemini.get(label, {})
        if isinstance(diagnostics, dict):
            if diagnostics.get("tool_block_events", 0) > 0:
                fail(errors, f"parties.gemini.{label}.tool_block_events must be 0 for release")
            if diagnostics.get("capacity_events", 0) > max_capacity:
                fail(
                    errors,
                    f"parties.gemini.{label}.capacity_events exceeds release threshold {max_capacity}",
                )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("state_file")
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()

    state_path = Path(args.state_file)
    repo_root = Path(__file__).resolve().parents[1]
    errors: list[str] = []

    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(f"state validation failed: could not read JSON: {exc}", file=sys.stderr)
        return 1

    validate_state_shape(errors, state)
    if args.release and isinstance(state, dict):
        validate_release(errors, state, repo_root)

    if errors:
        print("state validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"state validation passed: {state_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
