#!/usr/bin/env python3
"""AgentParty product-pack CLI.

This is the generic protocol entrypoint. It discovers product packs and creates
pack-scoped artifacts. The existing triparty executable core remains delegated
to scripts/triparty.sh.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tarfile
from html.parser import HTMLParser
from urllib.parse import urlparse
from datetime import datetime, timezone
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs/framework/agentparty-packs.json"
RUNS_DIR = pathlib.Path(os.environ.get("AGENTPARTY_RUNS_DIR", str(ROOT / "docs/framework/agentparty-runs"))).expanduser()
TRIPARTY = ROOT / "scripts/triparty.sh"
BOOTSTRAP_INSTALLER = ROOT / "scripts/install-triparty-global-bootstrap.sh"
SUPPORTED_EXECUTABLE_OSES = {"macos", "linux", "windows_wsl2"}
CLAW_EVIDENCE_BUNDLE_SCHEMA = "agentparty.claw-evidence-bundle.v1"
CLAW_EVIDENCE_BUNDLE_FILE = "agentparty-claw-evidence.json"
CLAW_BRIDGE_STATE_SCHEMA = "agentparty.claw-bridge-state.v1"
CLAW_BRIDGE_KIT_SCHEMA = "agentparty.claw-bridge-kit.v1"
CLAW_BRIDGE_MANIFEST_FILE = "agentparty-claw-bridge.json"
CLAW_PLACEHOLDER_TOKEN = "TODO_AGENTPARTY_REPLACE"
MIN_CLAW_EVIDENCE_CHARS = 40
CLAW_EVIDENCE_ARTIFACT_FILES = {
    "feishu_claw_transcript": "feishu-claw-transcript.txt",
    "operation_summary": "operation-summary.txt",
    "claude_code_review": "claude-code-review.txt",
}
PACKAGE_SCHEMA_VERSION = "agentparty.package.v1"
PACKAGE_MANIFEST_FILE = "agentparty-package-manifest.json"
PACKAGE_INSTALL_FILE = "INSTALL.md"
# Website command cards are curated user workflows. Every card must expose
# exactly one copy command, so the expected card count is derived from the
# command contract instead of being maintained as a second literal.
EXPECTED_WEB_COPY_COMMANDS = [
    "scripts/triparty.sh preflight",
    "scripts/triparty.sh run '<task>'",
    "scripts/triparty.sh release-gate docs/framework/runs/review-YYYYMMDD-HHMMSS",
    "scripts/triparty.sh continuity bootstrap",
    "scripts/agentparty.sh kit --pack claude-code-feishu-claw --task '<task>' --out claw-kit",
    "scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir '<run-dir>' --out claw-evidence",
    "scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle claw-evidence/agentparty-claw-evidence.json",
    "scripts/agentparty.sh validate-run --run-dir '<run-dir>'",
    "scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir '<run-dir>'",
    "scripts/agentparty.sh info --pack claude-code-feishu-claw",
    "scripts/agentparty.sh onboard --pack triparty --target-os auto",
    "scripts/agentparty.sh quickstart --pack triparty --target-os auto",
    "scripts/agentparty.sh install --pack triparty --target-os auto",
    "scripts/agentparty.sh install --pack triparty --target-os auto --execute",
    "scripts/agentparty.sh install-plan --pack triparty --target-os auto",
    "scripts/agentparty.sh release-check --full",
    "scripts/agentparty.sh package --out dist/agentparty-release --archive",
    "scripts/uninstall-triparty-global-bootstrap.sh --dry-run",
    ".\\scripts\\uninstall-triparty-global-bootstrap.ps1 -DryRun",
]
EXPECTED_WEB_COMMAND_CARDS = len(EXPECTED_WEB_COPY_COMMANDS)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_registry() -> dict[str, Any]:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def packs_by_id() -> dict[str, dict[str, Any]]:
    return {pack["id"]: pack for pack in load_registry()["packs"]}


def require_pack(pack_id: str) -> dict[str, Any]:
    packs = packs_by_id()
    if pack_id not in packs:
        known = ", ".join(sorted(packs))
        raise SystemExit(f"Unknown pack: {pack_id}. Known packs: {known}")
    return packs[pack_id]


def print_json(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def user_path(value: str) -> pathlib.Path:
    path = pathlib.Path(value).expanduser()
    if not path.is_absolute():
        path = pathlib.Path.cwd() / path
    return path


def require_non_empty_file(value: str, label: str) -> pathlib.Path:
    path = user_path(value)
    if not path.is_file():
        raise SystemExit(f"{label} file missing: {path}")
    if path.stat().st_size == 0:
        raise SystemExit(f"{label} file is empty: {path}")
    return path


def placeholder_value(value: Any) -> bool:
    if value is None:
        return True
    if not isinstance(value, str):
        return False
    stripped = value.strip()
    if not stripped:
        return True
    return CLAW_PLACEHOLDER_TOKEN in stripped or stripped.startswith("<")


def require_real_evidence_file(value: str, label: str) -> pathlib.Path:
    path = require_non_empty_file(value, label)
    text = path.read_text(encoding="utf-8", errors="replace")
    if CLAW_PLACEHOLDER_TOKEN in text:
        raise SystemExit(f"{label} file still contains the AgentParty TODO marker: {path}")
    if len(text.strip()) < MIN_CLAW_EVIDENCE_CHARS:
        raise SystemExit(
            f"{label} file is too short for pack-ready evidence: {path} "
            f"(minimum {MIN_CLAW_EVIDENCE_CHARS} non-whitespace characters)"
        )
    return path


def require_evidence_link(value: Any) -> str | None:
    if placeholder_value(value):
        return None
    link = str(value).strip()
    parsed = urlparse(link)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SystemExit(f"Feishu link must be an http(s) URL, got: {link}")
    host = parsed.netloc.lower().split(":", 1)[0]
    allowed = ("feishu.cn", "larksuite.com", "larksuite.cn")
    if not any(host == domain or host.endswith("." + domain) for domain in allowed):
        raise SystemExit(f"Feishu link must be a Feishu/Lark URL (*.feishu.cn or *.larksuite.com), got: {link}")
    return link


def copy_evidence(src: pathlib.Path, dest_dir: pathlib.Path, filename: str) -> dict[str, Any]:
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / filename
    if src.resolve() != dest.resolve():
        shutil.copyfile(src, dest)
    return {
        "path": str(dest),
        "source_path": str(src),
        "sha256": sha256_file(dest),
        "bytes": dest.stat().st_size,
    }


def read_state(run_dir: pathlib.Path) -> dict[str, Any]:
    state_path = run_dir / "state.json"
    if not state_path.is_file():
        raise SystemExit(f"state.json missing: {state_path}")
    try:
        return json.loads(state_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"state.json is invalid JSON: {exc}") from exc


def enforce_pack_write_boundaries(state: dict[str, Any]) -> None:
    if not any(key in state for key in ("pack_id", "pack_ready", "true_triparty_ready", "completion_label")):
        return
    if state.get("schema_version") != "agentparty.pack-state.v1":
        raise SystemExit(
            "E_PACK_SCHEMA_UNKNOWN: AgentParty pack states must use schema_version=agentparty.pack-state.v1"
        )
    if state.get("pack_id") not in {"triparty", "claude-code-feishu-claw"}:
        raise SystemExit(f"E_PACK_ID_UNKNOWN: unsupported AgentParty pack state: {state.get('pack_id')}")
    if state.get("pack_id") != "triparty" and state.get("true_triparty_ready") is not False:
        raise SystemExit(
            "E_TRUE_TRIPARTY_FORBIDDEN: non-triparty AgentParty pack states must keep "
            "true_triparty_ready=false"
        )


def write_state(run_dir: pathlib.Path, state: dict[str, Any]) -> None:
    enforce_pack_write_boundaries(state)
    state["updated_at"] = utc_now()
    state_path = run_dir / "state.json"
    tmp = state_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(state_path)


def read_json_file(path: pathlib.Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"{label} missing: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{label} is invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"{label} must be a JSON object: {path}")
    return data


def write_new_text(path: pathlib.Path, text: str, force: bool = False) -> None:
    if path.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing file without --force: {path}")
    path.write_text(text, encoding="utf-8")


def write_new_json(path: pathlib.Path, data: dict[str, Any], force: bool = False) -> None:
    write_new_text(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n", force=force)


def run_captured(cmd: list[str], cwd: pathlib.Path | None = None) -> dict[str, Any]:
    completed = subprocess.run(
        cmd,
        cwd=str(cwd or ROOT),
        text=True,
        capture_output=True,
        check=False,
    )
    return {
        "command": cmd,
        "exit_code": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def parse_json_output(output: str, label: str) -> Any:
    text = output.strip()
    if not text:
        raise SystemExit(f"{label} did not return JSON output")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{label} returned invalid JSON: {exc}") from exc
        raise SystemExit(f"{label} returned invalid JSON")


def walk_json_strings(data: Any) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, str):
                found.append((str(key), value))
            else:
                found.extend(walk_json_strings(value))
    elif isinstance(data, list):
        for item in data:
            found.extend(walk_json_strings(item))
    return found


def feishu_link_from_create(data: Any) -> tuple[str, str | None]:
    strings = walk_json_strings(data)
    for key, value in strings:
        lowered = key.lower()
        if lowered in {"url", "link", "feishu_link", "document_url", "doc_url"} and "feishu.cn" in value:
            token = value.rstrip("/").split("/")[-1] if "/" in value.rstrip("/") else None
            return value, token
    for key, value in strings:
        lowered = key.lower()
        if lowered in {"doc_token", "document_id", "document_token", "token"} and len(value.strip()) >= 8:
            token = value.strip()
            return f"https://mi.feishu.cn/docx/{token}", token
    raise SystemExit("Feishu docx create output did not contain a document URL or token")


def markdown_from_fetch(data: Any) -> str:
    if isinstance(data, dict) and isinstance(data.get("markdown"), str):
        return data["markdown"]
    return ""


def default_e2e_title() -> str:
    return "AgentParty Claw E2E 测试文档 - " + datetime.now().strftime("%Y-%m-%d-%H%M%S")


def default_e2e_content(title: str) -> str:
    today = datetime.now().strftime("%Y-%m-%d")
    return f"""# {title}

这是 AgentParty Claude Code + Feishu Claw pack 的端到端测试文档。

创建日期：{today}。

目的：验证 Claude Code 计划、Feishu CLI 执行、Feishu fetch 校验、Claude Code 复核、AgentParty evidence import 与 validate-run 可以串成一个自动化闭环。

边界：这是 Feishu CLI E2E adapter，不是 Feishu Claw 原生 connector；true_triparty_ready 必须保持 false。
"""


def command_claw_e2e(args: argparse.Namespace) -> int:
    if native_windows():
        block_windows_native("claw e2e")
    if args.pack != "claude-code-feishu-claw":
        raise SystemExit("claw-e2e currently supports only --pack claude-code-feishu-claw")
    pack = require_pack(args.pack)

    out_dir = user_path(args.out) if args.out else RUNS_DIR / f"claw-e2e-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    prepare_claw_kit_out_dir(out_dir, args.force)
    evidence_dir = out_dir / "evidence"
    title = args.title or default_e2e_title()
    content = args.content or default_e2e_content(title)
    task = args.task

    claude_prompt_path = out_dir / "claude-code-prompt.txt"
    claw_prompt_path = out_dir / "feishu-claw-prompt.txt"
    plan_path = out_dir / "claude-code-plan.md"
    create_content_path = out_dir / "feishu-doc-content.md"
    e2e_result_path = out_dir / "e2e-result.json"
    bundle_path = evidence_dir / CLAW_EVIDENCE_BUNDLE_FILE

    bundle = claw_evidence_bundle(out_dir, task, evidence_dir)
    bundle["source_mode"] = "feishu_cli_e2e"
    evidence_files = write_claw_evidence_files(evidence_dir, bundle, force=True)
    write_new_text(claude_prompt_path, prompt_for_pack(args.pack, task) + "\n", force=True)
    write_new_text(claw_prompt_path, claw_prompt_text(task) + "\n", force=True)
    write_new_text(create_content_path, content, force=True)

    state = build_claw_state(
        out_dir,
        task,
        pack,
        {
            "claude_code_prompt": str(claude_prompt_path),
            "feishu_claw_prompt": str(claw_prompt_path),
            "evidence_dir": str(evidence_dir),
            "evidence_bundle": str(bundle_path),
            "e2e_result": str(e2e_result_path),
            "feishu_doc_content": str(create_content_path),
        },
    )
    state["source_mode"] = "feishu_cli_e2e"
    write_state(out_dir, state)

    plan_prompt = f"""请按 AgentParty 的 Claude Code + Feishu Claw 产品包为这个端到端测试输出简短计划。
任务：{task}
飞书文档标题：{title}
要求：列出执行步骤、证据要求、失败时应保持 partial/blocked 的条件。不要声称 true_triparty_ready=true。"""
    plan_result = run_captured(
        [
            args.claude_bin,
            "-p",
            plan_prompt,
            "--permission-mode",
            "dontAsk",
            "--tools",
            "",
            "--max-budget-usd",
            str(args.max_budget_usd),
        ],
        cwd=out_dir,
    )
    if plan_result["exit_code"] != 0:
        raise SystemExit("Claude Code plan failed: " + plan_result["stderr"][-1000:])
    write_new_text(plan_path, plan_result["stdout"], force=True)

    create_result = run_captured(
        [args.feishu_bin, "docx", "create", title, "-c", content],
        cwd=out_dir,
    )
    if create_result["exit_code"] not in {0, 3}:
        raise SystemExit("Feishu docx create failed: " + (create_result["stderr"] or create_result["stdout"])[-2000:])
    create_data = parse_json_output(create_result["stdout"], "feishu docx create")
    feishu_link, doc_token = feishu_link_from_create(create_data)

    fetch_result = run_captured([args.feishu_bin, "fetch", feishu_link], cwd=out_dir)
    if fetch_result["exit_code"] != 0:
        raise SystemExit("Feishu fetch verification failed: " + (fetch_result["stderr"] or fetch_result["stdout"])[-2000:])
    fetch_data = parse_json_output(fetch_result["stdout"], "feishu fetch")
    fetched_markdown = markdown_from_fetch(fetch_data)
    if isinstance(fetch_data, dict) and isinstance(fetch_data.get("token"), str):
        doc_token = fetch_data["token"]
    if title not in fetched_markdown and "AgentParty" not in fetched_markdown:
        raise SystemExit("Feishu fetch verification did not find expected AgentParty document content")

    review_prompt = f"""请复核 AgentParty claude-code-feishu-claw 的 Feishu CLI E2E 结果。
任务：{task}
文档链接：{feishu_link}
source_mode：feishu_cli_e2e
Claude 计划摘要：
{plan_result['stdout'][-4000:]}

Feishu fetch markdown：
{fetched_markdown[-5000:]}

请输出：证据来源、通过项、缺口、最终标签。若满足任务，请给 final label: pack_ready。必须说明 true_triparty_ready=false，且这是 Feishu CLI adapter，不是 Feishu Claw 原生 connector。"""
    review_result = run_captured(
        [
            args.claude_bin,
            "-p",
            review_prompt,
            "--permission-mode",
            "dontAsk",
            "--tools",
            "",
            "--max-budget-usd",
            str(args.max_budget_usd),
        ],
        cwd=out_dir,
    )
    if review_result["exit_code"] != 0:
        raise SystemExit("Claude Code review failed: " + review_result["stderr"][-1000:])

    transcript_text = f"""Source mode: feishu_cli_e2e
Captured by: AgentParty claw-e2e command
Captured at: {utc_now()}

Boundary:
This is an automated Feishu CLI adapter run. It proves the local end-to-end evidence loop can call Claude Code and Feishu CLI, but it is not a native Feishu Claw connector or auth automation.

Feishu document link:
{feishu_link}

Document token:
{doc_token or "unknown"}

Commands:
- Claude plan: {args.claude_bin} -p <plan-prompt>
- Feishu create: {args.feishu_bin} docx create <title> -c <content>
- Feishu fetch: {args.feishu_bin} fetch {feishu_link}
- Claude review: {args.claude_bin} -p <review-prompt>

Feishu create stdout:
{create_result['stdout']}

Feishu create stderr:
{create_result['stderr']}

Feishu fetch stdout:
{fetch_result['stdout']}

Feishu fetch stderr:
{fetch_result['stderr']}
"""
    summary_text = f"""Outcome against task brief: satisfied.

Source mode: feishu_cli_e2e.

Feishu link:
{feishu_link}

Summary:
AgentParty invoked Claude Code for planning, created a Feishu docx document through the local Feishu CLI, verified the resulting document through `feishu fetch`, invoked Claude Code for review, imported evidence, and validated the pack state.

