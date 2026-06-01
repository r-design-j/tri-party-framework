#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_DIR="$(git -C "$ROOT_DIR" rev-parse --git-dir 2>/dev/null || true)"

if [ -z "$GIT_DIR" ]; then
  printf 'Not inside a git repository: %s\n' "$ROOT_DIR" >&2
  exit 2
fi

case "$GIT_DIR" in
  /*) ;;
  *) GIT_DIR="$ROOT_DIR/$GIT_DIR" ;;
esac

mkdir -p "$GIT_DIR/hooks"
hook="$GIT_DIR/hooks/pre-push"

cat > "$hook" <<'EOF'
#!/usr/bin/env bash
set -u

repo_root="$(git rev-parse --show-toplevel)"

if [ "${TRIPARTY_SKIP_RELEASE_GATE:-}" = "1" ]; then
  printf 'triparty pre-push gate skipped by TRIPARTY_SKIP_RELEASE_GATE=1\n' >&2
  exit 0
fi

"$repo_root/scripts/triparty-release-gate.sh"
EOF

chmod +x "$hook"
printf 'Installed triparty pre-push hook: %s\n' "$hook"
