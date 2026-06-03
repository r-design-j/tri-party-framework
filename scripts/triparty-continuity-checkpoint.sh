#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${TRIPARTY_CONTINUITY_DIR:-"$ROOT_DIR/.agent/continuity"}"
WORKSTREAM="$(basename "$ROOT_DIR")"
GOAL="Continue the current tri-party framework workstream."
RUN_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/triparty-continuity-checkpoint.sh [--out-dir DIR] [--workstream NAME] [--goal TEXT] [--run-dir RUN_DIR]

Writes a local handoff package:
  current.yml, handoff.md, bootstrap.md, manifest.json, events.jsonl, redact-rules.yml
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --workstream)
      WORKSTREAM="$2"
      shift 2
      ;;
    --goal)
      GOAL="$2"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

stamp() {
  date -u '+%Y%m%d-%H%M%S'
}

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_escape() {
  awk '
    BEGIN { ORS = "" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "\\r")
      gsub(/\n/, "\\n")
      print
    }
  '
}

json_string() {
  printf '%s' "$1" | json_escape
}

extract_json_field() {
  local file="$1"
  local key="$2"
  if command -v jq >/dev/null 2>&1 && [ -s "$file" ]; then
    jq -r "$key // \"unknown\"" "$file" 2>/dev/null || printf 'unknown'
  else
    printf 'unknown'
  fi
}

detect_secrets() {
  grep -En 'OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|[A-Za-z_]*TOKEN=|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "$@" 2>/dev/null
}

mkdir -p "$OUT_DIR/snapshots" "$OUT_DIR/reviews" "$OUT_DIR/locks"
CHECKPOINT_STAMP="$(stamp)"
SNAPSHOT_DIR="$OUT_DIR/snapshots/$CHECKPOINT_STAMP"
mkdir -p "$SNAPSHOT_DIR"

REVISION=1
if [ -f "$OUT_DIR/current.yml" ]; then
  previous_revision="$(awk '/^revision:/ { print $2; exit }' "$OUT_DIR/current.yml")"
  case "$previous_revision" in
    ''|*[!0-9]*)
      REVISION=1
      ;;
    *)
      REVISION=$((previous_revision + 1))
      ;;
  esac
fi

TRIPARTY_PHASE="unknown"
TRIPARTY_CONCLUSION="unknown"
TRIPARTY_STATE=""
if [ -n "$RUN_DIR" ]; then
  if [ ! -d "$RUN_DIR" ]; then
    printf 'Run directory does not exist: %s\n' "$RUN_DIR" >&2
    exit 2
  fi
  if [ ! -f "$RUN_DIR/state.json" ]; then
    "$ROOT_DIR/scripts/triparty.sh" status "$RUN_DIR" >/dev/null 2>&1 || true
  fi
  TRIPARTY_STATE="$RUN_DIR/state.json"
  TRIPARTY_PHASE="$(extract_json_field "$TRIPARTY_STATE" '.phase')"
  TRIPARTY_CONCLUSION="$(extract_json_field "$TRIPARTY_STATE" '.conclusion')"
fi

GENERATED_AT="$(now_utc)"
CURRENT_FILE="$OUT_DIR/current.yml"
HANDOFF_FILE="$OUT_DIR/handoff.md"
BOOTSTRAP_FILE="$OUT_DIR/bootstrap.md"
MANIFEST_FILE="$OUT_DIR/manifest.json"
REDACT_FILE="$OUT_DIR/redact-rules.yml"
EVENTS_FILE="$OUT_DIR/events.jsonl"

cat > "$REDACT_FILE" <<'EOF'
schema: triparty-redact-rules/v1
blocked_patterns:
  - OPENAI_API_KEY
  - ANTHROPIC_API_KEY
  - GEMINI_API_KEY
  - bearer_token
  - private_key
  - long_api_key
EOF

cat > "$CURRENT_FILE" <<EOF
schema: triparty-continuity/v1
revision: $REVISION
generated_at: "$GENERATED_AT"
workstream: "$(yaml_escape "$WORKSTREAM")"
latest_user_request: "$(yaml_escape "$GOAL")"
active_goal:
  status: in_progress
  objective: "$(yaml_escape "$GOAL")"
open_tasks:
  - "Continue from this file-backed handoff, not chat history."
blocked_items: []
changed_files: []
context_to_load:
  - "$CURRENT_FILE"
  - "$HANDOFF_FILE"
  - "$BOOTSTRAP_FILE"