Boundary:
This is end-to-end for the local Claude Code + Feishu CLI adapter. It is not native Feishu Claw connector automation and must keep true_triparty_ready=false.
"""

    write_new_text(evidence_files["transcript"], transcript_text, force=True)
    write_new_text(evidence_files["summary"], summary_text, force=True)
    write_new_text(evidence_files["review"], review_result["stdout"], force=True)
    bundle["feishu_link"] = feishu_link
    bundle["updated_at"] = utc_now()
    bundle["last_fill"] = {
        "updated_at": bundle["updated_at"],
        "mode": "feishu_cli_e2e",
        "artifacts_updated": ["feishu_claw_transcript", "operation_summary", "claude_code_review"],
        "feishu_link_set": True,
        "true_triparty_ready": False,
    }
    write_new_json(bundle_path, bundle, force=True)

    import_result = run_captured(
        [
            sys.executable,
            str(ROOT / "scripts/agentparty.py"),
            "evidence",
            "--pack",
            "claude-code-feishu-claw",
            "--bundle",
            str(bundle_path),
            "--json",
        ],
        cwd=ROOT,
    )
    if import_result["exit_code"] != 0:
        raise SystemExit("AgentParty evidence import failed: " + (import_result["stderr"] or import_result["stdout"])[-2000:])
    validate_result = run_captured(
        [
            sys.executable,
            str(ROOT / "scripts/agentparty.py"),
            "validate-run",
            "--run-dir",
            str(out_dir),
            "--json",
        ],
        cwd=ROOT,
    )
    if validate_result["exit_code"] != 0:
        raise SystemExit("AgentParty validate-run failed: " + (validate_result["stderr"] or validate_result["stdout"])[-2000:])

    final_state = read_state(out_dir)
    result = {
        "schema_version": "agentparty.claw-e2e.v1",
        "run_dir": str(out_dir),
        "state": str(out_dir / "state.json"),
        "evidence_bundle": str(bundle_path),
        "feishu_link": feishu_link,
        "doc_token": doc_token,
        "source_mode": "feishu_cli_e2e",
        "native_claw_connector": False,
        "pack_ready": final_state.get("pack_ready"),
        "completion_label": final_state.get("completion_label"),
        "true_triparty_ready": final_state.get("true_triparty_ready"),
        "claude_plan": {
            "exit_code": plan_result["exit_code"],
            "path": str(plan_path),
        },
        "feishu_create": {
            "exit_code": create_result["exit_code"],
        },
        "feishu_fetch": {
            "exit_code": fetch_result["exit_code"],
        },
        "claude_review": {
            "exit_code": review_result["exit_code"],
            "path": str(evidence_files["review"]),
        },
        "evidence_import": parse_json_output(import_result["stdout"], "agentparty evidence"),
        "validation": parse_json_output(validate_result["stdout"], "agentparty validate-run"),
        "boundary": "Automated Claude Code + Feishu CLI E2E adapter; not native Feishu Claw connector automation.",
    }
    write_new_json(e2e_result_path, result, force=True)
    if args.json:
        print_json(result)
    else:
        print(f"AgentParty Claw E2E complete: {out_dir}")
        print(f"Feishu link: {feishu_link}")
        print(f"Status: {result['completion_label']}")
        print(f"Pack ready: {result['pack_ready']}")
        print("True tri-party ready: false")
        print("Boundary: Feishu CLI E2E adapter, not native Feishu Claw connector automation.")
    return 0


def native_windows() -> bool:
    if os.environ.get("AGENTPARTY_FORCE_NATIVE_WINDOWS") == "1":
        return True
    system = platform.system().lower()
    return os.name == "nt" or system.startswith(("msys", "mingw", "cygwin"))


def running_in_wsl() -> bool:
    if os.environ.get("AGENTPARTY_FORCE_NATIVE_WINDOWS") == "1":
        return False
    if platform.system().lower() != "linux":
        return False
    release = platform.release().lower()
    if "microsoft" in release or "wsl" in release:
        return True
    try:
        return "microsoft" in pathlib.Path("/proc/version").read_text(encoding="utf-8").lower()
    except OSError:
        return False


def detected_os_key() -> str:
    if native_windows():
        return "windows_powershell"
    system = platform.system().lower()
    if system == "darwin":
        return "macos"
    if running_in_wsl():
        return "windows_wsl2"
    if system == "linux":
        return "linux"
    return "unknown"


def block_windows_native(action: str) -> None:
    raise SystemExit(
        f"E_BLOCKED_OS: Windows non-WSL AgentParty {action} is roadmap and is not verified. "
        "Use Windows WSL2, macOS, or Linux for executable checks and run workflows. "
        "Start with: wsl --install -d Ubuntu"
    )


def command_packs(args: argparse.Namespace) -> int:
    registry = load_registry()
    if args.json:
        print_json(registry)
        return 0
    for pack in registry["packs"]:
        agents = " + ".join(agent["name"] for agent in pack["agents"])
        ready = pack["completion_semantics"]["ready_label"]
        print(f"{pack['id']}\t{pack['status']}\t{ready}\t{agents}")
    return 0


def command_info(args: argparse.Namespace) -> int:
    pack_id = args.pack_flag or args.pack
    if args.pack_flag and args.pack and args.pack_flag != args.pack:
        raise SystemExit(f"E_PACK_CONFLICT: info received both positional pack={args.pack} and --pack={args.pack_flag}")
    if not pack_id:
        raise SystemExit("E_PACK_REQUIRED: info requires a pack id, for example: agentparty info --pack triparty")
    pack = require_pack(pack_id)
    if args.json:
        print_json(pack)
        return 0
    print(f"Pack: {pack['display_name']} ({pack['id']})")
    print(f"Status: {pack['status']}")
    print(f"Ready label: {pack['completion_semantics']['ready_label']}")
    print(f"Must not claim: {', '.join(pack['completion_semantics']['must_not_claim'])}")
    print("Agents:")
    for agent in pack["agents"]:
        print(f"- {agent['name']}: {agent['role']} [{agent['source']}]")
    print("OS support:")
    for os_name, status in pack["os_support"].items():
        print(f"- {os_name}: {status}")
    print(f"Docs: {pack['docs']}")
    return 0


def prompt_for_pack(pack_id: str, task: str) -> str:
    if pack_id == "triparty":
        return f"""请在这台机器上安装并使用 triparty。
目标仓库：https://github.com/r-design-j/tri-party-framework
任务：{task}
执行要求：
先判断系统环境：macOS / Linux / Windows WSL2 可按当前流程执行；Windows 原生 PowerShell/CMD 目前只做环境准备和检查，不要硬跑 bash 脚本，请引导进入 WSL2 或等待 PowerShell 原生 AgentParty CLI 路线完成。
1. clone 仓库并进入目录。
2. 补齐必要脚本权限。
3. 运行 scripts/triparty-lint.sh。
4. 安装全局发现规则和 triparty 命令。
5. 运行 triparty preflight。
6. 对任务运行 triparty run。
7. 如果缺少 Claude Code、Gemini CLI、认证或权限，请明确报告缺失项；不要把 partial run / 未完成协作说成 true tri-party / 完整三方。
完成后告诉我本机安装路径、preflight 结果、run 目录和 release gate 结果。"""

    if pack_id == "claude-code-feishu-claw":
        return f"""请按 AgentParty 的 Claude Code + Feishu Claw 产品包处理这个任务。
目标：{task}
要求：
1. Claude Code 先输出任务拆解、风险、需要 Claw 执行的飞书动作。
2. 把 Claw 要执行的动作写成可复制指令。
3. Claw 执行后，返回可填入 AgentParty evidence bundle 的飞书链接、操作摘要和 transcript。
4. Claude Code 读取 transcript，检查是否满足任务 brief。
5. 如果缺权限、缺链接、缺 transcript 或结果不一致，标记 partial，不要声称完整完成。
6. 这是 2-agent AgentParty pack，不要声称 true tri-party，不要写 true_triparty_ready=true。
7. 最终只允许输出 pack_ready、partial、blocked 或 scoped。"""

    pack = require_pack(pack_id)
    return f"AgentParty pack {pack['id']} has no prompt template yet. See {pack['docs']}."


def plan_commands_for_supported_os(pack_id: str) -> list[str]:
    if pack_id == "triparty":
        return [
            "git clone https://github.com/r-design-j/tri-party-framework.git",
            "cd tri-party-framework",
            "chmod +x scripts/*.sh adapters/http/triparty_http_adapter.py adapters/mcp/triparty_mcp_adapter.py",
            "scripts/triparty-lint.sh",
            "scripts/agentparty.sh install --pack triparty --target-os auto",
            "scripts/agentparty.sh install --pack triparty --target-os auto --execute",
            "scripts/agentparty.sh guide --pack triparty --target-os auto",
            "triparty preflight",
            "triparty run '<task>'",
            "triparty release-gate '<run-dir>'",
        ]
    if pack_id == "claude-code-feishu-claw":
        return [
            "git clone https://github.com/r-design-j/tri-party-framework.git",
            "cd tri-party-framework",
            "chmod +x scripts/*.sh scripts/agentparty.py scripts/agentparty-pack-lint.py",
            "scripts/agentparty.sh install --pack claude-code-feishu-claw --target-os auto",
            "scripts/agentparty.sh install --pack claude-code-feishu-claw --target-os auto --execute",
            "scripts/agentparty.sh doctor --pack claude-code-feishu-claw",
            "scripts/agentparty.sh kit --pack claude-code-feishu-claw --task '<task>' --out '<kit-dir>'",
            "scripts/agentparty.sh run --pack claude-code-feishu-claw --task '<task>'",
            "scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir '<run-dir>'",
            "scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir '<run-dir>' --out '<bundle-dir>'",
            "scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle '<bundle-dir>/agentparty-claw-evidence.json' --feishu-link '<feishu-link>'",
            "scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle '<bundle-dir>/agentparty-claw-evidence.json'",
            "scripts/agentparty.sh validate-run --run-dir '<run-dir>'",
            "scripts/agentparty.sh claw-e2e --pack claude-code-feishu-claw --task '<task>' --out '<run-dir>'",
        ]
    return ["scripts/agentparty.sh prompt --pack '<pack-id>' --task '<task>'"]


def install_plan(pack: dict[str, Any], target_os: str) -> dict[str, Any]:
    pack_id = pack["id"]
    supported = target_os in SUPPORTED_EXECUTABLE_OSES
    powershell = target_os == "windows_powershell"
    if target_os == "auto":
        target_os = detected_os_key()
        supported = target_os in SUPPORTED_EXECUTABLE_OSES
        powershell = target_os == "windows_powershell"

    powershell_prep_surfaces = "discovery, doctor, install dry-run, prompt, quickstart, onboard, guide, and install planning"
    if pack_id == "claude-code-feishu-claw":
        powershell_prep_surfaces = "discovery, doctor, install dry-run, prompt, quickstart, onboard, guide, validate-run, kit, evidence-template, evidence-fill, and install planning"
    os_support = pack.get("os_support", {}).get(target_os, "blocked")
    plan: dict[str, Any] = {
        "pack_id": pack_id,
        "target_os": target_os,
        "registry_os_support": os_support,
        "executable_status": "supported" if supported else "roadmap",
        "run_supported": supported,
        "deep_doctor_supported": supported and pack_id == "triparty",
        "evidence_import_supported": supported and pack_id == "claude-code-feishu-claw",
        "prompt_supported": True,
        "true_triparty_ready_allowed": pack_id == "triparty",
        "recommended_path": "Use macOS/Linux/Windows WSL2 executable path." if supported else f"Use Windows WSL2 for executable run workflows; use native PowerShell only for {powershell_prep_surfaces}.",
        "commands": plan_commands_for_supported_os(pack_id) if supported else [],
        "cleanup_commands": [
            "scripts/uninstall-triparty-global-bootstrap.sh --dry-run",
            "scripts/uninstall-triparty-global-bootstrap.sh --execute",
        ] if supported else [],
        "native_powershell_commands": [],
        "blocked_commands": [],
        "notes": [],
    }

    if powershell:
        plan["native_powershell_commands"] = [
            "winget install Git.Git",
            "winget install Python.Python.3.12",
            ".\\scripts\\agentparty.ps1 packs",
            ".\\scripts\\agentparty.ps1 doctor --pack " + pack_id,
            ".\\scripts\\agentparty.ps1 install --pack " + pack_id + " --target-os windows_powershell",
            ".\\scripts\\agentparty.ps1 install-plan --pack " + pack_id + " --target-os windows_powershell",
            ".\\scripts\\agentparty.ps1 onboard --pack " + pack_id + " --target-os windows_powershell",
            ".\\scripts\\agentparty.ps1 quickstart --pack " + pack_id + " --target-os windows_powershell",
            ".\\scripts\\agentparty.ps1 prompt --pack " + pack_id + " --task '<task>'",
            ".\\scripts\\agentparty.ps1 guide --pack " + pack_id + " --target-os windows_powershell",
            ".\\scripts\\uninstall-triparty-global-bootstrap.ps1 -DryRun",
            ".\\scripts\\uninstall-triparty-global-bootstrap.ps1 -Execute",
            "wsl --install -d Ubuntu",
        ]
        if pack_id == "claude-code-feishu-claw":
            plan["native_powershell_commands"].insert(
                8,
                ".\\scripts\\agentparty.ps1 kit --pack claude-code-feishu-claw --task '<task>' --out '<kit-dir>'",
            )
            plan["native_powershell_commands"].insert(
                9,
                ".\\scripts\\agentparty.ps1 evidence-template --pack claude-code-feishu-claw --run-dir '<run-dir>' --out '<bundle-dir>'",
            )
            plan["native_powershell_commands"].insert(
                10,
                ".\\scripts\\agentparty.ps1 evidence-fill --pack claude-code-feishu-claw --bundle '<bundle-dir>\\agentparty-claw-evidence.json' --feishu-link '<feishu-link>'",
            )
            plan["native_powershell_commands"].insert(
                12,
                ".\\scripts\\agentparty.ps1 validate-run --run-dir '<run-dir>'",
            )
        plan["blocked_commands"] = [
            ".\\scripts\\agentparty.ps1 install --pack " + pack_id + " --target-os windows_powershell --execute",
            ".\\scripts\\agentparty.ps1 run --pack " + pack_id + " --task '<task>'",
            ".\\scripts\\agentparty.ps1 doctor --pack " + pack_id + " --deep",
        ]
        if pack_id == "claude-code-feishu-claw":
            plan["blocked_commands"].append(".\\scripts\\agentparty.ps1 evidence --pack claude-code-feishu-claw --run-dir '<run-dir>' ...")
            plan["blocked_commands"].append(".\\scripts\\agentparty.ps1 claw-e2e --pack claude-code-feishu-claw --task '<task>' --out '<run-dir>'")
        plan["notes"].append("Windows native PowerShell/CMD/Git Bash/MSYS/Cygwin run workflows are not shipped.")
        plan["notes"].append("After WSL2 is installed, rerun the supported Linux commands inside Ubuntu.")

    if pack_id != "triparty":
        plan["true_triparty_ready_allowed"] = False
        plan["notes"].append("Non-triparty packs can become pack_ready only; they must keep true_triparty_ready=false.")
    if pack_id == "claude-code-feishu-claw":
        plan["notes"].append("Feishu Claw evidence is imported from a manual evidence bundle or transcript/link/summary/Claude review flags; native Feishu Claw connector collection is roadmap.")
        plan["notes"].append("A scoped claw-e2e command can automate Claude Code + Feishu CLI evidence collection; it is not a native Claw connector.")
    return plan


def command_install_plan(args: argparse.Namespace) -> int:
    pack = require_pack(args.pack)
    plan = install_plan(pack, args.target_os)
    if args.json:
        print_json(plan)
        return 0
    print(f"Pack: {pack['display_name']} ({pack['id']})")
    print(f"Target OS: {plan['target_os']}")
    print(f"Executable status: {plan['executable_status']}")
    print(f"Run supported: {str(plan['run_supported']).lower()}")
    print(f"Evidence import supported: {str(plan['evidence_import_supported']).lower()}")
    print(f"Prompt supported: {str(plan['prompt_supported']).lower()}")
    print(f"Recommended path: {plan['recommended_path']}")
    if plan["commands"]:
        print("Commands:")
        for command in plan["commands"]:
            print(f"- {command}")
    if plan["cleanup_commands"]:
        print("Cleanup commands:")
        for command in plan["cleanup_commands"]:
            print(f"- {command}")
    if plan["native_powershell_commands"]:
        print("Native PowerShell preparation commands:")
        for command in plan["native_powershell_commands"]:
            print(f"- {command}")
    if plan["blocked_commands"]:
        print("Blocked until native Windows execution is productized:")
        for command in plan["blocked_commands"]:
            print(f"- {command}")
    if plan["notes"]:
        print("Notes:")
        for note in plan["notes"]:
            print(f"- {note}")
    return 0


def install_preview(pack: dict[str, Any], target_os: str) -> dict[str, Any]:
    plan = install_plan(pack, target_os)
    pack_id = pack["id"]
    detected = detected_os_key()
    supported = plan["target_os"] in SUPPORTED_EXECUTABLE_OSES
    target_matches_host = target_os == "auto" or plan["target_os"] == detected
    execute_supported = supported and target_matches_host
    actions = [
        "write framework discovery config",
        "install triparty and agentparty CLI wrappers",
        "write managed Codex and Claude Code bootstrap blocks",
        "install Claude Code /triparty, /tp, /agentparty-claw, and /ap-claw command surfaces",
    ]
    result: dict[str, Any] = {
        "pack_id": pack_id,
        "target_os": plan["target_os"],
        "detected_os": detected,
        "install_supported": supported,
        "execute_supported": execute_supported,
        "target_matches_host": target_matches_host,
        "run_supported": plan["run_supported"],
        "evidence_import_supported": plan["evidence_import_supported"],
        "true_triparty_ready_allowed": pack_id == "triparty",
        "installer": str(BOOTSTRAP_INSTALLER),
        "actions": actions if supported else [],
        "cleanup_commands": plan["cleanup_commands"],
        "blocked_commands": plan["blocked_commands"],
        "notes": list(plan["notes"]),
    }
    if not supported:
        result["blocked_reason"] = (
            "E_BLOCKED_OS: Windows non-WSL AgentParty install execute is roadmap and is not verified. "
            "Use Windows WSL2, macOS, or Linux for managed install execution. "
            "Start with: wsl --install -d Ubuntu"
        )
        result["recommended_path"] = plan["recommended_path"]
    elif not target_matches_host:
        result["blocked_reason"] = (
            f"AgentParty install execute target mismatch: requested {plan['target_os']} "
            f"but detected {detected}. Re-run with --target-os auto on the host that will execute the install."
        )
        result["recommended_path"] = "Use --target-os auto for execution, or run the command inside the target OS environment."
    if pack_id != "triparty":
        result["notes"].append("This installs the shared AgentParty/triparty bootstrap, not a true tri-party completion claim.")
    if pack_id == "claude-code-feishu-claw":
        result["notes"].append("Feishu Claw connector/auth automation is roadmap; this pack currently installs prompt/evidence scaffolding only.")
    return result


def print_install_preview(preview: dict[str, Any]) -> None:
    print(f"Pack: {preview['pack_id']}")
    print(f"Target OS: {preview['target_os']}")
    print(f"Detected OS: {preview['detected_os']}")
    print(f"Install supported: {str(preview['install_supported']).lower()}")
    print(f"Execute supported: {str(preview['execute_supported']).lower()}")
    print("Mode: dry-run")
    if preview["install_supported"]:
        print("Managed actions:")
        for action in preview["actions"]:
            print(f"- {action}")
        print(f"Installer: {preview['installer']}")
        if preview["execute_supported"]:
            print("No changes made. Re-run with --execute to install managed artifacts.")
        else:
            print(f"No changes made. Execute blocked: {preview['blocked_reason']}")
    else:
        print(f"Blocked: {preview['blocked_reason']}")
        print(f"Recommended path: {preview['recommended_path']}")
    if preview["cleanup_commands"]:
        print("Cleanup commands:")
        for command in preview["cleanup_commands"]:
            print(f"- {command}")
    if preview["notes"]:
        print("Notes:")
        for note in preview["notes"]:
            print(f"- {note}")


def command_install(args: argparse.Namespace) -> int:
    pack = require_pack(args.pack)
    preview = install_preview(pack, args.target_os)
    dry_run = not args.execute
    preview["dry_run"] = dry_run
    preview["executed"] = False
    if dry_run:
        if args.json:
            print_json(preview)
        else:
            print_install_preview(preview)
        return 0

    if not preview["execute_supported"]:
        preview["error"] = preview["blocked_reason"]
        if args.json:
            print_json(preview)
        else:
            print(f"ERROR: {preview['blocked_reason']}", file=sys.stderr)
            print(f"Recommended path: {preview['recommended_path']}", file=sys.stderr)
        return 2

    completed = subprocess.run(
        [str(BOOTSTRAP_INSTALLER)],
        cwd=str(ROOT),
        text=True,
        capture_output=True,
        check=False,
    )
    preview["executed"] = True
    preview["exit_code"] = completed.returncode
    preview["stdout"] = completed.stdout
    preview["stderr"] = completed.stderr
    if args.json:
        print_json(preview)
    else:
        if completed.stdout:
            print(completed.stdout, end="")
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr)
        if completed.returncode == 0:
            print(f"AgentParty managed install complete for pack: {pack['id']}")
        else:
            print(f"AgentParty managed install failed for pack: {pack['id']}", file=sys.stderr)
    return completed.returncode


def command_prompt(args: argparse.Namespace) -> int:
    require_pack(args.pack)
    print(prompt_for_pack(args.pack, args.task))
    return 0


def run_triparty(args: argparse.Namespace) -> int:
    cmd = [str(TRIPARTY), "run", args.task]
    if args.context_files:
        cmd.extend(args.context_files)
    return subprocess.call(cmd, cwd=str(ROOT))


def slug(value: str) -> str:
    cleaned = []
    for char in value.lower():
        if char.isalnum():
            cleaned.append(char)
        elif cleaned and cleaned[-1] != "-":
            cleaned.append("-")
    return "".join(cleaned).strip("-")[:48] or "task"


def create_claw_run(args: argparse.Namespace) -> int:
    pack = require_pack("claude-code-feishu-claw")
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = RUNS_DIR / f"claude-code-feishu-claw-{timestamp}-{slug(args.task)}"
    run_dir.mkdir(parents=True, exist_ok=False)

    claude_prompt = prompt_for_pack("claude-code-feishu-claw", args.task)
    claw_prompt = f"""飞书小龙虾 Claw 执行指令
