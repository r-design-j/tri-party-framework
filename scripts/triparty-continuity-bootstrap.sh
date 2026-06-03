#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${TRIPARTY_CONTINUITY_DIR:-"$ROOT_DIR/.agent/continuity"}"

usage() {
  cat <<'EOF'
Usage:
  scripts/triparty-continuity-bootstrap.sh [--out-dir DIR]

Verifies manifest hashes and prints the handoff/bootstrap text for a new session.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
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

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

manifest_entries() {
  awk -F '"' '
    /"path"[[:space:]]*:/ && /"sha256"[[:space:]]*:/ {
      print $4 "|" $8
      next
    }
    /"path"[[:space:]]*:/ {
      path = $4
      next
    }
    /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/ {
      if ($2 != "files") {
        pending = $2
      }
      next
    }
    /"sha256"[[:space:]]*:/ {
      if (path != "") {
        print path "|" $4
        path = ""
        next
      }
      if (pending != "") {
        print pending "|" $4
        pending = ""
        next
      }
    }
  ' "$MANIFEST_FILE"
}

MANIFEST_FILE="$OUT_DIR/manifest.json"
CURRENT_FILE="$OUT_DIR/current.yml"
HANDOFF_FILE="$OUT_DIR/handoff.md"
BOOTSTRAP_FILE="$OUT_DIR/bootstrap.md"

if [ ! -f "$MANIFEST_FILE" ] || [ ! -f "$CURRENT_FILE" ] || [ ! -f "$HANDOFF_FILE" ] || [ ! -f "$BOOTSTRAP_FILE" ]; then
  printf 'Continuity handoff is incomplete in %s\n' "$OUT_DIR" >&2
  exit 2
fi

FAILED=0
while IFS='|' read -r rel_path expected_sha; do
  file="$OUT_DIR/$rel_path"
  if [ ! -f "$file" ]; then
    printf 'Missing continuity file: %s\n' "$file" >&2
    FAILED=1
    continue
  fi
  actual_sha="$(hash_file "$file")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    printf 'Hash mismatch: %s expected=%s actual=%s\n' "$rel_path" "$expected_sha" "$actual_sha" >&2
    FAILED=1
  fi
done <<EOF
$(manifest_entries)
EOF

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

printf '# Verified Continuity Bootstrap\n\n'
printf 'Manifest: %s\n\n' "$MANIFEST_FILE"
cat "$HANDOFF_FILE"
printf '\n---\n\n'
cat "$BOOTSTRAP_FILE"