gates:
  redaction_status: pending
  hash_status: pending
  bootstrap_status: ready
triparty:
  run_dir: "$(yaml_escape "$RUN_DIR")"
  state_json: "$(yaml_escape "$TRIPARTY_STATE")"
  phase: "$(yaml_escape "$TRIPARTY_PHASE")"
  conclusion: "$(yaml_escape "$TRIPARTY_CONCLUSION")"
EOF

cat > "$HANDOFF_FILE" <<EOF
# Triparty Continuity Handoff

Generated: $GENERATED_AT
Revision: $REVISION
Workstream: $WORKSTREAM

## Current Goal

$GOAL

## Source Of Truth

- Use \`current.yml\` as the machine-readable entrypoint.
- Use \`manifest.json\` to verify file hashes before resuming.
- Do not treat chat history as the authoritative state.

## Triparty State

- Run directory: ${RUN_DIR:-none}
- State file: ${TRIPARTY_STATE:-none}
- Phase: $TRIPARTY_PHASE
- Conclusion: $TRIPARTY_CONCLUSION

## Resume Rule

If the manifest hash check fails, stop and ask for a fresh checkpoint.
EOF

cat > "$BOOTSTRAP_FILE" <<EOF
# New Session Bootstrap

Read these files first:

1. $CURRENT_FILE
2. $HANDOFF_FILE
3. $MANIFEST_FILE

Resume workstream: $WORKSTREAM

Goal: $GOAL

Before claiming a true tri-party result, verify the referenced triparty state and merge gate. If any review or cross-audit input is missing, label the result partial.
EOF

if detect_secrets "$CURRENT_FILE" "$HANDOFF_FILE" "$BOOTSTRAP_FILE" >/tmp/triparty-continuity-secrets.$$ 2>/dev/null; then
  printf 'Continuity checkpoint failed redaction scan:\n' >&2
  sed -n '1,40p' /tmp/triparty-continuity-secrets.$$ >&2
  rm -f /tmp/triparty-continuity-secrets.$$
  exit 1
fi
rm -f /tmp/triparty-continuity-secrets.$$

sed -i.bak 's/redaction_status: pending/redaction_status: passed/; s/hash_status: pending/hash_status: pending/' "$CURRENT_FILE"
rm -f "$CURRENT_FILE.bak"

current_sha="$(hash_file "$CURRENT_FILE")"
handoff_sha="$(hash_file "$HANDOFF_FILE")"
bootstrap_sha="$(hash_file "$BOOTSTRAP_FILE")"
redact_sha="$(hash_file "$REDACT_FILE")"

cat > "$MANIFEST_FILE" <<EOF
{
  "schema": "triparty-continuity-manifest/v1",
  "generated_at": "$(json_string "$GENERATED_AT")",
  "revision": $REVISION,
  "workstream": "$(json_string "$WORKSTREAM")",
  "files": [
    {"path": "current.yml", "sha256": "$current_sha"},
    {"path": "handoff.md", "sha256": "$handoff_sha"},
    {"path": "bootstrap.md", "sha256": "$bootstrap_sha"},
    {"path": "redact-rules.yml", "sha256": "$redact_sha"}
  ]
}
EOF

sed -i.bak 's/hash_status: pending/hash_status: passed/' "$CURRENT_FILE"
rm -f "$CURRENT_FILE.bak"
current_sha="$(hash_file "$CURRENT_FILE")"
sed -i.bak "s/\"path\": \"current.yml\", \"sha256\": \"[a-f0-9]*\"/\"path\": \"current.yml\", \"sha256\": \"$current_sha\"/" "$MANIFEST_FILE"
rm -f "$MANIFEST_FILE.bak"

printf '{"generated_at":"%s","event":"checkpoint","revision":%s,"workstream":"%s"}\n' \
  "$(json_string "$GENERATED_AT")" \
  "$REVISION" \
  "$(json_string "$WORKSTREAM")" >> "$EVENTS_FILE"

cp "$CURRENT_FILE" "$SNAPSHOT_DIR/current.yml"
cp "$HANDOFF_FILE" "$SNAPSHOT_DIR/handoff.md"
cp "$BOOTSTRAP_FILE" "$SNAPSHOT_DIR/bootstrap.md"
cp "$MANIFEST_FILE" "$SNAPSHOT_DIR/manifest.json"

printf 'Continuity checkpoint written: %s\n' "$OUT_DIR"
printf 'Bootstrap: %s\n' "$BOOTSTRAP_FILE"