任务：{args.task}

请在飞书中完成 Claude Code 指定的文档/流程动作，并返回：
1. 飞书链接。
2. 操作摘要。
3. 执行 transcript。
4. 未完成项、权限缺口或需要用户确认的地方。

注意：这些内容会被填入 AgentParty evidence bundle。这是 2-agent 产品包证据，不是 true tri-party。"""

    (run_dir / "claude-code-prompt.txt").write_text(claude_prompt + "\n", encoding="utf-8")
    (run_dir / "feishu-claw-prompt.txt").write_text(claw_prompt + "\n", encoding="utf-8")
    (run_dir / "README.md").write_text(
        f"""# AgentParty Run: Claude Code + Feishu Claw

- Pack: `claude-code-feishu-claw`
- Task: {args.task}
- Status: partial until Feishu Claw transcript is provided and reviewed.

## Files

- `claude-code-prompt.txt`: copy into Claude Code.
- `feishu-claw-prompt.txt`: copy into Feishu Claw.
- `state.json`: pack state for this scaffold run.

## Evidence Bundle

Create a fill-in evidence bundle:

```bash
scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir "{run_dir}" --out "{run_dir / 'claw-evidence'}"
```

After filling it, import:

```bash
scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle "{run_dir / 'claw-evidence' / CLAW_EVIDENCE_BUNDLE_FILE}"
scripts/agentparty.sh validate-run --run-dir "{run_dir}"
```
""",
        encoding="utf-8",
    )

    state = {
        "schema_version": "agentparty.pack-state.v1",
        "generated_at": utc_now(),
        "pack_id": "claude-code-feishu-claw",
        "pack_status": "partial",
        "pack_ready": False,
        "true_triparty_ready": False,
        "completion_label": "partial",
        "task": args.task,
        "run_dir": str(run_dir),
        "errors": [
            {
                "code": "E_CLAW_TRANSCRIPT_MISSING",
                "message": "Feishu Claw transcript and document evidence have not been provided yet."
            }
        ],
        "agents": [
            {
                "id": agent["id"],
                "name": agent["name"],
                "role": agent["role"],
                "evidence_status": "planned"
            }
            for agent in pack["agents"]
        ],
        "artifacts": {
            "claude_code_prompt": str(run_dir / "claude-code-prompt.txt"),
            "feishu_claw_prompt": str(run_dir / "feishu-claw-prompt.txt"),
            "evidence_dir": str(run_dir / "evidence")
        }
    }
    enforce_pack_write_boundaries(state)
    (run_dir / "state.json").write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"AgentParty pack run created: {run_dir}")
    print(f"State: {run_dir / 'state.json'}")
    print("Status: partial; waiting for Feishu Claw transcript evidence.")
    return 0


def require_claw_state(run_dir: pathlib.Path) -> dict[str, Any]:
    state = read_state(run_dir)
    if state.get("pack_id") != "claude-code-feishu-claw":
        raise SystemExit(f"run is not a claude-code-feishu-claw pack run: {run_dir}")
    state_run_dir = state.get("run_dir")
    if state_run_dir and user_path(str(state_run_dir)).resolve() != run_dir.resolve():
        raise SystemExit(f"state.json run_dir does not match requested run directory: {run_dir}")
    return state


def command_evidence_template(args: argparse.Namespace) -> int:
    require_pack(args.pack)
    if args.pack != "claude-code-feishu-claw":
        raise SystemExit("evidence-template currently supports only --pack claude-code-feishu-claw")

    run_dir = user_path(args.run_dir)
    state = require_claw_state(run_dir)
    out_dir = user_path(args.out)
    if out_dir.exists() and not out_dir.is_dir():
        raise SystemExit(f"evidence template output path is not a directory: {out_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)

    bundle_path = out_dir / CLAW_EVIDENCE_BUNDLE_FILE
    transcript_path = out_dir / "feishu-claw-transcript.txt"
    summary_path = out_dir / "operation-summary.txt"
    review_path = out_dir / "claude-code-review.txt"
    readme_path = out_dir / "README.md"
    template_paths = [bundle_path, transcript_path, summary_path, review_path, readme_path]
    if not args.force:
        existing = [str(path) for path in template_paths if path.exists()]
        if existing:
            raise SystemExit("refusing to overwrite existing template files without --force: " + ", ".join(existing))

    bundle = {
        "schema_version": CLAW_EVIDENCE_BUNDLE_SCHEMA,
        "pack_id": "claude-code-feishu-claw",
        "created_at": utc_now(),
        "source_mode": "manual_transcript",
        "run_dir": str(run_dir),
        "task": state.get("task"),
        "feishu_link": "",
        "artifacts": {
            "feishu_claw_transcript": transcript_path.name,
            "operation_summary": summary_path.name,
            "claude_code_review": review_path.name,
        },
        "blocked_reason": "",
        "completion_boundary": {
            "allowed_labels": ["pack_ready", "partial", "blocked", "scoped"],
            "true_triparty_ready": False,
        },
        "instructions": [
            "Replace TODO markers in the text files with real Claw transcript, operation summary, and Claude Code review evidence.",
            "Set feishu_link to the Feishu document or workflow URL returned by Claw.",
            "Use blocked_reason only when permissions, auth, or user confirmation prevent completion.",
            "This bundle is manual evidence; it does not imply Feishu connector/auth automation.",
        ],
    }

    write_new_json(bundle_path, bundle, force=args.force)
    write_new_text(
        transcript_path,
        f"""{CLAW_PLACEHOLDER_TOKEN}: paste the Feishu Claw transcript here.

Required content:
- What Claw did in Feishu.
- Feishu document or workflow operation evidence.
- Any permission, auth, or confirmation gaps.
""",
        force=args.force,
    )
    write_new_text(
        summary_path,
        f"""{CLAW_PLACEHOLDER_TOKEN}: summarize the Feishu operation result here.

Required content:
- Outcome against the original task brief.
- Feishu link owner or visible access boundary if known.
- Missing or unresolved items.
""",
        force=args.force,
    )
    write_new_text(
        review_path,
        f"""{CLAW_PLACEHOLDER_TOKEN}: paste Claude Code's review of the Claw transcript here.

Required content:
- Whether the Claw output satisfies the task brief.
- Whether evidence is sufficient for pack_ready.
- Final label: pack_ready, partial, blocked, or scoped.
""",
        force=args.force,
    )
    write_new_text(
        readme_path,
        f"""# AgentParty Claude Code + Feishu Claw Evidence Bundle

1. Fill `feishu-claw-transcript.txt`, `operation-summary.txt`, and `claude-code-review.txt`.
2. Either edit `{CLAW_EVIDENCE_BUNDLE_FILE}` and set `feishu_link`, or run:

```bash
scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle "{bundle_path}" --feishu-link "<feishu-link>"
```

3. Import the bundle:

```bash
scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle "{bundle_path}"
scripts/agentparty.sh validate-run --run-dir "{run_dir}"
```

This is a 2-agent AgentParty pack. It can become `pack_ready`, `partial`, `blocked`, or `scoped`, but it must keep `true_triparty_ready=false`.
""",
        force=args.force,
    )

    result = {
        "bundle_dir": str(out_dir),
        "bundle": str(bundle_path),
        "run_dir": str(run_dir),
        "files": [str(transcript_path), str(summary_path), str(review_path), str(readme_path)],
        "true_triparty_ready": False,
    }
    if args.json:
        print_json(result)
    else:
        print(f"AgentParty Claw evidence template created: {out_dir}")
        print(f"Bundle: {bundle_path}")
        print("Next: fill the files, set feishu_link with evidence-fill or by editing the bundle, then import with:")
        print(f"scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle '{bundle_path}' --feishu-link '<feishu-link>'")
        print(f"scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle '{bundle_path}'")
    return 0


def prepare_claw_kit_out_dir(out_dir: pathlib.Path, force: bool) -> None:
    if out_dir.exists():
        if not out_dir.is_dir():
            raise SystemExit(f"Claw kit output path exists but is not a directory: {out_dir}")
        if any(out_dir.iterdir()):
            if not force:
                raise SystemExit(f"Claw kit output directory is not empty; re-run with --force: {out_dir}")
            if not (out_dir / "agentparty-claw-kit.json").is_file():
                raise SystemExit(
                    "refusing to --force a non-AgentParty Claw kit directory without "
                    f"agentparty-claw-kit.json: {out_dir}"
                )
            shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)


def prepare_claw_bridge_out_dir(out_dir: pathlib.Path, force: bool) -> None:
    if out_dir.exists():
        if not out_dir.is_dir():
            raise SystemExit(f"Claw bridge output path exists but is not a directory: {out_dir}")
        if any(out_dir.iterdir()):
            if not force:
                raise SystemExit(f"Claw bridge output directory is not empty; re-run with --force: {out_dir}")
            if not (out_dir / CLAW_BRIDGE_MANIFEST_FILE).is_file():
                raise SystemExit(
                    "refusing to --force a non-AgentParty Claw bridge directory without "
                    f"{CLAW_BRIDGE_MANIFEST_FILE}: {out_dir}"
                )
            shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)


def claw_prompt_text(task: str) -> str:
    return f"""飞书小龙虾 Claw 执行指令
任务：{task}

请在飞书中完成 Claude Code 指定的文档/流程动作，并返回：
1. 飞书链接。
2. 操作摘要。
3. 执行 transcript。
4. 未完成项、权限缺口或需要用户确认的地方。

注意：这些内容会被填入 AgentParty evidence bundle。这是 2-agent 产品包证据，不是 true tri-party。"""


def build_claw_state(run_dir: pathlib.Path, task: str, pack: dict[str, Any], artifacts: dict[str, str]) -> dict[str, Any]:
    state = {
        "schema_version": "agentparty.pack-state.v1",
        "generated_at": utc_now(),
        "pack_id": "claude-code-feishu-claw",
        "pack_status": "partial",
        "pack_ready": False,
        "true_triparty_ready": False,
        "completion_label": "partial",
        "task": task,
        "run_dir": str(run_dir),
        "errors": [
            {
                "code": "E_CLAW_TRANSCRIPT_MISSING",
                "message": "Feishu Claw transcript and document evidence have not been provided yet."
            }
        ],
        "agents": [
            {
                "id": agent["id"],
                "name": agent["name"],
                "role": agent["role"],
                "evidence_status": "planned"
            }
            for agent in pack["agents"]
        ],
        "artifacts": artifacts,
    }
    enforce_pack_write_boundaries(state)
    return state


def claw_evidence_bundle(run_dir: pathlib.Path, task: str, evidence_dir: pathlib.Path) -> dict[str, Any]:
    return {
        "schema_version": CLAW_EVIDENCE_BUNDLE_SCHEMA,
        "pack_id": "claude-code-feishu-claw",
        "created_at": utc_now(),
        "source_mode": "manual_transcript",
        "run_dir": str(run_dir),
        "task": task,
        "feishu_link": "",
        "artifacts": {
            "feishu_claw_transcript": "feishu-claw-transcript.txt",
            "operation_summary": "operation-summary.txt",
            "claude_code_review": "claude-code-review.txt",
        },
        "blocked_reason": "",
        "completion_boundary": {
            "allowed_labels": ["pack_ready", "partial", "blocked", "scoped"],
            "true_triparty_ready": False,
        },
        "instructions": [
            "Replace TODO markers in the text files with real Claw transcript, operation summary, and Claude Code review evidence.",
            "Set feishu_link to the Feishu document or workflow URL returned by Claw.",
            "Use blocked_reason only when permissions, auth, or user confirmation prevent completion.",
            "This bundle is manual evidence; it does not imply Feishu connector/auth automation.",
        ],
    }


def write_claw_evidence_files(evidence_dir: pathlib.Path, bundle: dict[str, Any], force: bool = False) -> dict[str, pathlib.Path]:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    bundle_path = evidence_dir / CLAW_EVIDENCE_BUNDLE_FILE
    transcript_path = evidence_dir / "feishu-claw-transcript.txt"
    summary_path = evidence_dir / "operation-summary.txt"
    review_path = evidence_dir / "claude-code-review.txt"
    readme_path = evidence_dir / "README.md"
    for path in [bundle_path, transcript_path, summary_path, review_path, readme_path]:
        if path.exists() and not force:
            raise SystemExit(f"refusing to overwrite existing file without --force: {path}")

    write_new_json(bundle_path, bundle, force=force)
    write_new_text(
        transcript_path,
        f"""{CLAW_PLACEHOLDER_TOKEN}: paste the Feishu Claw transcript here.

Required content:
- What Claw did in Feishu.
- Feishu document or workflow operation evidence.
- Any permission, auth, or confirmation gaps.
""",
        force=force,
    )
    write_new_text(
        summary_path,
        f"""{CLAW_PLACEHOLDER_TOKEN}: summarize the Feishu operation result here.

Required content:
- Outcome against the original task brief.
- Feishu link owner or visible access boundary if known.
- Missing or unresolved items.
""",
        force=force,
    )
    write_new_text(
        review_path,
        f"""{CLAW_PLACEHOLDER_TOKEN}: paste Claude Code's review of the Claw transcript here.

Required content:
- Whether the Claw output satisfies the task brief.
- Whether evidence is sufficient for pack_ready.
- Final label: pack_ready, partial, blocked, or scoped.
""",
        force=force,
    )
    write_new_text(
        readme_path,
        f"""# AgentParty Claude Code + Feishu Claw Evidence Bundle

1. Fill `feishu-claw-transcript.txt`, `operation-summary.txt`, and `claude-code-review.txt`.
2. Either edit `{CLAW_EVIDENCE_BUNDLE_FILE}` and set `feishu_link`, or run:

```bash
scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle "{bundle_path}" --feishu-link "<feishu-link>"
```

3. Import the bundle:

```bash
scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle "{bundle_path}"
scripts/agentparty.sh validate-run --run-dir "{bundle.get("run_dir")}"
```

This is a 2-agent AgentParty pack. It can become `pack_ready`, `partial`, `blocked`, or `scoped`, but it must keep `true_triparty_ready=false`.
""",
        force=force,
    )
    return {
        "bundle": bundle_path,
        "transcript": transcript_path,
        "summary": summary_path,
        "review": review_path,
        "readme": readme_path,
    }


def command_kit(args: argparse.Namespace) -> int:
    if args.pack != "claude-code-feishu-claw":
        raise SystemExit("kit currently supports only --pack claude-code-feishu-claw")
    pack = require_pack(args.pack)
    out_dir = user_path(args.out)
    prepare_claw_kit_out_dir(out_dir, args.force)
    plan = install_plan(pack, args.target_os)
    evidence_dir = out_dir / "evidence"
    kit_manifest_path = out_dir / "agentparty-claw-kit.json"
    claude_prompt_path = out_dir / "claude-code-prompt.txt"
    claw_prompt_path = out_dir / "feishu-claw-prompt.txt"
    action_request_path = out_dir / "claw-action-request.md"
    task_brief_path = out_dir / "task-brief.md"
    start_here_path = out_dir / "START_HERE.md"
    readme_path = out_dir / "README.md"

    bundle = claw_evidence_bundle(out_dir, args.task, evidence_dir)
    evidence_files = write_claw_evidence_files(evidence_dir, bundle, force=True)
    write_new_text(claude_prompt_path, prompt_for_pack(args.pack, args.task) + "\n", force=True)
    write_new_text(claw_prompt_path, claw_prompt_text(args.task) + "\n", force=True)
    write_new_text(
        action_request_path,
        f"""# Claw Action Request

Task: {args.task}

Copy the relevant Claude Code plan into Feishu Claw, then ask Claw to return:

- Feishu document or workflow link.
- Operation summary.
- Execution transcript.
- Permission, auth, or user-confirmation gaps.

Paste those outputs into `evidence/feishu-claw-transcript.txt` and `evidence/operation-summary.txt`.
""",
        force=True,
    )
    write_new_text(
        task_brief_path,
        f"""# Task Brief

{args.task}

Completion labels allowed for this kit:

- `pack_ready`
- `partial`
- `blocked`
- `scoped`

This kit must keep `true_triparty_ready=false`.
""",
        force=True,
    )

    state = build_claw_state(
        out_dir,
        args.task,
        pack,
        {
            "claude_code_prompt": str(claude_prompt_path),
            "feishu_claw_prompt": str(claw_prompt_path),
            "claw_action_request": str(action_request_path),
            "task_brief": str(task_brief_path),
            "start_here": str(start_here_path),
            "evidence_dir": str(evidence_dir),
            "evidence_bundle": str(evidence_files["bundle"]),
            "kit_manifest": str(kit_manifest_path),
        },
    )
    write_state(out_dir, state)

    commands = {
        "fill_bundle": f"scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle {shell_quote(evidence_files['bundle'])} --feishu-link '<feishu-link>'",
        "import_bundle": f"scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle {shell_quote(evidence_files['bundle'])}",
        "validate_run": f"scripts/agentparty.sh validate-run --run-dir {shell_quote(out_dir)}",
        "guide": f"scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir {shell_quote(out_dir)}",
    }
    write_new_text(
        start_here_path,
        f"""# Start Here: Claude Code + Feishu Claw

