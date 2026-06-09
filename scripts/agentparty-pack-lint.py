#!/usr/bin/env python3
"""Validate the AgentParty product pack registry without external packages."""

from __future__ import annotations

import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs/framework/agentparty-packs.json"
PACK_STATE_SCHEMA = ROOT / "docs/framework/agentparty-pack-state.schema.json"
TRIPARTY_STATE_SCHEMA = "docs/framework/state.schema.json"
GENERIC_PACK_STATE_SCHEMA = "docs/framework/agentparty-pack-state.schema.json"
ALLOWED_STATUS = {"productized", "scaffolded", "roadmap"}
ALLOWED_OS = {"supported", "roadmap", "blocked", "not_applicable"}
REQUIRED_OS = {"macos", "linux", "windows_wsl2", "windows_powershell"}
TRIPARTY_AGENT_IDS = {"codex", "claude", "gemini"}


def root_path(repo_relative: str) -> pathlib.Path:
    normalized = repo_relative.replace("\\", "/")
    return ROOT / pathlib.Path(*normalized.split("/"))


def fail(message: str) -> int:
    print(f"FAIL: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if not REGISTRY.exists():
        return fail(f"missing registry: {REGISTRY}")

    try:
        data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return fail(f"registry is invalid JSON: {exc}")

    if data.get("schema_version") != "agentparty.packs.v1":
        return fail("schema_version must be agentparty.packs.v1")

    try:
        pack_state_schema = json.loads(PACK_STATE_SCHEMA.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        return fail(f"pack state schema is missing or invalid: {exc}")

    true_triparty_field = pack_state_schema.get("properties", {}).get("true_triparty_ready", {})
    if true_triparty_field.get("const") is not False:
        return fail("agentparty pack-state true_triparty_ready must be const false")

    packs = data.get("packs")
    if not isinstance(packs, list) or not packs:
        return fail("packs must be a non-empty list")

    seen: set[str] = set()
    errors: list[str] = []

    for pack in packs:
        pack_id = pack.get("id")
        if not pack_id:
            errors.append("pack missing id")
            continue
        if pack_id in seen:
            errors.append(f"duplicate pack id: {pack_id}")
        seen.add(pack_id)

        if pack.get("status") not in ALLOWED_STATUS:
            errors.append(f"{pack_id}: invalid status")

        agents = pack.get("agents")
        if not isinstance(agents, list) or len(agents) < 2:
            errors.append(f"{pack_id}: must declare at least two agents")
        agent_list = agents if isinstance(agents, list) else []

        os_support = pack.get("os_support", {})
        missing_os = REQUIRED_OS - set(os_support)
        if missing_os:
            errors.append(f"{pack_id}: missing os_support {sorted(missing_os)}")
        for name, status in os_support.items():
            if status not in ALLOWED_OS:
                errors.append(f"{pack_id}: invalid os_support {name}={status}")

        docs = pack.get("docs")
        if not docs or not root_path(docs).exists():
            errors.append(f"{pack_id}: docs path missing: {docs}")

        semantics = pack.get("completion_semantics", {})
        state_schema = semantics.get("state_schema")
        normalized_state_schema = state_schema.replace("\\", "/") if isinstance(state_schema, str) else state_schema
        if normalized_state_schema and normalized_state_schema.startswith("docs/") and not root_path(normalized_state_schema).exists():
            errors.append(f"{pack_id}: state_schema path missing: {state_schema}")
        must_not_claim = set(semantics.get("must_not_claim", []))
        if pack_id != "triparty" and "true_triparty_ready" not in must_not_claim:
            errors.append(f"{pack_id}: non-triparty packs must forbid true_triparty_ready")
        if pack_id != "triparty" and semantics.get("ready_label") == "true_triparty_ready":
            errors.append(f"{pack_id}: non-triparty packs cannot use true_triparty_ready as ready_label")
        if pack_id != "triparty" and normalized_state_schema == TRIPARTY_STATE_SCHEMA:
            errors.append(f"{pack_id}: non-triparty packs cannot bind the triparty release state schema")
        if pack_id != "triparty" and normalized_state_schema != GENERIC_PACK_STATE_SCHEMA:
            errors.append(f"{pack_id}: non-triparty packs must use {GENERIC_PACK_STATE_SCHEMA}")
        if pack_id == "triparty" and semantics.get("ready_label") != "true_triparty_ready":
            errors.append("triparty: ready_label must be true_triparty_ready")
        if pack_id == "triparty" and normalized_state_schema != TRIPARTY_STATE_SCHEMA:
            errors.append(f"triparty: state_schema must be {TRIPARTY_STATE_SCHEMA}")
        if pack_id == "triparty":
            agent_ids = {agent.get("id") for agent in agent_list if isinstance(agent, dict)}
            if len(agent_list) != 3 or agent_ids != TRIPARTY_AGENT_IDS:
                errors.append("triparty: agents must be exactly codex, claude, and gemini")

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1

    print("agentparty pack lint passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