Task: {args.task}

Use this file as the first page of the kit. It keeps Claude Code, Feishu Claw, and the evidence import step aligned.

## Environment Check

- macOS, Linux, and Windows WSL2 can run the import and validation commands below.
- Native Windows PowerShell can generate this kit and run `evidence-fill` as preparation, but `evidence`, `run`, `doctor --deep`, and `install --execute` remain roadmap there.
- If you generated the kit in native PowerShell, move into WSL2/macOS/Linux before step 4 and use a path visible from that environment.

## 1. Start in Claude Code

Copy `claude-code-prompt.txt` into Claude Code. Claude Code should produce:

- A short plan for the task.
- The exact Feishu action request for Claw.
- Evidence requirements and blockers to watch.

## 2. Hand Off to Feishu Claw

Copy `feishu-claw-prompt.txt` or `claw-action-request.md` into Feishu Claw.
Claw must return a Feishu link, operation summary, execution transcript, and any permission/auth/user-confirmation gaps.

## 3. Fill Evidence

Edit these files:

- `evidence/agentparty-claw-evidence.json`: set `feishu_link`.
- `evidence/feishu-claw-transcript.txt`: paste the Claw transcript.
- `evidence/operation-summary.txt`: summarize what changed in Feishu.
- `evidence/claude-code-review.txt`: paste Claude Code's review of the Claw result.

To avoid editing JSON by hand, run this after the text files are filled:

```bash
{commands["fill_bundle"]}
```

## 4. Import and Validate

```bash
{commands["import_bundle"]}
{commands["validate_run"]}
```

For state-aware next steps:

```bash
{commands["guide"]}
```

## Boundaries

- This kit is local scaffold only; it does not call Feishu or configure Claw auth.
- Native PowerShell can generate the kit and fill the local bundle, but evidence import still runs only in WSL2/macOS/Linux.
- Final labels are `pack_ready`, `partial`, `blocked`, or `scoped`.
- This is a 2-agent AgentParty pack; keep `true_triparty_ready=false`.
""",
        force=True,
    )
    manifest = {
        "schema_version": "agentparty.claw-kit.v1",
        "created_at": utc_now(),
        "pack_id": args.pack,
        "task": args.task,
        "kit_dir": str(out_dir),
        "target_os": plan["target_os"],
        "run_dir": str(out_dir),
        "state": str(out_dir / "state.json"),
        "files": {
            "claude_code_prompt": str(claude_prompt_path),
            "feishu_claw_prompt": str(claw_prompt_path),
            "claw_action_request": str(action_request_path),
            "task_brief": str(task_brief_path),
            "start_here": str(start_here_path),
            "evidence_bundle": str(evidence_files["bundle"]),
            "readme": str(readme_path),
        },
        "commands": commands,
        "boundaries": {
            **claw_boundaries(),
            "kit_generation": "local_scaffold_no_external_side_effects",
            "native_powershell_kit_generation": "supported_local_scaffold",
            "evidence_import_execution": "macOS/Linux/Windows WSL2 only",
        },
    }
    write_new_json(kit_manifest_path, manifest, force=True)
    write_new_text(
        readme_path,
        f"""# AgentParty Claw Kit

Pack: `claude-code-feishu-claw`

Task: {args.task}

## Files

- `START_HERE.md`: first page for the kit; copy order, evidence checklist, import commands, and boundaries.
- `claude-code-prompt.txt`: copy into Claude Code.
- `feishu-claw-prompt.txt`: copy into Feishu Claw.
- `claw-action-request.md`: short Feishu-side action request.
- `evidence/`: fill-in evidence bundle for Claw transcript, operation summary, and Claude Code review.
- `state.json`: initial `partial` pack state.

## Flow

1. Claude Code uses `claude-code-prompt.txt` to plan and review.
2. Feishu Claw uses `feishu-claw-prompt.txt` or `claw-action-request.md` to operate in Feishu.
3. Fill the three evidence text files, then set the link with `evidence-fill` or by editing `evidence/{CLAW_EVIDENCE_BUNDLE_FILE}`.
4. Import and validate:

```bash
{commands["fill_bundle"]}
{commands["import_bundle"]}
{commands["validate_run"]}
```

    Native PowerShell can generate this kit as a local scaffold and run `evidence-fill`, but evidence import still runs only in WSL2/macOS/Linux.
    For a scoped local E2E adapter on macOS/Linux/WSL2, use `scripts/agentparty.sh claw-e2e --pack claude-code-feishu-claw --task "<task>" --out claw-e2e-run`.
    Feishu Claw native connector/auth automation remains roadmap.
    This is a 2-agent pack; do not claim `true_triparty_ready=true`.
""",
        force=True,
    )

    result = {
        "schema_version": "agentparty.claw-kit.v1",
        "kit_dir": str(out_dir),
        "manifest": str(kit_manifest_path),
        "start_here": str(start_here_path),
        "state": str(out_dir / "state.json"),
        "evidence_bundle": str(evidence_files["bundle"]),
        "completion_label": "partial",
        "true_triparty_ready": False,
        "commands": commands,
        "boundaries": manifest["boundaries"],
    }
    if args.json:
        print_json(result)
    else:
        print(f"AgentParty Claw kit created: {out_dir}")
        print(f"Manifest: {kit_manifest_path}")
        print(f"Start here: {start_here_path}")
        print(f"State: {out_dir / 'state.json'}")
        print(f"Evidence bundle: {evidence_files['bundle']}")
        print("Next: fill evidence files, set feishu_link with evidence-fill, then run:")
        print(commands["fill_bundle"])
        print(commands["import_bundle"])
        print(commands["validate_run"])
        print("Boundary: Feishu Claw native connector/auth automation remains roadmap; true_triparty_ready=false.")
        return 0


def bridge_file_entry(path: pathlib.Path, bridge_dir: pathlib.Path) -> dict[str, Any]:
    return {
        "path": path.relative_to(bridge_dir).as_posix(),
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
    }


def build_claw_bridge_state(
    bridge_dir: pathlib.Path,
    task: str,
    target_os: str,
    files: dict[str, pathlib.Path],
) -> dict[str, Any]:
    state = {
        "schema_version": CLAW_BRIDGE_STATE_SCHEMA,
        "generated_at": utc_now(),
        "pack_id": "claude-code-feishu-claw",
        "task": task,
        "bridge_dir": str(bridge_dir),
        "bridge_status": "scaffolded",
        "entrypoint": {
            "primary": "feishu_claw",
            "user_surface": "Feishu chat with Claw",
            "report_surface": "Feishu document or Claw chat reply",
            "native_feishu_claw_connector": False,
        },
        "runner": {
            "id": "claude-code",
            "type": "local_or_controlled_runner",
            "command_surface": "Claude Code CLI or Claude Code session",
            "direct_shell_from_feishu": False,
        },
        "revision": 1,
        "active_writer": None,
        "writer_policy": {
            "one_active_writer": True,
            "reviewers_read_only": True,
            "revision_required_before_write": True,
            "human_approval_required_for_destructive_actions": True,
        },
        "participants": [
            {
                "id": "feishu-claw",
                "name": "Feishu Claw",
                "role": "primary entrypoint, Feishu operation owner, user-facing reporter",
                "can_write": ["feishu_intake", "feishu_operation_report", "claw_review"],
                "must_review": ["claude_execution_report"],
            },
            {
                "id": "claude-code",
                "name": "Claude Code",
                "role": "controlled runner, implementation planner, execution reviewer",
                "can_write": ["claude_plan", "claude_execution_report", "claude_review"],
                "must_review": ["feishu_operation_report", "claw_review"],
            },
        ],
        "shared_resources": {
            "resource_manifest": str(files["resource_manifest"]),
            "skill_contract": str(files["skill_contract"]),
            "feishu_entry_message": str(files["feishu_entry_message"]),
            "claude_runner_prompt": str(files["claude_runner_prompt"]),
            "report_template": str(files["report_template"]),
        },
        "shared_state": {
            "state_file": str(bridge_dir / "state.json"),
            "revision_log": str(files["revision_log"]),
            "evidence_dir": str(bridge_dir / "evidence"),
            "source_of_truth": "file_backed_state_not_chat_memory",
        },
        "state_machine": [
            "feishu_intake",
            "bridge_acceptance",
            "claude_planning",
            "claude_execution",
            "claw_review",
            "claude_review",
            "feishu_report",
            "pack_ready_or_partial_or_blocked_or_scoped",
        ],
        "mutual_supervision": {
            "claw_reviews_claude": True,
            "claude_reviews_claw": True,
            "fallback_rule": "If either side is missing, blocked, or produces insufficient evidence, keep partial or blocked.",
        },
        "completion": {
            "allowed_labels": ["pack_ready", "partial", "blocked", "scoped"],
            "current_label": "partial",
            "pack_ready": False,
            "true_triparty_ready": False,
            "true_triparty_ready_reason": "This bridge coordinates Feishu Claw and Claude Code; it is not Codex + Claude + Gemini triparty.",
        },
        "execution_boundaries": {
            "feishu_is_entry_and_report_surface": True,
            "claude_code_directly_callable_from_feishu": False,
            "requires_controlled_bridge_runner": True,
            "native_feishu_claw_connector": "roadmap",
            "target_os": target_os,
        },
        "errors": [
            {
                "code": "E_NATIVE_CLAW_BRIDGE_NOT_CONNECTED",
                "message": "This bridge kit defines the shared state and resource contract; native Feishu Claw event callback is not connected yet.",
            }
        ],
    }
    return state


def command_bridge_kit(args: argparse.Namespace) -> int:
    if args.pack != "claude-code-feishu-claw":
        raise SystemExit("bridge-kit currently supports only --pack claude-code-feishu-claw")
    pack = require_pack(args.pack)
    out_dir = user_path(args.out)
    prepare_claw_bridge_out_dir(out_dir, args.force)
    plan = install_plan(pack, args.target_os)

    shared_resources_dir = out_dir / "shared-resources"
    shared_state_dir = out_dir / "shared-state"
    evidence_dir = out_dir / "evidence"
    shared_resources_dir.mkdir(parents=True, exist_ok=True)
    shared_state_dir.mkdir(parents=True, exist_ok=True)
    evidence_dir.mkdir(parents=True, exist_ok=True)

    start_here_path = out_dir / "START_HERE.md"
    manifest_path = out_dir / CLAW_BRIDGE_MANIFEST_FILE
    feishu_entry_path = out_dir / "feishu-entry-message.md"
    claude_runner_prompt_path = out_dir / "claude-code-runner-prompt.txt"
    report_template_path = evidence_dir / "feishu-report-template.md"
    claude_report_path = evidence_dir / "claude-execution-report.md"
    claw_review_path = evidence_dir / "claw-review.md"
    claude_review_path = evidence_dir / "claude-review.md"
    skill_contract_path = shared_resources_dir / "skill-contract.md"
    resource_manifest_path = shared_resources_dir / "resource-manifest.json"
    revision_log_path = shared_state_dir / "revision-log.md"

    write_new_text(
        feishu_entry_path,
        f"""# Feishu Claw Entry Message

请在飞书小龙虾中发起这个 AgentParty bridge 任务：

任务：{args.task}

你是总调起和汇报入口。请把任务交给 AgentParty bridge，由受控 Claude Code runner 执行；你需要监督 Claude Code 的计划和结果，并在飞书中汇报最终状态。

必须返回：
- 飞书侧用户请求原文。
- 需要 Claude Code 执行或复核的动作。
- 小龙虾自己的检查意见。
- 最终汇报内容或阻塞原因。

边界：
- 不要直接执行本机 shell。
- 不要声称已经原生调起 Claude Code；真实调起必须通过受控 bridge runner。
- 如果 Claude Code 或小龙虾任一侧缺证据，状态保持 partial 或 blocked。
""",
        force=True,
    )
    write_new_text(
        claude_runner_prompt_path,
        f"""AgentParty Claude Code Runner Prompt

Task:
{args.task}

You are the controlled Claude Code runner for a Feishu Claw initiated AgentParty bridge.

Responsibilities:
1. Read the shared state and skill contract before acting.
2. Produce a concise plan, execution result, and review notes.
3. Do not trust chat-only state; update or cite file-backed evidence.
4. Do not claim native Feishu Claw connector automation.
5. Keep true_triparty_ready=false unless a separate Codex + Claude + Gemini triparty run is explicitly started and release-gated.

Mutual supervision:
- Feishu Claw reviews your plan and result from the Feishu context.
- You review Feishu Claw's operation report and transcript.
- If either side is incomplete, label the bridge partial or blocked.
""",
        force=True,
    )
    write_new_text(
        skill_contract_path,
        f"""# AgentParty Shared Skill Contract

Pack: `claude-code-feishu-claw`

Task: {args.task}

## Purpose

This contract lets Feishu Claw and Claude Code use the same operating rules without sharing private runtime directories such as `~/.claude/skills` or `~/.codex/skills`.

## Shared Resources

- `feishu-entry-message.md`: Feishu Claw entry and reporting instruction.
- `claude-code-runner-prompt.txt`: controlled Claude Code runner prompt.
- `shared-state/revision-log.md`: append-only revision notes.
- `state.json`: bridge state and completion boundary.
- `evidence/`: reports and mutual review artifacts.

## Rules

- Feishu is the user-facing entry and report surface.
- Claude Code is a controlled runner, not a raw shell exposed to Feishu.
- One active writer at a time; reviewers are read-only until the writer releases the revision.
- Every completion claim must cite file-backed evidence.
- Allowed labels: `pack_ready`, `partial`, `blocked`, `scoped`.
- Keep `true_triparty_ready=false`.
""",
        force=True,
    )
    write_new_text(
        revision_log_path,
        f"""# Bridge Revision Log

Revision 1

- Created bridge scaffold at {utc_now()}.
- Active writer: none.
- Status: partial until a real Feishu Claw callback or user-supplied Feishu transcript and Claude Code runner report are present.
""",
        force=True,
    )
    write_new_text(
        report_template_path,
        f"""# Feishu Report Template

## 任务

{args.task}

## 总入口

Feishu Claw

## Claude Code 执行摘要

TODO_AGENTPARTY_REPLACE

## 小龙虾监督意见

TODO_AGENTPARTY_REPLACE

## 最终状态

Allowed: `pack_ready`, `partial`, `blocked`, `scoped`.

`true_triparty_ready=false`
""",
        force=True,
    )
    write_new_text(
        claude_report_path,
        "# Claude Execution Report\n\nTODO_AGENTPARTY_REPLACE\n",
        force=True,
    )
    write_new_text(
        claw_review_path,
        "# Claw Review\n\nTODO_AGENTPARTY_REPLACE\n",
        force=True,
    )
    write_new_text(
        claude_review_path,
        "# Claude Review of Claw Output\n\nTODO_AGENTPARTY_REPLACE\n",
        force=True,
    )

    resource_files = {
        "feishu_entry_message": feishu_entry_path,
        "claude_runner_prompt": claude_runner_prompt_path,
        "skill_contract": skill_contract_path,
        "revision_log": revision_log_path,
        "report_template": report_template_path,
        "claude_execution_report": claude_report_path,
        "claw_review": claw_review_path,
        "claude_review": claude_review_path,
    }
    resource_manifest = {
        "schema_version": "agentparty.resource-manifest.v1",
        "generated_at": utc_now(),
        "pack_id": args.pack,
        "bridge_dir": str(out_dir),
        "resources": {key: bridge_file_entry(path, out_dir) for key, path in resource_files.items()},
        "runtime_private_paths_shared": False,
        "state_source": "state.json",
    }
    write_new_json(resource_manifest_path, resource_manifest, force=True)

    state_files = {
        **resource_files,
        "resource_manifest": resource_manifest_path,
    }
    state = build_claw_bridge_state(out_dir, args.task, plan["target_os"], state_files)
    write_new_json(out_dir / "state.json", state, force=True)

    write_new_text(
        start_here_path,
        f"""# Start Here: Feishu Claw -> AgentParty -> Claude Code

Task: {args.task}

This bridge kit is the first scaffold for using Feishu Claw as the user-facing entry and reporting surface while Claude Code acts as a controlled runner.

## 1. Feishu Is The Entry

Copy `feishu-entry-message.md` into Feishu Claw. Claw owns intake, user-facing report, Feishu-context checks, and review of Claude Code output.

## 2. Claude Code Is The Controlled Runner

Give `claude-code-runner-prompt.txt` plus `state.json` and `shared-resources/skill-contract.md` to Claude Code. Claude Code plans, executes, and writes a runner report; it is not directly exposed as raw shell from Feishu.

## 3. Shared Resources

Use `shared-resources/resource-manifest.json` as the resource index. It shares prompts, contracts, and evidence paths, not private runtime folders like `~/.claude/skills` or `~/.codex/skills`.

## 4. Shared State

`state.json` is the source of truth. It uses revision `1`, one active writer, and read-only reviewers. Keep changes in `shared-state/revision-log.md`.

## 5. Mutual Supervision

- Claw reviews Claude Code from the Feishu context.
- Claude Code reviews Claw's operation report.
- Missing evidence, auth, permission, or bridge callback keeps the status `partial` or `blocked`.

## 6. Validate

```bash
scripts/agentparty.sh bridge-validate --bridge-dir {shell_quote(out_dir)}
```

## Boundaries

- This is not native Feishu Claw connector automation yet.
- This does not expose local shell directly to Feishu.
- This is a 2-agent bridge scaffold, not Codex + Claude + Gemini true triparty.
- Keep `true_triparty_ready=false`.
""",
        force=True,
    )

    manifest = {
        "schema_version": CLAW_BRIDGE_KIT_SCHEMA,
        "created_at": utc_now(),
        "pack_id": args.pack,
        "task": args.task,
        "bridge_dir": str(out_dir),
        "state": str(out_dir / "state.json"),
        "start_here": str(start_here_path),
        "resource_manifest": str(resource_manifest_path),
        "entry_surface": "Feishu Claw",
        "runner_surface": "Claude Code controlled runner",
        "bridge_status": "scaffolded",
        "true_triparty_ready": False,
        "native_feishu_claw_connector": False,
        "files": {
            "start_here": str(start_here_path),
            "feishu_entry_message": str(feishu_entry_path),
            "claude_runner_prompt": str(claude_runner_prompt_path),
            "skill_contract": str(skill_contract_path),
            "resource_manifest": str(resource_manifest_path),
            "state": str(out_dir / "state.json"),
            "revision_log": str(revision_log_path),
            "report_template": str(report_template_path),
        },
    }
    write_new_json(manifest_path, manifest, force=True)

    result = {
        "schema_version": CLAW_BRIDGE_KIT_SCHEMA,
        "bridge_dir": str(out_dir),
        "manifest": str(manifest_path),
        "state": str(out_dir / "state.json"),
        "start_here": str(start_here_path),
        "resource_manifest": str(resource_manifest_path),
        "bridge_status": "scaffolded",
        "completion_label": "partial",
        "true_triparty_ready": False,
        "native_feishu_claw_connector": False,
        "next_commands": {
            "validate": f"scripts/agentparty.sh bridge-validate --bridge-dir {shell_quote(out_dir)}",
        },
    }
    if args.json:
        print_json(result)
    else:
        print(f"AgentParty Claw bridge kit created: {out_dir}")
        print(f"Manifest: {manifest_path}")
        print(f"Start here: {start_here_path}")
        print(f"State: {out_dir / 'state.json'}")
        print(f"Resource manifest: {resource_manifest_path}")
        print("Next:")
        print(result["next_commands"]["validate"])
        print("Boundary: Feishu is entry/report surface; Claude Code is controlled runner; native Claw connector remains roadmap.")
    return 0


def validate_claw_bridge_state(state: dict[str, Any], bridge_dir: pathlib.Path) -> list[str]:
    errors: list[str] = []
    if state.get("schema_version") != CLAW_BRIDGE_STATE_SCHEMA:
        errors.append(f"schema_version must be {CLAW_BRIDGE_STATE_SCHEMA}")
    if state.get("pack_id") != "claude-code-feishu-claw":
        errors.append("pack_id must be claude-code-feishu-claw")
    if state.get("entrypoint", {}).get("primary") != "feishu_claw":
        errors.append("entrypoint.primary must be feishu_claw")
    if state.get("entrypoint", {}).get("native_feishu_claw_connector") is not False:
        errors.append("native Feishu Claw connector must remain false in bridge scaffold")
    if state.get("runner", {}).get("direct_shell_from_feishu") is not False:
        errors.append("runner.direct_shell_from_feishu must be false")
    if state.get("writer_policy", {}).get("one_active_writer") is not True:
        errors.append("writer_policy.one_active_writer must be true")
    if state.get("writer_policy", {}).get("reviewers_read_only") is not True:
        errors.append("writer_policy.reviewers_read_only must be true")
    if not isinstance(state.get("revision"), int) or state.get("revision", 0) < 1:
        errors.append("revision must be an integer >= 1")
    participant_ids = {participant.get("id") for participant in state.get("participants", []) if isinstance(participant, dict)}
    if {"feishu-claw", "claude-code"} - participant_ids:
        errors.append("participants must include feishu-claw and claude-code")
    completion = state.get("completion", {})
    if completion.get("true_triparty_ready") is not False:
        errors.append("completion.true_triparty_ready must be false")
    if completion.get("current_label") not in {"pack_ready", "partial", "blocked", "scoped"}:
        errors.append("completion.current_label must be pack_ready, partial, blocked, or scoped")
    supervision = state.get("mutual_supervision", {})
    if supervision.get("claw_reviews_claude") is not True or supervision.get("claude_reviews_claw") is not True:
        errors.append("mutual_supervision must require both Claw and Claude review")
    shared_resources = state.get("shared_resources", {})
    for key in ["resource_manifest", "skill_contract", "feishu_entry_message", "claude_runner_prompt", "report_template"]:
        value = shared_resources.get(key)
        if not isinstance(value, str) or not value:
            errors.append(f"shared_resources.{key} missing")
            continue
        path = user_path(value)
        if not path.is_file():
            errors.append(f"shared_resources.{key} file missing: {path}")
    state_bridge_dir = state.get("bridge_dir")
    if state_bridge_dir and user_path(str(state_bridge_dir)).resolve() != bridge_dir.resolve():
        errors.append("state.bridge_dir does not match requested bridge directory")
    return errors


def command_bridge_validate(args: argparse.Namespace) -> int:
    bridge_dir = user_path(args.bridge_dir)
    state = read_json_file(bridge_dir / "state.json", "bridge state")
    errors = validate_claw_bridge_state(state, bridge_dir)
    result = {
        "bridge_dir": str(bridge_dir),
        "valid": not errors,
        "schema_version": state.get("schema_version"),
        "pack_id": state.get("pack_id"),
        "bridge_status": state.get("bridge_status"),
        "entrypoint": state.get("entrypoint", {}).get("primary"),
        "runner": state.get("runner", {}).get("id"),
        "revision": state.get("revision"),
        "completion_label": state.get("completion", {}).get("current_label"),
        "true_triparty_ready": state.get("completion", {}).get("true_triparty_ready"),
        "native_feishu_claw_connector": state.get("entrypoint", {}).get("native_feishu_claw_connector"),
        "validation_errors": errors,
    }
    if args.json:
        print_json(result)
    else:
        print(f"Bridge: {bridge_dir}")
        print(f"Valid: {result['valid']}")
        print(f"Pack: {result['pack_id']}")
        print(f"Status: {result['bridge_status']}")
        print(f"Entrypoint: {result['entrypoint']}")
        print(f"Runner: {result['runner']}")
        print(f"Completion label: {result['completion_label']}")
        print(f"True tri-party ready: {result['true_triparty_ready']}")
        print(f"Native Feishu Claw connector: {result['native_feishu_claw_connector']}")
        if errors:
            print("Errors:")
            for error in errors:
                print(f"- {error}")
    return 0 if not errors else 1


def load_claw_evidence_bundle(value: str) -> tuple[pathlib.Path, dict[str, Any]]:
    bundle_path = user_path(value)
    bundle = read_json_file(bundle_path, "evidence bundle")
    if bundle.get("schema_version") != CLAW_EVIDENCE_BUNDLE_SCHEMA:
        raise SystemExit(
            f"evidence bundle schema_version must be {CLAW_EVIDENCE_BUNDLE_SCHEMA}: {bundle_path}"
        )
    if bundle.get("pack_id") != "claude-code-feishu-claw":
        raise SystemExit(f"evidence bundle pack_id must be claude-code-feishu-claw: {bundle_path}")
    if bundle.get("completion_boundary", {}).get("true_triparty_ready") is not False:
        raise SystemExit("evidence bundle must keep completion_boundary.true_triparty_ready=false")
    return bundle_path, bundle


def bundle_artifact_arg(bundle_path: pathlib.Path, bundle: dict[str, Any], key: str) -> str | None:
    path = bundle_artifact_path(bundle_path, bundle, key)
    return str(path) if path else None


def bundle_artifact_path(
    bundle_path: pathlib.Path,
    bundle: dict[str, Any],
    key: str,
    default_filename: str | None = None,
) -> pathlib.Path | None:
    artifacts = bundle.get("artifacts", {})
    if not isinstance(artifacts, dict):
        raise SystemExit(f"evidence bundle artifacts must be an object: {bundle_path}")
    value = artifacts.get(key)
    if placeholder_value(value):
        if not default_filename:
            return None
        value = default_filename
        artifacts[key] = default_filename
    path = pathlib.Path(str(value)).expanduser()
    if not path.is_absolute():
        path = bundle_path.parent / path
    resolved = path.resolve()
    bundle_root = bundle_path.parent.resolve()
    if not resolved.is_relative_to(bundle_root):
        raise SystemExit(f"evidence bundle artifact path must stay inside bundle directory: {path}")
    return resolved


def fill_bundle_artifact(
    bundle_path: pathlib.Path,
    bundle: dict[str, Any],
    key: str,
    src_value: str | None,
    label: str,
) -> dict[str, Any] | None:
    if src_value is None:
        return None
    src = require_real_evidence_file(src_value, label)
    dest = bundle_artifact_path(bundle_path, bundle, key, CLAW_EVIDENCE_ARTIFACT_FILES[key])
    if dest is None:
        raise SystemExit(f"evidence bundle artifact path missing for {key}: {bundle_path}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if src.resolve() != dest.resolve():
        shutil.copyfile(src, dest)
    return {
        "key": key,
        "path": str(dest),
        "source_path": str(src),
        "sha256": sha256_file(dest),
        "bytes": dest.stat().st_size,
    }


def command_evidence_fill(args: argparse.Namespace) -> int:
    require_pack(args.pack)
    if args.pack != "claude-code-feishu-claw":
        raise SystemExit("evidence-fill currently supports only --pack claude-code-feishu-claw")

    supplied_updates = [
        args.feishu_link is not None,
        args.claw_transcript is not None,
        args.operation_summary is not None,
        args.claude_review is not None,
        args.blocked_reason is not None,
    ]
    if not any(supplied_updates):
        raise SystemExit(
            "E_EVIDENCE_FILL_NOOP: provide --feishu-link, one evidence file flag, or --blocked-reason"
        )

    bundle_path, bundle = load_claw_evidence_bundle(args.bundle)
    artifacts_updated: list[dict[str, Any]] = []

    if args.feishu_link is not None:
        bundle["feishu_link"] = require_evidence_link(args.feishu_link) or ""

    if args.blocked_reason is not None:
        bundle["blocked_reason"] = str(args.blocked_reason).strip()

    for key, src_value, label in [
        ("feishu_claw_transcript", args.claw_transcript, "Feishu Claw transcript"),
        ("operation_summary", args.operation_summary, "operation summary"),
        ("claude_code_review", args.claude_review, "Claude Code review"),
    ]:
        artifact = fill_bundle_artifact(bundle_path, bundle, key, src_value, label)
        if artifact:
            artifacts_updated.append(artifact)

    updated_at = utc_now()
    bundle["updated_at"] = updated_at
    bundle["last_fill"] = {
        "updated_at": updated_at,
        "mode": "local_bundle_update_only",
        "artifacts_updated": [artifact["key"] for artifact in artifacts_updated],
        "feishu_link_set": not placeholder_value(bundle.get("feishu_link")),
        "blocked_reason_set": not placeholder_value(bundle.get("blocked_reason")),
        "does_not_import_evidence": True,
        "does_not_update_pack_state": True,
        "true_triparty_ready": False,
    }
    bundle_path.write_text(json.dumps(bundle, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    run_dir_value = bundle.get("run_dir")
    validate_run_command = None
    guide_command = None
    if not placeholder_value(run_dir_value):
        validate_run_command = f"scripts/agentparty.sh validate-run --run-dir {shell_quote(str(run_dir_value))}"
        guide_command = (
            "scripts/agentparty.sh guide --pack claude-code-feishu-claw "
            f"--run-dir {shell_quote(str(run_dir_value))}"
        )
    next_commands = {
        "import_bundle": (
            "scripts/agentparty.sh evidence --pack claude-code-feishu-claw "
            f"--bundle {shell_quote(bundle_path)}"
        ),
        "validate_run": validate_run_command,
        "guide": guide_command,
    }
    result = {
        "bundle": str(bundle_path),
        "updated": True,
        "updated_at": updated_at,
        "feishu_link_set": not placeholder_value(bundle.get("feishu_link")),
        "blocked_reason_set": not placeholder_value(bundle.get("blocked_reason")),
        "artifacts_updated": artifacts_updated,
        "true_triparty_ready": False,
        "boundary": "local bundle update only; no Feishu call, no evidence import, no pack state update",
        "next_commands": next_commands,
    }
    if args.json:
        print_json(result)
    else:
        print(f"AgentParty Claw evidence bundle updated: {bundle_path}")
        if artifacts_updated:
            print("Artifacts updated:")
            for artifact in artifacts_updated:
                print(f"- {artifact['key']}: {artifact['path']}")
        print(f"Feishu link set: {str(result['feishu_link_set']).lower()}")
        print(f"Blocked reason set: {str(result['blocked_reason_set']).lower()}")
        print("Boundary: local bundle update only; no Feishu call, no evidence import, no pack state update.")
        print("Next: import inside WSL2/macOS/Linux when evidence is complete:")
        print(next_commands["import_bundle"])
        if validate_run_command:
            print(validate_run_command)
    return 0


def validate_pack_state(state: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    required = [
        "schema_version",
        "generated_at",
        "pack_id",
        "pack_status",
        "pack_ready",
        "true_triparty_ready",
        "completion_label",
        "errors",
        "agents",
        "artifacts",
    ]
    for key in required:
        if key not in state:
            errors.append(f"missing required state field: {key}")
    if state.get("schema_version") != "agentparty.pack-state.v1":
        errors.append("schema_version must be agentparty.pack-state.v1")
    if state.get("pack_id") != "claude-code-feishu-claw":
        errors.append("validate-run currently supports claude-code-feishu-claw pack states")
    if state.get("true_triparty_ready") is not False:
        errors.append("AgentParty pack state must never set true_triparty_ready=true")
    if state.get("pack_ready") is True and state.get("completion_label") != "pack_ready":
        errors.append("pack_ready=true requires completion_label=pack_ready")
    if state.get("completion_label") == "pack_ready" and state.get("pack_ready") is not True:
        errors.append("completion_label=pack_ready requires pack_ready=true")
    if state.get("pack_status") == "ready" and state.get("pack_ready") is not True:
        errors.append("pack_status=ready requires pack_ready=true")
    if state.get("completion_label") not in {"pack_ready", "partial", "blocked", "scoped"}:
        errors.append("completion_label must be pack_ready, partial, blocked, or scoped")
    if not isinstance(state.get("agents"), list) or len(state.get("agents", [])) < 2:
        errors.append("agents must include at least two entries")
    if not isinstance(state.get("errors"), list):
        errors.append("errors must be a list")
    return errors


def command_validate_run(args: argparse.Namespace) -> int:
    run_dir = user_path(args.run_dir)
    state = read_state(run_dir)
    errors = validate_pack_state(state)
    result = {
        "run_dir": str(run_dir),
        "valid": not errors,
        "pack_id": state.get("pack_id"),
        "pack_status": state.get("pack_status"),
        "pack_ready": state.get("pack_ready"),
        "completion_label": state.get("completion_label"),
        "true_triparty_ready": state.get("true_triparty_ready"),
        "validation_errors": errors,
        "state_errors": state.get("errors", []),
    }
    if args.json:
        print_json(result)
    else:
        print(f"Run: {run_dir}")
        print(f"Valid: {result['valid']}")
        print(f"Pack: {result['pack_id']}")
        print(f"Status: {result['completion_label']}")
        print(f"Pack ready: {result['pack_ready']}")
        print(f"True tri-party ready: {result['true_triparty_ready']}")
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        for error in state.get("errors", []):
            print(f"State error: {error.get('code')}: {error.get('message')}")
    return 0 if not errors else 1


def shell_quote(value: str | pathlib.Path) -> str:
    return "'" + str(value).replace("'", "'\"'\"'") + "'"


def command_entry(label: str, command: str, purpose: str) -> dict[str, str]:
    return {
        "label": label,
        "command": command,
        "purpose": purpose,
    }


def clone_commands_for_target(target_os: str) -> list[str]:
    if target_os == "windows_powershell":
        return [
            "winget install Git.Git",
            "winget install Python.Python.3.12",
            "git clone https://github.com/r-design-j/tri-party-framework.git",
            "cd tri-party-framework",
        ]
    return [
        "git clone https://github.com/r-design-j/tri-party-framework.git",
        "cd tri-party-framework",
        "chmod +x scripts/*.sh adapters/http/triparty_http_adapter.py adapters/mcp/triparty_mcp_adapter.py",
    ]


def quickstart_prompt(pack_id: str, target_os: str, task: str) -> str:
    if pack_id == "triparty":
        return f"""请在这台机器上安装并验证 AgentParty 的 triparty 产品包。
目标仓库：https://github.com/r-design-j/tri-party-framework
任务：{task}
系统边界：
- macOS / Linux / Windows WSL2 可以执行当前 bash/Python 路径。
- Windows 原生 PowerShell/CMD/Git Bash/MSYS/Cygwin 只做环境准备、quickstart、onboard、doctor、install dry-run、install-plan、prompt、guide、validate-run；不要执行 install --execute、run、doctor --deep 或 evidence，请先进入 WSL2。
执行要求：
1. 判断系统环境；如果是原生 Windows，先运行 `wsl --install -d Ubuntu`，进入 WSL2 后继续。
2. clone 仓库并进入目录。
3. 运行 `scripts/agentparty.sh quickstart --pack triparty --target-os auto` 复核安装路径。
4. 运行 `scripts/agentparty.sh release-check --full` 或至少 `scripts/triparty-lint.sh` 做本地自检。
5. 运行 `scripts/agentparty.sh install --pack triparty --target-os auto` dry-run，再运行 `scripts/agentparty.sh install --pack triparty --target-os auto --execute`。
6. 运行 `triparty preflight`。
7. 如缺 Claude Code、Gemini CLI、Gemini auth、权限或 release evidence，明确报告 partial/blocked；不要把探针成功说成 true tri-party。
完成后回报：安装路径、OS、preflight 结果、缺失项、下一步。"""

    if pack_id == "claude-code-feishu-claw":
        return f"""请按 AgentParty 的 Claude Code + Feishu Claw 产品包启动这个工作流。
目标仓库：https://github.com/r-design-j/tri-party-framework
任务：{task}
系统边界：
- macOS / Linux / Windows WSL2 可以创建 run、导入 evidence、validate-run。
	- Windows 原生 PowerShell 只做准备、本地填包和只读引导；run/evidence import/claw-e2e/install --execute/doctor --deep 仍是 roadmap，请进入 WSL2 后执行。
执行要求：
1. clone 仓库并进入目录。
2. 运行 `scripts/agentparty.sh quickstart --pack claude-code-feishu-claw --target-os auto` 查看路径。
3. 运行 `scripts/agentparty.sh kit --pack claude-code-feishu-claw --task "{task}" --out claw-kit` 生成可交接 kit，或运行 `scripts/agentparty.sh run --pack claude-code-feishu-claw --task "{task}"` 创建 run。
4. 运行 `scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir "<run-dir-or-kit-dir>"` 查看下一步。
5. 填写 kit/evidence bundle，交给 Feishu Claw 填入飞书链接、Claw transcript、操作摘要；可用 `evidence-fill` 设置链接和复制本地证据文件，避免手改 JSON。
6. Claude Code 复核 Claw transcript 后，用 `evidence` 把 bundle import，再 validate-run。
7. 最终只能输出 pack_ready、partial、blocked 或 scoped；必须保持 true_triparty_ready=false。Feishu connector/auth 自动化仍是 roadmap。"""

    return f"请安装 AgentParty pack {pack_id} 并运行任务：{task}"


def quickstart_for_pack(pack_id: str, target_os: str, task: str) -> dict[str, Any]:
    pack = require_pack(pack_id)
    plan = install_plan(pack, target_os)
    target = plan["target_os"]
    commands: list[dict[str, str]] = [
        command_entry("Clone repository", " && ".join(clone_commands_for_target(target)), "Get the framework source on this machine."),
    ]
    if plan["run_supported"]:
        commands.extend([
            command_entry(
                "Run quickstart",
                f"scripts/agentparty.sh quickstart --pack {pack_id} --target-os auto",
                "Print this pack-specific install and use path from inside the repository.",
            ),
            command_entry(
                "Install dry-run",
                f"scripts/agentparty.sh install --pack {pack_id} --target-os auto",
                "Preview managed bootstrap changes.",
            ),
            command_entry(
                "Install execute",
                f"scripts/agentparty.sh install --pack {pack_id} --target-os auto --execute",
                "Install managed bootstrap artifacts on supported hosts.",
            ),
        ])
        if pack_id == "triparty":
            commands.extend([
                command_entry("Preflight", "triparty preflight", "Check Claude/Gemini availability and auth."),
                command_entry("Run triparty", "triparty run '<task>'", "Start a true Codex + Claude + Gemini workflow."),
            ])
        elif pack_id == "claude-code-feishu-claw":
            commands.extend([
                command_entry(
                    "Create Claw kit",
                    "scripts/agentparty.sh kit --pack claude-code-feishu-claw --task '<task>' --out claw-kit",
                    "Create a reusable prompt, state, and evidence kit for Claude Code + Feishu Claw.",
                ),
                command_entry(
                    "Create bridge kit",
                    "scripts/agentparty.sh bridge-kit --pack claude-code-feishu-claw --task '<task>' --out claw-bridge",
                    "Create the Feishu-entry and Claude Code runner bridge scaffold with shared resources and state.",
                ),
                command_entry(
                    "Create Claw run",
                    "scripts/agentparty.sh run --pack claude-code-feishu-claw --task '<task>'",
                    "Create Claude Code and Feishu Claw prompts plus partial state.",
                ),
                command_entry(
                    "Open guide",
                    "scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir '<run-dir>'",
                    "Print state-aware next steps.",
                ),
                command_entry(
                    "Run scoped E2E adapter",
                    "scripts/agentparty.sh claw-e2e --pack claude-code-feishu-claw --task '<task>' --out claw-e2e-run",
                    "Automate Claude Code planning/review, Feishu CLI document creation, evidence import, and validation. This is not a native Claw connector.",
                ),
            ])
    else:
        commands.extend([
            command_entry(
                "Prepare in PowerShell",
                f".\\scripts\\agentparty.ps1 quickstart --pack {pack_id} --target-os windows_powershell",
                "Use native PowerShell only for preparation and local guidance.",
            ),
            command_entry("Install WSL2", "wsl --install -d Ubuntu", "Move into the supported Windows executable path."),
            command_entry(
                "Continue inside WSL2",
                f"scripts/agentparty.sh quickstart --pack {pack_id} --target-os auto",
                "Re-run quickstart inside Ubuntu/WSL2 before executing install or run commands.",
            ),
        ])
    return {
        "schema_version": "agentparty.quickstart.v1",
        "pack_id": pack_id,
        "display_name": pack["display_name"],
        "target_os": target,
        "detected_os": detected_os_key(),
        "run_supported": plan["run_supported"],
        "install_supported": plan["executable_status"] == "supported",
        "ready_label": pack["completion_semantics"]["ready_label"],
        "commands": commands,
        "copy_to_agent_prompt": quickstart_prompt(pack_id, target, task),
        "blocked_commands": plan["blocked_commands"],
        "native_powershell_commands": plan["native_powershell_commands"],
        "boundaries": {
            "recommended_path": plan["recommended_path"],
            "true_triparty_ready_allowed": pack_id == "triparty",
            "feishu_connector_automation": "roadmap" if pack_id == "claude-code-feishu-claw" else "not_applicable",
            "feishu_cli_e2e_adapter": "supported" if pack_id == "claude-code-feishu-claw" else "not_applicable",
            "native_powershell_execution": "roadmap for install execute, run, doctor --deep, evidence import, and claw-e2e",
        },
    }


def print_quickstart(data: dict[str, Any]) -> None:
    print(f"AgentParty quickstart: {data['display_name']} ({data['pack_id']})")
    print(f"Target OS: {data['target_os']}")
    print(f"Run supported: {str(data['run_supported']).lower()}")
    print(f"Ready label: {data['ready_label']}")
    print("Commands:")
    for item in data["commands"]:
        print(f"- {item['command']}")
    if data.get("blocked_commands"):
        print("Blocked commands:")
        for command in data["blocked_commands"]:
            print(f"- {command}")
    print("Boundaries:")
    for key, value in data["boundaries"].items():
        print(f"- {key}: {value}")
    print("Copy to agent:")
    print(data["copy_to_agent_prompt"])


def command_quickstart(args: argparse.Namespace) -> int:
    data = quickstart_for_pack(args.pack, args.target_os, args.task)
    if args.json:
        print_json(data)
    else:
        print_quickstart(data)
    return 0


def triparty_onboard(target_os: str, task: str) -> dict[str, Any]:
    pack = require_pack("triparty")
    plan = install_plan(pack, target_os)
    supported = bool(plan["run_supported"])
    if supported:
        stage = "ready_for_managed_install_or_run"
        next_label = "copy_agent_prompt_or_run_install"
        steps = [
            command_entry("One-copy prompt", "scripts/agentparty.sh onboard --pack triparty --target-os auto", "Show the productized install and first-run path."),
            command_entry("Install dry-run", "scripts/agentparty.sh install --pack triparty --target-os auto", "Preview managed bootstrap writes."),
            command_entry("Install execute", "scripts/agentparty.sh install --pack triparty --target-os auto --execute", "Install managed discovery, wrappers, and slash surfaces."),
            command_entry("Preflight", "triparty preflight", "Verify Claude, Gemini, auth, and local tool availability."),
            command_entry("First run", "triparty run '<task>'", "Start Codex + Claude + Gemini review for a real task."),
            command_entry("Release gate", "triparty release-gate '<run-dir>'", "Validate state, source labels, hashes, cross-audit, and true_triparty_ready."),
        ]
    else:
        stage = "windows_wsl2_handoff_required"
        next_label = "enter_wsl2_before_execution"
        steps = [
            command_entry("PowerShell preparation", ".\\scripts\\agentparty.ps1 onboard --pack triparty --target-os windows_powershell", "Show preparation-only guidance in native Windows."),
            command_entry("Install WSL2", "wsl --install -d Ubuntu", "Move into the current executable Windows path."),
            command_entry("Continue inside WSL2", "scripts/agentparty.sh onboard --pack triparty --target-os auto", "Re-run onboarding before install or run commands."),
        ]
    checks = [
        {
            "id": "repo_source",
            "label": "Repository source present",
            "status": "passed" if ROOT.is_dir() and TRIPARTY.exists() else "blocked",
            "evidence": str(ROOT),
        },
        {
            "id": "pack_registry",
            "label": "AgentParty pack registry contains triparty",
            "status": "passed" if pack["id"] == "triparty" else "blocked",
            "evidence": str(REGISTRY),
        },
        {
            "id": "host_path",
            "label": "Host execution path",
            "status": "passed" if supported else "blocked",
            "evidence": plan["recommended_path"],
        },
        {
            "id": "completion_boundary",
            "label": "Completion boundary",
            "status": "guarded",
            "evidence": "true_triparty_ready only after review, cross-audit, merge, and release gate",
        },
    ]
    return {
        "schema_version": "agentparty.onboard.v1",
        "pack_id": "triparty",
        "display_name": pack["display_name"],
        "target_os": plan["target_os"],
        "detected_os": detected_os_key(),
        "stage": stage,
        "next_label": next_label,
        "task": task,
        "checks": checks,
        "steps": steps,
        "copy_to_agent_prompt": quickstart_prompt("triparty", plan["target_os"], task),
        "boundaries": {
            "run_supported": supported,
            "install_supported": plan["executable_status"] == "supported",
            "native_powershell_execution": "roadmap; use WSL2 for current Windows execution",
            "probe_success_is_not_completion": True,
            "true_triparty_ready_allowed": True,
            "required_completion_gates": [
                "preflight",
                "claude_review",
                "gemini_review",
                "claude_cross_audit",
                "gemini_cross_audit",
                "merge_gate",
                "release_gate",
            ],
        },
    }


def print_onboard(data: dict[str, Any]) -> None:
    print(f"AgentParty onboard: {data['display_name']} ({data['pack_id']})")
    print(f"Target OS: {data['target_os']}")
    print(f"Stage: {data['stage']}")
    print(f"Next: {data['next_label']}")
    print("Checks:")
    for check in data["checks"]:
        print(f"- {check['status']}: {check['label']} ({check['evidence']})")
    print("Steps:")
    for step in data["steps"]:
        print(f"- {step['command']}")
    print("Boundaries:")
    for key, value in data["boundaries"].items():
        print(f"- {key}: {value}")
    print("Copy to agent:")
    print(data["copy_to_agent_prompt"])


def command_onboard(args: argparse.Namespace) -> int:
    if args.pack != "triparty":
        raise SystemExit("onboard currently supports the triparty product pack only")
    data = triparty_onboard(args.target_os, args.task)
    if args.json:
        print_json(data)
    else:
        print_onboard(data)
    return 0


def claw_required_evidence() -> list[str]:
    return [
        "feishu_link",
        "feishu_claw_transcript",
        "operation_summary",
        "claude_code_review",
    ]


def claw_boundaries() -> dict[str, Any]:
    return {
        "allowed_completion_labels": ["pack_ready", "partial", "blocked", "scoped"],
        "true_triparty_ready": False,
        "true_triparty_ready_reason": "This is a 2-agent AgentParty product pack, not Codex + Claude + Gemini triparty.",
        "feishu_connector_automation": "roadmap",
        "feishu_cli_e2e_adapter": "supported",
        "native_powershell_execution": "roadmap for install execute, run, doctor --deep, evidence import, and claw-e2e",
    }


def claw_general_guide(target_os: str) -> dict[str, Any]:
    plan = install_plan(require_pack("claude-code-feishu-claw"), target_os)
    run_placeholder = "<run-dir>"
    bundle_placeholder = "claw-evidence"
    if not plan["run_supported"]:
        commands = [
            command_entry(
                "Show Windows plan",
                "scripts/agentparty.sh install-plan --pack claude-code-feishu-claw --target-os windows_powershell",
                "Print native PowerShell preparation commands and blocked executable commands.",
            ),
            command_entry(
                "Prepare prompt",
                ".\\scripts\\agentparty.ps1 prompt --pack claude-code-feishu-claw --task '<task>'",
                "Generate copy-to-agent text from native PowerShell without claiming run execution.",
            ),
            command_entry(
                "Install WSL2",
                "wsl --install -d Ubuntu",
                "Move into the currently supported Windows executable path before running the pack.",
            ),
        ]
        next_label = "prepare_then_use_wsl2"
    else:
        commands = [
            command_entry(
                "Create Claw kit",
                "scripts/agentparty.sh kit --pack claude-code-feishu-claw --task '<task>' --out claw-kit",
                "Create a reusable prompt, state, and evidence kit for Claude Code + Feishu Claw.",
            ),
            command_entry(
                "Open guide",
                f"scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir '{run_placeholder}'",
                "Read the run state and print the next evidence step.",
            ),
            command_entry(
                "Create evidence bundle",
                f"scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir '{run_placeholder}' --out {bundle_placeholder}",
                "Create fill-in files for Feishu Claw transcript, operation summary, and Claude review.",
            ),
            command_entry(
                "Fill evidence bundle",
                f"scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle {bundle_placeholder}/{CLAW_EVIDENCE_BUNDLE_FILE} --feishu-link '<feishu-link>'",
                "Set the Feishu link or copy local evidence files into the bundle without importing run state.",
            ),
        ]
        next_label = "create_pack_run"
    return {
        "schema_version": "agentparty.guide.v1",
        "pack_id": "claude-code-feishu-claw",
        "target_os": plan["target_os"],
        "mode": "general",
        "next_label": next_label,
        "status": "not_started",
        "commands": commands,
        "required_evidence": claw_required_evidence(),
        "boundaries": claw_boundaries(),
    }


def claw_run_guide(run_dir: pathlib.Path, target_os: str) -> dict[str, Any]:
    plan = install_plan(require_pack("claude-code-feishu-claw"), target_os)
    native_powershell = plan["target_os"] == "windows_powershell"
    agentparty_cmd = ".\\scripts\\agentparty.ps1" if native_powershell else "scripts/agentparty.sh"
    state = require_claw_state(run_dir)
    validation_errors = validate_pack_state(state)
    label = state.get("completion_label", "partial")
    evidence_dir = pathlib.Path(str(state.get("artifacts", {}).get("evidence_dir", run_dir / "evidence")))
    bundle_dir = run_dir / "claw-evidence"
    bundle_path = bundle_dir / CLAW_EVIDENCE_BUNDLE_FILE
    commands: list[dict[str, str]] = []
    copy_targets: list[dict[str, str]] = []

    artifacts = state.get("artifacts", {})
    for key, purpose in [
        ("claude_code_prompt", "Copy into Claude Code for the planning/review side."),
        ("feishu_claw_prompt", "Copy into Feishu Claw for the Feishu execution side."),
    ]:
        value = artifacts.get(key)
        if value:
            copy_targets.append({"path": str(value), "purpose": purpose})

    if validation_errors:
        next_label = "repair_state"
        commands.append(command_entry(
            "Validate state",
            f"{agentparty_cmd} validate-run --run-dir {shell_quote(run_dir)}",
            "Show schema and completion-semantics errors before continuing.",
        ))
    elif label == "pack_ready":
        next_label = "pack_ready_validate"
        commands.extend([
            command_entry(
                "Validate final pack state",
                f"{agentparty_cmd} validate-run --run-dir {shell_quote(run_dir)}",
                "Confirm pack_ready=true and true_triparty_ready=false.",
            ),
            command_entry(
                "Inspect evidence",
                f"ls -la {shell_quote(evidence_dir)}",
                "Review copied transcript, summary, Claude review, and bundle metadata.",
            ),
        ])
    elif label == "blocked":
        next_label = "resolve_blocker"
        commands.extend([
            command_entry(
                "Review blocker",
                f"{agentparty_cmd} validate-run --run-dir {shell_quote(run_dir)}",
                "Read the blocked reason and confirm it remains accurate.",
            ),
            command_entry(
                "Create fresh evidence bundle after unblock",
                f"{agentparty_cmd} evidence-template --pack claude-code-feishu-claw --run-dir {shell_quote(run_dir)} --out {shell_quote(bundle_dir)}",
                "Restart evidence collection after permissions, auth, or user confirmation are resolved.",
            ),
        ])
    elif label == "scoped":
        next_label = "review_scope"
        commands.append(command_entry(
            "Validate scoped result",
            f"{agentparty_cmd} validate-run --run-dir {shell_quote(run_dir)}",
            "Confirm scoped completion remains a pack-level result and not true triparty.",
        ))
    else:
        next_label = "collect_claw_evidence"
        commands.extend([
            command_entry(
                "Create evidence bundle",
                f"{agentparty_cmd} evidence-template --pack claude-code-feishu-claw --run-dir {shell_quote(run_dir)} --out {shell_quote(bundle_dir)}",
                "Create fill-in files for Feishu Claw transcript, operation summary, and Claude review.",
            ),
            command_entry(
                "Fill evidence bundle",
                f"{agentparty_cmd} evidence-fill --pack claude-code-feishu-claw --bundle {shell_quote(bundle_path)} --feishu-link '<feishu-link>'",
                "Set the Feishu link or copy local evidence files into the bundle without importing run state.",
            ),
            command_entry(
                "Import filled bundle" if not native_powershell else "Import filled bundle inside WSL2",
                f"scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle {shell_quote(bundle_path)}",
                "Import evidence after all TODO markers are replaced and feishu_link is set." if not native_powershell else "Run this only inside WSL2/macOS/Linux; native PowerShell evidence import is roadmap.",
            ),
            command_entry(
                "Validate pack state",
                f"{agentparty_cmd} validate-run --run-dir {shell_quote(run_dir)}",
                "Confirm partial, blocked, scoped, or pack_ready without true_triparty_ready.",
            ),
        ])

    return {
        "schema_version": "agentparty.guide.v1",
        "pack_id": "claude-code-feishu-claw",
        "mode": "run",
        "target_os": plan["target_os"],
        "run_dir": str(run_dir),
        "state": str(run_dir / "state.json"),
        "status": label,
        "next_label": next_label,
        "pack_ready": state.get("pack_ready"),
        "true_triparty_ready": state.get("true_triparty_ready"),
        "copy_targets": copy_targets,
        "commands": commands,
        "required_evidence": claw_required_evidence(),
        "state_errors": state.get("errors", []),
        "validation_errors": validation_errors,
        "boundaries": claw_boundaries(),
    }


def triparty_guide(target_os: str, run_dir_value: str | None) -> dict[str, Any]:
    pack = require_pack("triparty")
    plan = install_plan(pack, target_os)
    if plan["run_supported"]:
        commands = [
            command_entry("Install plan", "scripts/agentparty.sh install-plan --pack triparty --target-os auto", "Print OS-specific install commands and blockers."),
            command_entry("Install dry-run", "scripts/agentparty.sh install --pack triparty --target-os auto", "Preview managed bootstrap writes."),
            command_entry("Install execute", "scripts/agentparty.sh install --pack triparty --target-os auto --execute", "Install managed discovery and CLI wrappers on supported hosts."),
            command_entry("Preflight", "triparty preflight", "Check Codex, Claude, Gemini, and Gemini auth readiness."),
            command_entry("Run", "triparty run '<task>'", "Start a true triparty run."),
        ]
    else:
        commands = [
            command_entry(
                "Show Windows plan",
                "scripts/agentparty.sh install-plan --pack triparty --target-os windows_powershell",
                "Print native PowerShell preparation commands and blocked executable commands.",
            ),
            command_entry(
                "Install WSL2",
                "wsl --install -d Ubuntu",
                "Move into the currently supported Windows executable path.",
            ),
            command_entry(
                "Run inside WSL2",
                "scripts/agentparty.sh guide --pack triparty --target-os auto",
                "After entering Ubuntu/WSL2, re-run the guide and use the Linux executable commands.",
            ),
        ]
    next_label = "install_or_run_triparty"
    if run_dir_value:
        run_dir = user_path(run_dir_value)
        next_label = "release_gate_triparty_run"
        if plan["run_supported"]:
            commands.append(command_entry(
                "Release gate",
                f"scripts/triparty.sh release-gate {shell_quote(run_dir)}",
                "Validate true_triparty_ready evidence for a completed Codex + Claude + Gemini run.",
            ))
        else:
            commands.append(command_entry(
                "Release gate inside WSL2",
                f"scripts/triparty.sh release-gate {shell_quote(run_dir)}",
                "Run this only after entering WSL2/Linux/macOS; native PowerShell execution is not shipped.",
            ))
    return {
        "schema_version": "agentparty.guide.v1",
        "pack_id": "triparty",
        "mode": "general" if not run_dir_value else "run",
        "target_os": plan["target_os"],
        "next_label": next_label,
        "commands": commands,
        "boundaries": {
            "true_triparty_ready_allowed": True,
            "native_powershell_execution": "roadmap; use Windows WSL2 for current executable workflow",
            "probe_success_is_not_completion": True,
        },
    }


def print_guide(data: dict[str, Any]) -> None:
    print(f"AgentParty guide: {data['pack_id']}")
    if data.get("run_dir"):
        print(f"Run: {data['run_dir']}")
    print(f"Status: {data.get('status', 'n/a')}")
    print(f"Next: {data['next_label']}")
    if data.get("copy_targets"):
        print("Copy targets:")
        for target in data["copy_targets"]:
            print(f"- {target['path']} ({target['purpose']})")
    if data.get("required_evidence"):
        print("Required evidence:")
        for item in data["required_evidence"]:
            print(f"- {item}")
    if data.get("state_errors"):
        print("State errors:")
        for error in data["state_errors"]:
            print(f"- {error.get('code')}: {error.get('message')}")
    if data.get("validation_errors"):
        print("Validation errors:")
        for error in data["validation_errors"]:
            print(f"- {error}")
    print("Commands:")
    for command in data.get("commands", []):
        print(f"- {command['command']}")
    boundaries = data.get("boundaries", {})
    if boundaries:
        print("Boundaries:")
        for key, value in boundaries.items():
            print(f"- {key}: {value}")


def command_guide(args: argparse.Namespace) -> int:
    require_pack(args.pack)
    if args.pack == "claude-code-feishu-claw":
        data = claw_run_guide(user_path(args.run_dir), args.target_os) if args.run_dir else claw_general_guide(args.target_os)
    elif args.pack == "triparty":
        data = triparty_guide(args.target_os, args.run_dir)
    else:
        raise SystemExit(f"Pack has no guide implementation yet: {args.pack}")
    if args.json:
        print_json(data)
    else:
        print_guide(data)
    return 1 if data.get("validation_errors") else 0


def update_agent_evidence_status(state: dict[str, Any], agent_id: str, status: str) -> None:
    for agent in state.get("agents", []):
        if agent.get("id") == agent_id:
            agent["evidence_status"] = status


def command_evidence(args: argparse.Namespace) -> int:
    if native_windows():
        block_windows_native("evidence import")
    require_pack(args.pack)
    if args.pack != "claude-code-feishu-claw":
        raise SystemExit("evidence currently supports only --pack claude-code-feishu-claw")

    bundle_path: pathlib.Path | None = None
    bundle: dict[str, Any] = {}
    if args.bundle:
        bundle_path, bundle = load_claw_evidence_bundle(args.bundle)

    run_dir_value = args.run_dir or bundle.get("run_dir")
    if placeholder_value(run_dir_value):
        raise SystemExit("--run-dir is required unless --bundle contains run_dir")
    run_dir = user_path(str(run_dir_value))
    if args.run_dir and not placeholder_value(bundle.get("run_dir")):
        bundle_run_dir = user_path(str(bundle["run_dir"]))
        if bundle_run_dir.resolve() != run_dir.resolve():
            raise SystemExit("--run-dir must match run_dir recorded in the evidence bundle")
    state = require_claw_state(run_dir)

    claw_transcript = args.claw_transcript or (
        bundle_artifact_arg(bundle_path, bundle, "feishu_claw_transcript") if bundle_path else None
    )
    operation_summary = args.operation_summary or (
        bundle_artifact_arg(bundle_path, bundle, "operation_summary") if bundle_path else None
    )
    claude_review = args.claude_review or (
        bundle_artifact_arg(bundle_path, bundle, "claude_code_review") if bundle_path else None
    )
    feishu_link = args.feishu_link or bundle.get("feishu_link")
    blocked_reason = args.blocked_reason or bundle.get("blocked_reason")
    blocked = not placeholder_value(blocked_reason)
    validated_feishu_link = None if blocked else require_evidence_link(feishu_link)

    evidence_dir = run_dir / "evidence"
    artifacts = state.setdefault("artifacts", {})
    evidence = state.setdefault("evidence", {})
    if bundle_path:
        evidence["evidence_bundle"] = {
            "path": str(bundle_path),
            "schema_version": bundle.get("schema_version"),
            "source_mode": bundle.get("source_mode", "manual_transcript"),
            "sha256": sha256_file(bundle_path),
        }

    missing: list[str] = []
    if not blocked:
        if claw_transcript:
            evidence["feishu_claw_transcript"] = copy_evidence(
                require_real_evidence_file(claw_transcript, "Feishu Claw transcript"),
                evidence_dir,
                "feishu-claw-transcript.txt",
            )
        else:
            missing.append("Feishu Claw transcript")

        if operation_summary:
            evidence["operation_summary"] = copy_evidence(
                require_real_evidence_file(operation_summary, "operation summary"),
                evidence_dir,
                "operation-summary.txt",
            )
        else:
            missing.append("operation summary")

        if claude_review:
            evidence["claude_code_review"] = copy_evidence(
                require_real_evidence_file(claude_review, "Claude Code review"),
                evidence_dir,
                "claude-code-review.txt",
            )
        else:
            missing.append("Claude Code review")

        if validated_feishu_link:
            evidence["feishu_link"] = validated_feishu_link
        else:
            missing.append("Feishu link")

    artifacts["evidence_dir"] = str(evidence_dir)
    artifacts["state"] = str(run_dir / "state.json")

    state["true_triparty_ready"] = False
    if blocked:
        state["pack_status"] = "blocked"
        state["pack_ready"] = False
        state["completion_label"] = "blocked"
        state["errors"] = [
            {
                "code": "E_CLAW_BLOCKED",
                "message": str(blocked_reason),
            }
        ]
        update_agent_evidence_status(state, "claude-code", "blocked")
        update_agent_evidence_status(state, "feishu-claw", "blocked")
    elif missing:
        state["pack_status"] = "partial"
        state["pack_ready"] = False
        state["completion_label"] = "partial"
        state["errors"] = [
            {
                "code": "E_CLAW_EVIDENCE_MISSING",
                "message": "Missing required evidence: " + ", ".join(missing),
            }
        ]
        update_agent_evidence_status(state, "claude-code", "provided" if claude_review else "missing")
        update_agent_evidence_status(
            state,
            "feishu-claw",
            "provided" if claw_transcript and operation_summary and validated_feishu_link else "missing",
        )
    else:
        state["pack_status"] = "ready"
        state["pack_ready"] = True
        state["completion_label"] = "pack_ready"
        state["errors"] = []
        update_agent_evidence_status(state, "claude-code", "provided")
        update_agent_evidence_status(state, "feishu-claw", "provided")

    state["validation"] = {
        "validated_at": utc_now(),
        "required_evidence": [
            "feishu_link",
            "feishu_claw_transcript",
            "operation_summary",
            "claude_code_review",
        ],
        "missing": missing,
        "blocked_reason": None if placeholder_value(blocked_reason) else str(blocked_reason),
        "true_triparty_ready_forbidden": True,
    }

    validation_errors = validate_pack_state(state)
    if validation_errors:
        print_json({"run_dir": str(run_dir), "updated": False, "errors": validation_errors})
        return 1

    write_state(run_dir, state)
    result = {
        "run_dir": str(run_dir),
        "state": str(run_dir / "state.json"),
        "pack_status": state["pack_status"],
        "pack_ready": state["pack_ready"],
        "completion_label": state["completion_label"],
        "true_triparty_ready": state["true_triparty_ready"],
        "errors": state["errors"],
    }
    if args.json:
        print_json(result)
    else:
        print(f"Run: {run_dir}")
        print(f"State: {run_dir / 'state.json'}")
        print(f"Status: {state['completion_label']}")
        print(f"Pack ready: {state['pack_ready']}")
        print("True tri-party ready: false")
    return 0


def command_run(args: argparse.Namespace) -> int:
    if native_windows():
        block_windows_native("run")
    require_pack(args.pack)
    if args.pack == "triparty":
        return run_triparty(args)
    if args.pack == "claude-code-feishu-claw":
        return create_claw_run(args)
    raise SystemExit(f"Pack has no run implementation yet: {args.pack}")


def command_doctor(args: argparse.Namespace) -> int:
    if native_windows() and args.deep:
        block_windows_native("deep doctor")
    registry_ok = subprocess.call([sys.executable, str(ROOT / "scripts/agentparty-pack-lint.py")], cwd=str(ROOT)) == 0
    pack = require_pack(args.pack) if args.pack else None
    data = {
        "root": str(ROOT),
        "platform": platform.platform(),
        "detected_os": detected_os_key(),
        "native_windows": native_windows(),
        "wsl": running_in_wsl(),
        "python": sys.version.split()[0],
        "registry_ok": registry_ok,
        "pack_count": len(load_registry()["packs"]),
        "triparty_cli": str(TRIPARTY) if TRIPARTY.exists() else None,
        "agentparty_runs_dir": str(RUNS_DIR),
    }
    if pack:
        data["pack"] = {
            "id": pack["id"],
            "status": pack["status"],
            "ready_label": pack["completion_semantics"]["ready_label"],
            "os_support": pack["os_support"],
        }
        data["install_plan"] = {
            key: value for key, value in install_plan(pack, "auto").items()
            if key in {"target_os", "executable_status", "run_supported", "evidence_import_supported", "recommended_path"}
        }
    if args.json:
        print_json(data)
    else:
        for key, value in data.items():
            print(f"{key}: {value}")

    if args.deep and args.pack == "triparty":
        return subprocess.call([str(TRIPARTY), "preflight"], cwd=str(ROOT))
    return 0 if registry_ok else 1


PACKAGE_ROOT_FILES = [
    "README.md",
    "CHANGELOG.md",
    "VERSION",
    "AGENTS.md",
    "CLAUDE.md",
    ".claude/commands/triparty.md",
    ".claude/commands/tp.md",
    ".claude/commands/agentparty-claw.md",
    ".claude/commands/ap-claw.md",
    ".claude/skills/triparty/SKILL.md",
]

PACKAGE_INCLUDE_DIRS: list[tuple[str, set[str]]] = [
    ("scripts", {".sh", ".py", ".ps1"}),
    ("adapters", {".py"}),
    ("docs/framework", {".md", ".json", ".yaml", ".yml", ".toml"}),
    ("examples", {".md", ".json"}),
    ("web", {".html", ".md", ".ico", ".png"}),
]

PACKAGE_EXCLUDED_PARTS = {
    "__pycache__",
    "runs",
    "agentparty-runs",
}


def package_version(value: str | None) -> str:
    if value:
        return value
    version_file = ROOT / "VERSION"
    if version_file.is_file():
        version = version_file.read_text(encoding="utf-8").strip()
        if version:
            return version
    return utc_now().replace(":", "-")


def package_relative_files() -> list[str]:
    files: set[str] = set()
    for rel in PACKAGE_ROOT_FILES:
        if (ROOT / rel).is_file():
            files.add(rel)
    for directory, suffixes in PACKAGE_INCLUDE_DIRS:
        base = ROOT / directory
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if not path.is_file():
                continue
            rel_path = path.relative_to(ROOT)
            if any(part in PACKAGE_EXCLUDED_PARTS for part in rel_path.parts):
                continue
            if path.suffix in suffixes:
                files.add(rel_path.as_posix())
    return sorted(files)


def prepare_package_out_dir(out_dir: pathlib.Path, force: bool) -> None:
    if out_dir.exists():
        if not out_dir.is_dir():
            raise SystemExit(f"package output path exists but is not a directory: {out_dir}")
        if any(out_dir.iterdir()):
            if not force:
                raise SystemExit(f"package output directory is not empty; re-run with --force: {out_dir}")
            if not (out_dir / PACKAGE_MANIFEST_FILE).is_file():
                raise SystemExit(
                    "refusing to --force a non-AgentParty package directory without "
                    f"{PACKAGE_MANIFEST_FILE}: {out_dir}"
                )
            shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)


def package_install_text(version: str, manifest_name: str) -> str:
    return f"""# AgentParty Release Bundle

- Package schema: `{PACKAGE_SCHEMA_VERSION}`
- Version: `{version}`
- Manifest: `{manifest_name}`

This bundle contains the AgentParty protocol layer plus the current product packs:

- `triparty`: Codex + Claude + Gemini; may claim `true_triparty_ready=true` only after the triparty release gate passes.
- `claude-code-feishu-claw`: Claude Code + Feishu Claw; can become `pack_ready`, `partial`, `blocked`, or `scoped`; must keep `true_triparty_ready=false`.

## Current Executable Paths

macOS, Linux, and Windows WSL2:

```bash
chmod +x scripts/*.sh adapters/http/triparty_http_adapter.py adapters/mcp/triparty_mcp_adapter.py
scripts/agentparty.sh release-check --full
scripts/agentparty.sh onboard --pack triparty --target-os auto
scripts/agentparty.sh quickstart --pack triparty --target-os auto
scripts/agentparty.sh install --pack triparty --target-os auto
scripts/agentparty.sh install --pack triparty --target-os auto --execute
triparty preflight
```

Native PowerShell/CMD/Git Bash/MSYS/Cygwin:

```powershell
.\\scripts\\agentparty.ps1 onboard --pack triparty --target-os windows_powershell
.\\scripts\\agentparty.ps1 quickstart --pack triparty --target-os windows_powershell
.\\scripts\\agentparty.ps1 install-plan --pack triparty --target-os windows_powershell
wsl --install -d Ubuntu
```

Native PowerShell is currently a preparation/local scaffold. It must not be used to claim shipped `install --execute`, `run`, `doctor --deep`, `evidence`, or `claw-e2e` execution.

Native PowerShell packaging is supported as a read-only distribution surface only. The generated manifest records that execution remains blocked and points users to WSL2 for runnable workflows.

## Safe Cleanup

macOS, Linux, and Windows WSL2:

```bash
scripts/uninstall-triparty-global-bootstrap.sh --dry-run
scripts/uninstall-triparty-global-bootstrap.sh --execute
```

Native PowerShell cleanup scaffold:

```powershell
.\\scripts\\uninstall-triparty-global-bootstrap.ps1 -DryRun
.\\scripts\\uninstall-triparty-global-bootstrap.ps1 -Execute
```

Uninstall removes only managed bootstrap artifacts and skips user-modified managed files.

## Claw Pack

**Feishu Claw auth and connector collection are not automated in this bundle.** Current evidence collection is manual transcript/link/summary/review based.

```bash
scripts/agentparty.sh quickstart --pack claude-code-feishu-claw --target-os auto
scripts/agentparty.sh kit --pack claude-code-feishu-claw --task "<task>" --out claw-kit
scripts/agentparty.sh bridge-kit --pack claude-code-feishu-claw --task "<task>" --out claw-bridge
scripts/agentparty.sh bridge-validate --bridge-dir claw-bridge
scripts/agentparty.sh run --pack claude-code-feishu-claw --task "<task>"
scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir "<run-dir>"
scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir "<run-dir>" --out claw-evidence
scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle claw-evidence/agentparty-claw-evidence.json --feishu-link "<feishu-link>"
scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle claw-evidence/agentparty-claw-evidence.json
scripts/agentparty.sh validate-run --run-dir "<run-dir>"
scripts/agentparty.sh claw-e2e --pack claude-code-feishu-claw --task "创建一个 AgentParty 测试文档" --out claw-e2e-run
```

Claude Code slash adapter after managed install:

```text
/agentparty-claw kit "<task>"
/agentparty-claw guide claw-kit
/ap-claw "<task>"
```

`claw-e2e` is a scoped local adapter that calls Claude Code and Feishu CLI, creates/fetches a Feishu doc, imports evidence, and validates the pack state. It is not a native Feishu Claw connector.

`bridge-kit` is the Feishu-entry / Claude Code runner scaffold. It creates shared resources, bridge state, revision log, and mutual-review templates without exposing local shell directly to Feishu.

Feishu Claw native connector/auth automation remains roadmap.
The `kit` command is the recommended local handoff surface for teams that want one directory containing prompts, state, and evidence templates before Claw runs. It writes local files only and does not trigger Feishu side effects.
"""


def package_pack_summaries() -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    for pack in load_registry()["packs"]:
        pack_id = pack["id"]
        summaries.append({
            "id": pack_id,
            "display_name": pack["display_name"],
            "status": pack["status"],
            "ready_label": pack["completion_semantics"]["ready_label"],
            "max_completion_label": pack["completion_semantics"]["ready_label"],
            "true_triparty_ready_allowed": pack_id == "triparty",
            "must_not_claim": pack["completion_semantics"].get("must_not_claim", []),
            "os_support": pack.get("os_support", {}),
            "docs": pack.get("docs"),
        })
    return summaries


def command_package(args: argparse.Namespace) -> int:
    out_dir = user_path(args.out)
    version = package_version(args.version)
    detected = detected_os_key()
    packaging_status = (
        "read_only_packaging_supported_execution_blocked"
        if detected == "windows_powershell"
        else "read_only_packaging_supported"
    )
    archive_path = pathlib.Path(str(out_dir) + ".tar.gz")
    if args.archive and archive_path.exists():
        if not args.force:
            raise SystemExit(f"package archive already exists; re-run with --force: {archive_path}")
        if not archive_path.is_file():
            raise SystemExit(f"package archive path exists but is not a file: {archive_path}")
        archive_path.unlink()

    prepare_package_out_dir(out_dir, args.force)

    included_files: list[dict[str, Any]] = []
    for rel in package_relative_files():
        src = ROOT / rel
        dest = out_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        included_files.append({
            "path": rel,
            "sha256": sha256_file(dest),
            "bytes": dest.stat().st_size,
        })

    install_path = out_dir / PACKAGE_INSTALL_FILE
    install_text = package_install_text(version, PACKAGE_MANIFEST_FILE)
    install_path.write_text(install_text, encoding="utf-8")
    generated_files = [
        {
            "path": PACKAGE_INSTALL_FILE,
            "sha256": sha256_file(install_path),
            "bytes": install_path.stat().st_size,
        }
    ]

    manifest = {
        "schema_version": PACKAGE_SCHEMA_VERSION,
        "generated_at": utc_now(),
        "version": version,
        "source_root": str(ROOT),
        "package_dir": str(out_dir),
        "packaging_host": {
            "detected_os": detected,
            "platform_status": packaging_status,
            "native_powershell_execution": "blocked" if detected == "windows_powershell" else "not_applicable",
        },
        "read_only_packaging": True,
        "included_file_count": len(included_files),
        "included_files": included_files,
        "generated_files": generated_files,
        "product_packs": package_pack_summaries(),
        "entrypoints": {
            "agentparty_bash": "scripts/agentparty.sh",
            "agentparty_powershell": "scripts/agentparty.ps1",
            "triparty_bash": "scripts/triparty.sh",
            "website": "web/index.html",
        },
        "boundaries": {
            "supported_execution_os": sorted(SUPPORTED_EXECUTABLE_OSES),
            "native_powershell_execution": "roadmap for install --execute, run, doctor --deep, evidence import, and claw-e2e",
            "native_powershell_preparation": [
                "packs",
                "doctor",
                "quickstart",
                "onboard",
                "install dry-run",
                "install-plan",
                "prompt",
                "guide",
                "validate-run",
                "bridge-kit",
                "bridge-validate",
                "kit",
                "evidence-template",
                "evidence-fill",
                "package",
            ],
            "blocked_native_powershell_commands": [
                "install --execute",
                "run",
                "doctor --deep",
                "evidence",
                "claw-e2e",
            ],
            "claw_true_triparty_ready": False,
            "feishu_claw_connector_automation": "roadmap",
            "probe_success_is_not_review_completion": True,
        },
        "release_gate": {
            "recommended_before_public_distribution": "scripts/agentparty.sh release-check --full",
            "triparty_run_gate": "scripts/triparty.sh release-gate <run-dir>",
        },
    }
    manifest_path = out_dir / PACKAGE_MANIFEST_FILE
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    archive_info: dict[str, Any] | None = None
    if args.archive:
        with tarfile.open(archive_path, "w:gz") as archive:
            archive.add(out_dir, arcname=out_dir.name)
        archive_info = {
            "path": str(archive_path),
            "sha256": sha256_file(archive_path),
            "bytes": archive_path.stat().st_size,
        }

    result = {
        "schema_version": PACKAGE_SCHEMA_VERSION,
        "package_dir": str(out_dir),
        "manifest": str(manifest_path),
        "install": str(install_path),
        "archive": archive_info,
        "included_file_count": len(included_files),
        "pack_ids": [pack["id"] for pack in manifest["product_packs"]],
        "boundaries": manifest["boundaries"],
    }
    if args.json:
        print_json(result)
    else:
        print(f"AgentParty package created: {out_dir}")
        print(f"Manifest: {manifest_path}")
        print(f"Install guide: {install_path}")
        if archive_info:
            print(f"Archive: {archive_info['path']}")
        print("Boundary: native PowerShell execution remains roadmap; WSL2/macOS/Linux are current executable paths.")
    return 0


class AgentPartyHTMLCheck(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: set[str] = set()
        self.hrefs: list[str] = []
        self.command_cards = 0
        self.copy_commands: list[str] = []
        self.command_card_copy_commands: list[str] = []
        self.command_card_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr = {key: value or "" for key, value in attrs}
        if "id" in attr:
            self.ids.add(attr["id"])
        if tag == "a" and attr.get("href", "").startswith("#"):
            self.hrefs.append(attr["href"][1:])
        starts_command_card = tag == "article" and "command-card" in attr.get("class", "").split()
        if starts_command_card:
            self.command_cards += 1
            self.command_card_depth = 1
        elif self.command_card_depth:
            self.command_card_depth += 1
        if tag == "button" and attr.get("data-copy"):
            self.copy_commands.append(attr["data-copy"])
            if self.command_card_depth:
                self.command_card_copy_commands.append(attr["data-copy"])

    def handle_endtag(self, tag: str) -> None:
        if self.command_card_depth:
            self.command_card_depth -= 1


def run_release_command(label: str, cmd: list[str]) -> dict[str, Any]:
    completed = subprocess.run(
        cmd,
        cwd=str(ROOT),
        text=True,
        capture_output=True,
        check=False,
    )
    return {
        "label": label,
        "status": "passed" if completed.returncode == 0 else "failed",
        "command": cmd,
        "exit_code": completed.returncode,
        "stdout_tail": completed.stdout[-4000:],
        "stderr_tail": completed.stderr[-4000:],
    }


def check_web_static() -> dict[str, Any]:
    html_path = pathlib.Path(os.environ.get("AGENTPARTY_WEB_INDEX", str(ROOT / "web/index.html"))).expanduser()
    if not html_path.is_absolute():
        html_path = ROOT / html_path
    parser = AgentPartyHTMLCheck()
    parser.feed(html_path.read_text(encoding="utf-8"))
    missing_anchors = [href for href in parser.hrefs if href not in parser.ids]
    errors: list[str] = []
    if missing_anchors:
        errors.append("missing anchors: " + ", ".join(missing_anchors))
    if parser.command_cards != EXPECTED_WEB_COMMAND_CARDS:
        errors.append(f"expected {EXPECTED_WEB_COMMAND_CARDS} command cards, found {parser.command_cards}")
    if parser.command_card_copy_commands != EXPECTED_WEB_COPY_COMMANDS:
        missing = [command for command in EXPECTED_WEB_COPY_COMMANDS if command not in parser.command_card_copy_commands]
        unexpected = [command for command in parser.command_card_copy_commands if command not in EXPECTED_WEB_COPY_COMMANDS]
        if missing:
            errors.append("missing command-card copy commands: " + " | ".join(missing))
        if unexpected:
            errors.append("unexpected command-card copy commands: " + " | ".join(unexpected))
        if not missing and not unexpected:
            errors.append("command-card copy commands are out of the expected order")
    if not any("evidence-template" in command for command in parser.copy_commands):
        errors.append("missing evidence-template copy command")
    if not any("agentparty-claw-evidence.json" in command for command in parser.copy_commands):
        errors.append("missing Claw evidence bundle copy command")
    if not any("release-check" in command for command in parser.copy_commands):
        errors.append("missing AgentParty release-check copy command")
    return {
        "label": "static web structure",
        "status": "passed" if not errors else "failed",
        "path": str(html_path),
        "ids": len(parser.ids),
        "hrefs": len(parser.hrefs),
        "command_cards": parser.command_cards,
        "copy_buttons": len(parser.copy_commands),
        "command_card_copy_buttons": len(parser.command_card_copy_commands),
        "errors": errors,
    }


def check_release_workflow_static() -> dict[str, Any]:
    workflow_path = ROOT / ".github/workflows/agentparty-release.yml"
    errors: list[str] = []
    if not workflow_path.is_file():
        return {
            "label": "AgentParty release workflow",
            "status": "failed",
            "path": str(workflow_path),
            "errors": ["missing .github/workflows/agentparty-release.yml"],
        }

    text = workflow_path.read_text(encoding="utf-8")
    required_fragments = [
        "ubuntu-latest",
        "macos-latest",
        "windows-latest",
        "concurrency:",
        "cancel-in-progress: false",
        "scripts/agentparty.sh release-check --full --json",
        "scripts/agentparty.sh package --out dist/agentparty-release-${{ matrix.os }} --archive --force --json",
        ".\\scripts\\agentparty.ps1 package --out dist\\agentparty-release-windows --archive --force --json",
        "actions/upload-artifact@v4",
        "release-gate-summary:",
        "needs.release-check.result",
        "needs.windows-boundary.result",
        "E_BLOCKED_OS",
        "wsl --install -d Ubuntu",
        "install\", \"--pack\", \"triparty\", \"--target-os\", \"windows_powershell\", \"--execute",
        "run\", \"--pack\", \"triparty\", \"--task",
        "doctor\", \"--pack\", \"triparty\", \"--deep",
        "evidence\", \"--pack\", \"claude-code-feishu-claw",
        "claw-e2e\", \"--pack\", \"claude-code-feishu-claw\", \"--task",
    ]
    for fragment in required_fragments:
        if fragment not in text:
            errors.append("missing workflow fragment: " + fragment)

    forbidden_fragments = [
        "scripts/triparty.sh run",
        "triparty run",
        ".\\scripts\\agentparty.ps1 install --pack triparty --target-os windows_powershell --execute",
    ]
    for fragment in forbidden_fragments:
        if fragment in text:
            errors.append("workflow must not execute model/run or native PowerShell install directly: " + fragment)

    return {
        "label": "AgentParty release workflow",
        "status": "passed" if not errors else "failed",
        "path": str(workflow_path),
        "errors": errors,
    }


def command_release_check(args: argparse.Namespace) -> int:
    checks: list[dict[str, Any]] = []
    checks.append(run_release_command(
        "python compile",
        [sys.executable, "-m", "py_compile", "scripts/agentparty.py", "scripts/agentparty-pack-lint.py"],
    ))
    checks.append(run_release_command("agentparty pack lint", [sys.executable, "scripts/agentparty-pack-lint.py"]))
    checks.append(run_release_command("triparty lint", ["bash", "scripts/triparty-lint.sh"]))
    checks.append(run_release_command("git diff check", ["git", "diff", "--check"]))
    checks.append(check_web_static())
    checks.append(check_release_workflow_static())
    if args.full:
        checks.append(run_release_command("triparty regression", ["bash", "scripts/triparty-regression.sh"]))
    else:
        checks.append({
            "label": "triparty regression",
            "status": "skipped",
            "reason": "pass --full to run the complete regression suite",
        })
    if args.triparty_run_dir:
        checks.append(run_release_command(
            "triparty release gate",
            ["bash", "scripts/triparty.sh", "release-gate", args.triparty_run_dir],
        ))

    failed = [check for check in checks if check["status"] == "failed"]
    result = {
        "status": "passed" if not failed else "failed",
        "full": args.full,
        "checks": checks,
        "failed": [check["label"] for check in failed],
        "notes": [
            "This is an AgentParty productization gate, not a native PowerShell execution claim.",
            "Run with --full before commit or public release packaging.",
        ],
    }
    if args.json:
        print_json(result)
    else:
        print(f"AgentParty release check: {result['status']}")
        for check in checks:
            print(f"- {check['label']}: {check['status']}")
            if check["status"] == "failed":
                for error in check.get("errors", []):
                    print(f"  error: {error}")
                if check.get("stderr_tail"):
                    print("  stderr:")
                    print(check["stderr_tail"].rstrip())
                elif check.get("stdout_tail"):
                    print("  output:")
                    print(check["stdout_tail"].rstrip())
            if check["status"] == "skipped":
                print(f"  reason: {check['reason']}")
    return 0 if not failed else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agentparty", description="AgentParty product-pack CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    packs = sub.add_parser("packs", help="List product packs")
    packs.add_argument("--json", action="store_true")
    packs.set_defaults(func=command_packs)

    info = sub.add_parser("info", help="Show product pack details")
    info.add_argument("pack", nargs="?")
    info.add_argument("--pack", dest="pack_flag", help="Product pack id; alias for the positional pack argument")
    info.add_argument("--json", action="store_true")
    info.set_defaults(func=command_info)

    quickstart = sub.add_parser("quickstart", help="Print a one-copy install/use quickstart for a product pack")
    quickstart.add_argument("--pack", required=True)
    quickstart.add_argument(
        "--target-os",
        default="auto",
        choices=["auto", "macos", "linux", "windows_wsl2", "windows_powershell"],
    )
    quickstart.add_argument("--task", default="检查并使用这个 AgentParty 产品包。")
    quickstart.add_argument("--json", action="store_true")
    quickstart.set_defaults(func=command_quickstart)

    onboard = sub.add_parser("onboard", help="Show productized onboarding status and next steps for a product pack")
    onboard.add_argument("--pack", required=True)
    onboard.add_argument(
        "--target-os",
        default="auto",
        choices=["auto", "macos", "linux", "windows_wsl2", "windows_powershell"],
    )
    onboard.add_argument("--task", default="审查这个任务并给出可验证结论。")
    onboard.add_argument("--json", action="store_true")
    onboard.set_defaults(func=command_onboard)

    prompt = sub.add_parser("prompt", help="Generate a copy-to-agent prompt")
    prompt.add_argument("--pack", required=True)
    prompt.add_argument("--task", default="检查这个 AgentParty 产品包是否可以用于当前任务。")
    prompt.set_defaults(func=command_prompt)

    kit = sub.add_parser("kit", help="Create a reusable local product-pack handoff kit")
    kit.add_argument("--pack", required=True)
    kit.add_argument("--task", required=True)
    kit.add_argument("--out", required=True, help="Output directory for the kit")
    kit.add_argument(
        "--target-os",
        default="auto",
        choices=["auto", "macos", "linux", "windows_wsl2", "windows_powershell"],
    )
    kit.add_argument("--force", action="store_true", help="Replace a previous AgentParty kit directory")
    kit.add_argument("--json", action="store_true")
    kit.set_defaults(func=command_kit)

    bridge_kit = sub.add_parser("bridge-kit", help="Create a Feishu-entry + Claude Code runner bridge scaffold")
    bridge_kit.add_argument("--pack", required=True)
    bridge_kit.add_argument("--task", required=True)
    bridge_kit.add_argument("--out", required=True, help="Output directory for the bridge kit")
    bridge_kit.add_argument(
        "--target-os",
        default="auto",
        choices=["auto", "macos", "linux", "windows_wsl2", "windows_powershell"],
    )
    bridge_kit.add_argument("--force", action="store_true", help="Replace a previous AgentParty bridge directory")
    bridge_kit.add_argument("--json", action="store_true")
    bridge_kit.set_defaults(func=command_bridge_kit)

    install_plan_parser = sub.add_parser("install-plan", help="Print OS-specific install and usage plan")
    install_plan_parser.add_argument("--pack", required=True)
    install_plan_parser.add_argument(
        "--target-os",
        default="auto",
        choices=["auto", "macos", "linux", "windows_wsl2", "windows_powershell"],
    )
    install_plan_parser.add_argument("--json", action="store_true")
    install_plan_parser.set_defaults(func=command_install_plan)

    install = sub.add_parser("install", help="Dry-run or execute managed AgentParty product-pack installation")
    install.add_argument("--pack", required=True)
    install.add_argument(
        "--target-os",
        default="auto",
        choices=["auto", "macos", "linux", "windows_wsl2", "windows_powershell"],
    )
    mode = install.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Preview managed installation without changing files")
    mode.add_argument("--execute", action="store_true", help="Install managed bootstrap artifacts")
    install.add_argument("--json", action="store_true")
    install.set_defaults(func=command_install)

    run = sub.add_parser("run", help="Run or scaffold a product pack")
    run.add_argument("--pack", required=True)
    run.add_argument("--task", required=True)
    run.add_argument("context_files", nargs="*")
    run.set_defaults(func=command_run)

    claw_e2e = sub.add_parser("claw-e2e", help="Run scoped Claude Code + Feishu CLI E2E for the Claw pack")
    claw_e2e.add_argument("--pack", required=True)
    claw_e2e.add_argument("--task", required=True)
    claw_e2e.add_argument("--out", help="Output run directory; defaults to the AgentParty runs dir")
    claw_e2e.add_argument("--title", help="Feishu doc title; defaults to a timestamped AgentParty title")
    claw_e2e.add_argument("--content", help="Markdown content to create in the Feishu doc")
    claw_e2e.add_argument("--claude-bin", default="claude")
    claw_e2e.add_argument("--feishu-bin", default="feishu")
    claw_e2e.add_argument("--max-budget-usd", default="1")
    claw_e2e.add_argument("--force", action="store_true", help="Replace a previous AgentParty Claw E2E directory")
    claw_e2e.add_argument("--json", action="store_true")
    claw_e2e.set_defaults(func=command_claw_e2e)

    evidence_template = sub.add_parser("evidence-template", help="Create a fill-in evidence bundle template")
    evidence_template.add_argument("--pack", required=True)
    evidence_template.add_argument("--run-dir", required=True)
    evidence_template.add_argument("--out", required=True)
    evidence_template.add_argument("--force", action="store_true", help="Overwrite existing template files")
    evidence_template.add_argument("--json", action="store_true")
    evidence_template.set_defaults(func=command_evidence_template)

    evidence_fill = sub.add_parser("evidence-fill", help="Fill a local Claw evidence bundle without importing it")
    evidence_fill.add_argument("--pack", required=True)
    evidence_fill.add_argument("--bundle", required=True, help="Path to agentparty-claw-evidence.json")
    evidence_fill.add_argument("--feishu-link")
    evidence_fill.add_argument("--claw-transcript")
    evidence_fill.add_argument("--operation-summary")
    evidence_fill.add_argument("--claude-review")
    evidence_fill.add_argument("--blocked-reason")
    evidence_fill.add_argument("--json", action="store_true")
    evidence_fill.set_defaults(func=command_evidence_fill)

    evidence = sub.add_parser("evidence", help="Import product-pack evidence into a run")
    evidence.add_argument("--pack", required=True)
    evidence.add_argument("--run-dir")
    evidence.add_argument("--bundle", help="Path to agentparty-claw-evidence.json")
    evidence.add_argument("--feishu-link")
    evidence.add_argument("--claw-transcript")
    evidence.add_argument("--operation-summary")
    evidence.add_argument("--claude-review")
    evidence.add_argument("--blocked-reason")
    evidence.add_argument("--json", action="store_true")
    evidence.set_defaults(func=command_evidence)

    validate_run = sub.add_parser("validate-run", help="Validate an AgentParty pack run state")
    validate_run.add_argument("--run-dir", required=True)
    validate_run.add_argument("--json", action="store_true")
    validate_run.set_defaults(func=command_validate_run)

    bridge_validate = sub.add_parser("bridge-validate", help="Validate an AgentParty Feishu/Claude bridge state")
    bridge_validate.add_argument("--bridge-dir", required=True)
    bridge_validate.add_argument("--json", action="store_true")
    bridge_validate.set_defaults(func=command_bridge_validate)

    guide = sub.add_parser("guide", help="Print next-step guidance for a product pack or pack run")
    guide.add_argument("--pack", required=True)
    guide.add_argument("--run-dir", help="Read this run state and print state-aware next steps")
    guide.add_argument(
        "--target-os",
        default="auto",
        choices=["auto", "macos", "linux", "windows_wsl2", "windows_powershell"],
    )
    guide.add_argument("--json", action="store_true")
    guide.set_defaults(func=command_guide)

    doctor = sub.add_parser("doctor", help="Check AgentParty installation and pack registry")
    doctor.add_argument("--pack")
    doctor.add_argument("--deep", action="store_true", help="Run pack-specific executable checks when available")
    doctor.add_argument("--json", action="store_true")
    doctor.set_defaults(func=command_doctor)

    release_check = sub.add_parser("release-check", help="Run AgentParty productization release checks")
    release_check.add_argument("--full", action="store_true", help="Run the complete regression suite")
    release_check.add_argument("--triparty-run-dir", help="Also run triparty release-gate for this run directory")
    release_check.add_argument("--json", action="store_true")
    release_check.set_defaults(func=command_release_check)

    package = sub.add_parser("package", help="Create a read-only AgentParty release bundle")
    package.add_argument("--out", required=True, help="Output directory for the release bundle")
    package.add_argument("--version", help="Package version; defaults to VERSION")
    package.add_argument("--archive", action="store_true", help="Also create <out>.tar.gz")
    package.add_argument("--force", action="store_true", help="Replace a previous AgentParty package directory/archive")
    package.add_argument("--json", action="store_true")
    package.set_defaults(func=command_package)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
