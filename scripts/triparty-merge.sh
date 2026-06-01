#!/usr/bin/env bash
set -u

if [ "$#" -lt 1 ]; then
  printf 'Usage: %s <run-dir>\n' "$0" >&2
  exit 2
fi

RUN_DIR="$1"
STATUS_FILE="$RUN_DIR/source-status.md"
OUT_FILE="$RUN_DIR/merge-status.md"
STATUS_ENV="$RUN_DIR/status.env"
REQUIRE_CROSS_AUDIT="${TRIPARTY_REQUIRE_CROSS_AUDIT:-1}"
if [ -f "$RUN_DIR/status/status.env" ]; then
  STATUS_ENV="$RUN_DIR/status/status.env"
fi

if [ ! -f "$STATUS_FILE" ]; then
  printf 'Missing source status file: %s\n' "$STATUS_FILE" >&2
  exit 2
fi

hash_file() {
  local file="$1"
  if [ -f "$file" ]; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

label_contamination_status() {
  local party="$1"
  local file="$2"

  if [ ! -f "$file" ]; then
    printf 'Missing'
    return
  fi

  if sed -n '1,30p' "$file" | grep -Eiq '(^|[[:space:]>#*_:-])(Codex-only provisional|Codex plus Codex sub-agents)($|[[:space:][:punct:]])|(^|[[:space:]>#*_:-])(I am|我是)[[:space:]]*Codex($|[[:space:][:punct:]])|source[- ]?label[:：][[:space:]]*Codex|来源标签[:：][[:space:]]*Codex|源标签[:：][[:space:]]*Codex'; then
    printf 'Contaminated'
    return
  fi

  if sed -n '1,30p' "$file" | grep -Eiq '来源状态[:：]|Source status[:：]|非真三方结论|not a true tri-party|Codex-only[[:space:]]*上下文|(Gemini|Claude|Codex)[[:space:]|:=]+(未调用|未直接调用|not called)'; then
    printf 'Contaminated'
    return
  fi

  if [ "$party" = "Claude" ] && sed -n '1,30p' "$file" | grep -Eiq '(^|[[:space:]>#*_:-])(Source|Source label|来源|源标签)[:：][[:space:]]*Gemini CLI|(^|[[:space:]>#*_:-])(我是|I am)[[:space:]]*Gemini($|[[:space:][:punct:]])'; then
    printf 'Contaminated'
    return
  fi

  if [ "$party" = "Gemini" ] && sed -n '1,30p' "$file" | grep -Eiq '(^|[[:space:]>#*_:-])(Source|Source label|来源|源标签)[:：][[:space:]]*Claude CLI|(^|[[:space:]>#*_:-])(我是|I am)[[:space:]]*Claude($|[[:space:][:punct:]])'; then
    printf 'Contaminated'
    return
  fi

  printf 'Clean'
}

artifact_metadata_status() {
  local party="$1"
  local stage="$2"
  local marker="$3"
  local file="$4"
  local header

  if [ ! -f "$file" ]; then
    printf 'Missing'
    return
  fi

  header="$(sed -n '1,24p' "$file")"
  if ! printf '%s\n' "$header" | grep -Fxq 'triparty_artifact: v1'; then
    printf 'MissingMetadata'
    return
  fi
  if ! printf '%s\n' "$header" | grep -Fxq "party: $party"; then
    printf 'PartyMismatch'
    return
  fi
  if ! printf '%s\n' "$header" | grep -Fxq "stage: $stage"; then
    printf 'StageMismatch'
    return
  fi
  if ! printf '%s\n' "$header" | grep -Fxq "completion_marker: $marker"; then
    printf 'MarkerMetadataMissing'
    return
  fi
  if ! printf '%s\n' "$header" | grep -Eq '^generated_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    printf 'GeneratedAtMissing'
    return
  fi
  if ! grep -Fxq "$marker" "$file"; then
    printf 'CompletionMissing'
    return
  fi

  printf 'Valid'
}

artifact_runtime_noise_status() {
  local file="$1"

  if [ ! -f "$file" ]; then
    printf 'Missing'
    return
  fi

  if grep -Eiq 'GaxiosError|MODEL_CAPACITY_EXHAUSTED|RESOURCE_EXHAUSTED|No capacity available|Warning: True color|Warning: Basic terminal|Warning: 256-color support|Ripgrep is not available|ignored by configured ignore patterns|Error executing tool read_file|Unauthorized tool call|Tool ".*" not found|LocalAgentExecutor.*Blocked call' "$file"; then
    printf 'Noisy'
    return
  fi

  printf 'Clean'
}

extract_review_status() {
  local party="$1"
  awk -F '|' -v party="$party" '
    $0 ~ "^\\| " party " " {
      gsub(/^ +| +$/, "", $4)
      print $4
      exit
    }
  ' "$STATUS_FILE"
}

CLAUDE_REVIEW_STATUS="$(extract_review_status "Claude")"
GEMINI_REVIEW_STATUS="$(extract_review_status "Gemini")"

if [ -z "$CLAUDE_REVIEW_STATUS" ]; then
  CLAUDE_REVIEW_STATUS="Missing"
fi
if [ -z "$GEMINI_REVIEW_STATUS" ]; then
  GEMINI_REVIEW_STATUS="Missing"
fi

if [ -f "$STATUS_ENV" ]; then
  # shellcheck disable=SC1090
  . "$STATUS_ENV"
fi

CLAUDE_REVIEW_PATH="${CLAUDE_REVIEW_PATH:-"$RUN_DIR/claude-review.md"}"
GEMINI_REVIEW_PATH="${GEMINI_REVIEW_PATH:-"$RUN_DIR/gemini-review.md"}"
CLAUDE_REVIEW_SHA256="${CLAUDE_REVIEW_SHA256:-}"
GEMINI_REVIEW_SHA256="${GEMINI_REVIEW_SHA256:-}"

CLAUDE_ACTUAL_SHA256="$(hash_file "$CLAUDE_REVIEW_PATH")"
GEMINI_ACTUAL_SHA256="$(hash_file "$GEMINI_REVIEW_PATH")"

CLAUDE_HASH_STATUS="Match"
GEMINI_HASH_STATUS="Match"
if [ -z "$CLAUDE_REVIEW_SHA256" ] || [ "$CLAUDE_REVIEW_SHA256" != "$CLAUDE_ACTUAL_SHA256" ]; then
  CLAUDE_HASH_STATUS="Mismatch"
fi
if [ -z "$GEMINI_REVIEW_SHA256" ] || [ "$GEMINI_REVIEW_SHA256" != "$GEMINI_ACTUAL_SHA256" ]; then
  GEMINI_HASH_STATUS="Mismatch"
fi

CLAUDE_SIZE_STATUS="NonEmpty"
GEMINI_SIZE_STATUS="NonEmpty"
if [ ! -s "$CLAUDE_REVIEW_PATH" ]; then
  CLAUDE_SIZE_STATUS="EmptyOrMissing"
fi
if [ ! -s "$GEMINI_REVIEW_PATH" ]; then
  GEMINI_SIZE_STATUS="EmptyOrMissing"
fi

CLAUDE_LABEL_STATUS="$(label_contamination_status "Claude" "$CLAUDE_REVIEW_PATH")"
GEMINI_LABEL_STATUS="$(label_contamination_status "Gemini" "$GEMINI_REVIEW_PATH")"
CLAUDE_METADATA_STATUS="$(artifact_metadata_status "Claude" "review" "TRIPARTY_REVIEW_COMPLETE" "$CLAUDE_REVIEW_PATH")"
GEMINI_METADATA_STATUS="$(artifact_metadata_status "Gemini" "review" "TRIPARTY_REVIEW_COMPLETE" "$GEMINI_REVIEW_PATH")"
CLAUDE_NOISE_STATUS="$(artifact_runtime_noise_status "$CLAUDE_REVIEW_PATH")"
GEMINI_NOISE_STATUS="$(artifact_runtime_noise_status "$GEMINI_REVIEW_PATH")"

CLAUDE_CROSS_STATUS="NotRequired"
GEMINI_CROSS_STATUS="NotRequired"
CLAUDE_CROSS_PATH="$RUN_DIR/claude-cross-audit.md"
GEMINI_CROSS_PATH="$RUN_DIR/gemini-cross-audit.md"
CLAUDE_CROSS_SHA256=""
GEMINI_CROSS_SHA256=""
CLAUDE_CROSS_SIZE_STATUS="NotRequired"
GEMINI_CROSS_SIZE_STATUS="NotRequired"
CLAUDE_CROSS_HASH_STATUS="NotRequired"
GEMINI_CROSS_HASH_STATUS="NotRequired"
CLAUDE_CROSS_METADATA_STATUS="NotRequired"
GEMINI_CROSS_METADATA_STATUS="NotRequired"
CLAUDE_CROSS_NOISE_STATUS="NotRequired"
GEMINI_CROSS_NOISE_STATUS="NotRequired"
if [ "$REQUIRE_CROSS_AUDIT" = "1" ]; then
  CROSS_ENV="$RUN_DIR/cross-audit.env"
  if [ -f "$RUN_DIR/status/cross-audit.env" ]; then
    CROSS_ENV="$RUN_DIR/status/cross-audit.env"
  fi
  if [ -f "$CROSS_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CROSS_ENV"
  else
    CLAUDE_CROSS_STATUS="Missing"
    GEMINI_CROSS_STATUS="Missing"
  fi

  CLAUDE_CROSS_PATH="${CLAUDE_CROSS_PATH:-"$RUN_DIR/claude-cross-audit.md"}"
  GEMINI_CROSS_PATH="${GEMINI_CROSS_PATH:-"$RUN_DIR/gemini-cross-audit.md"}"
  CLAUDE_CROSS_ACTUAL_SHA256="$(hash_file "$CLAUDE_CROSS_PATH")"
  GEMINI_CROSS_ACTUAL_SHA256="$(hash_file "$GEMINI_CROSS_PATH")"

  CLAUDE_CROSS_SIZE_STATUS="NonEmpty"
  GEMINI_CROSS_SIZE_STATUS="NonEmpty"
  if [ ! -s "$CLAUDE_CROSS_PATH" ]; then
    CLAUDE_CROSS_SIZE_STATUS="EmptyOrMissing"
  fi
  if [ ! -s "$GEMINI_CROSS_PATH" ]; then
    GEMINI_CROSS_SIZE_STATUS="EmptyOrMissing"
  fi

  CLAUDE_CROSS_HASH_STATUS="Match"
  GEMINI_CROSS_HASH_STATUS="Match"
  if [ -z "${CLAUDE_CROSS_SHA256:-}" ] || [ "$CLAUDE_CROSS_SHA256" != "$CLAUDE_CROSS_ACTUAL_SHA256" ]; then
    CLAUDE_CROSS_HASH_STATUS="Mismatch"
  fi
  if [ -z "${GEMINI_CROSS_SHA256:-}" ] || [ "$GEMINI_CROSS_SHA256" != "$GEMINI_CROSS_ACTUAL_SHA256" ]; then
    GEMINI_CROSS_HASH_STATUS="Mismatch"
  fi

  CLAUDE_CROSS_METADATA_STATUS="$(artifact_metadata_status "Claude" "cross-audit" "TRIPARTY_CROSS_AUDIT_COMPLETE" "$CLAUDE_CROSS_PATH")"
  GEMINI_CROSS_METADATA_STATUS="$(artifact_metadata_status "Gemini" "cross-audit" "TRIPARTY_CROSS_AUDIT_COMPLETE" "$GEMINI_CROSS_PATH")"
  CLAUDE_CROSS_NOISE_STATUS="$(artifact_runtime_noise_status "$CLAUDE_CROSS_PATH")"
  GEMINI_CROSS_NOISE_STATUS="$(artifact_runtime_noise_status "$GEMINI_CROSS_PATH")"
fi

if [ "$CLAUDE_REVIEW_STATUS" = "Completed" ] \
  && [ "$GEMINI_REVIEW_STATUS" = "Completed" ] \
  && [ "$CLAUDE_HASH_STATUS" = "Match" ] \
  && [ "$GEMINI_HASH_STATUS" = "Match" ] \
  && [ "$CLAUDE_SIZE_STATUS" = "NonEmpty" ] \
  && [ "$GEMINI_SIZE_STATUS" = "NonEmpty" ] \
  && [ "$CLAUDE_METADATA_STATUS" = "Valid" ] \
  && [ "$GEMINI_METADATA_STATUS" = "Valid" ] \
  && [ "$CLAUDE_NOISE_STATUS" = "Clean" ] \
  && [ "$GEMINI_NOISE_STATUS" = "Clean" ] \
  && [ "$CLAUDE_LABEL_STATUS" = "Clean" ] \
  && [ "$GEMINI_LABEL_STATUS" = "Clean" ] \
  && { [ "$REQUIRE_CROSS_AUDIT" != "1" ] || { [ "${CLAUDE_CROSS_STATUS:-Missing}" = "Completed" ] && [ "${GEMINI_CROSS_STATUS:-Missing}" = "Completed" ] && [ "$CLAUDE_CROSS_SIZE_STATUS" = "NonEmpty" ] && [ "$GEMINI_CROSS_SIZE_STATUS" = "NonEmpty" ] && [ "$CLAUDE_CROSS_HASH_STATUS" = "Match" ] && [ "$GEMINI_CROSS_HASH_STATUS" = "Match" ] && [ "$CLAUDE_CROSS_METADATA_STATUS" = "Valid" ] && [ "$GEMINI_CROSS_METADATA_STATUS" = "Valid" ] && [ "$CLAUDE_CROSS_NOISE_STATUS" = "Clean" ] && [ "$GEMINI_CROSS_NOISE_STATUS" = "Clean" ]; }; }; then
  CONCLUSION_LABEL="Ready for true tri-party synthesis"
  EXIT_CODE=0
else
  CONCLUSION_LABEL="Partial review only"
  EXIT_CODE=1
fi

OUT_TMP="$OUT_FILE.tmp.$$"
cat > "$OUT_TMP" <<EOF
# Tri-party Merge Gate

| Party | Review Status |
| --- | --- |
| Codex | Current session must synthesize |
| Claude | $CLAUDE_REVIEW_STATUS |
| Gemini | $GEMINI_REVIEW_STATUS |

## Artifact Gate

| Party | Non-empty | Hash | Metadata | Runtime Noise | Label Scan | Artifact |
| --- | --- | --- | --- | --- | --- | --- |
| Claude | $CLAUDE_SIZE_STATUS | $CLAUDE_HASH_STATUS | $CLAUDE_METADATA_STATUS | $CLAUDE_NOISE_STATUS | $CLAUDE_LABEL_STATUS | $CLAUDE_REVIEW_PATH |
| Gemini | $GEMINI_SIZE_STATUS | $GEMINI_HASH_STATUS | $GEMINI_METADATA_STATUS | $GEMINI_NOISE_STATUS | $GEMINI_LABEL_STATUS | $GEMINI_REVIEW_PATH |

## Cross-audit Gate

| Party | Status | Non-empty | Hash | Metadata | Runtime Noise | Artifact |
| --- | --- | --- | --- | --- | --- | --- |
| Claude audits Gemini | ${CLAUDE_CROSS_STATUS:-Missing} | $CLAUDE_CROSS_SIZE_STATUS | $CLAUDE_CROSS_HASH_STATUS | $CLAUDE_CROSS_METADATA_STATUS | $CLAUDE_CROSS_NOISE_STATUS | $CLAUDE_CROSS_PATH |
| Gemini audits Claude | ${GEMINI_CROSS_STATUS:-Missing} | $GEMINI_CROSS_SIZE_STATUS | $GEMINI_CROSS_HASH_STATUS | $GEMINI_CROSS_METADATA_STATUS | $GEMINI_CROSS_NOISE_STATUS | $GEMINI_CROSS_PATH |
| Codex final audit | Pending in active session | n/a | n/a | n/a | n/a | Current Codex session |

Cross-audit required: $REQUIRE_CROSS_AUDIT

Conclusion label: $CONCLUSION_LABEL

Rules:

- Use "true tri-party conclusion" only when Claude and Gemini are both Completed and Codex synthesizes the result with source labels preserved.
- Otherwise label the output as partial and list missing or invalid party inputs.
EOF
mv "$OUT_TMP" "$OUT_FILE"

if [ "$EXIT_CODE" -eq 0 ]; then
  rm -f "$RUN_DIR/partial-report.md"
  MERGE_INPUT_TMP="$RUN_DIR/merge-input.md.tmp.$$"
  cat > "$MERGE_INPUT_TMP" <<EOF
# Merge Input

## Source Status

$(cat "$STATUS_FILE")

## Claude

$(cat "$RUN_DIR/claude-review.md" 2>/dev/null || printf 'Missing Claude review.')

## Gemini

$(cat "$RUN_DIR/gemini-review.md" 2>/dev/null || printf 'Missing Gemini review.')

## Claude Cross-audit

$(cat "$RUN_DIR/claude-cross-audit.md" 2>/dev/null || printf 'Missing Claude cross-audit.')

## Gemini Cross-audit

$(cat "$RUN_DIR/gemini-cross-audit.md" 2>/dev/null || printf 'Missing Gemini cross-audit.')

## Codex

Codex must synthesize the final answer in the active session.
EOF
  mv "$MERGE_INPUT_TMP" "$RUN_DIR/merge-input.md"
else
  rm -f "$RUN_DIR/merge-input.md"
  PARTIAL_TMP="$RUN_DIR/partial-report.md.tmp.$$"
  cat > "$PARTIAL_TMP" <<EOF
# Partial Review Report

This run is not eligible for a true tri-party conclusion.

## Source Status

$(cat "$STATUS_FILE")

## Missing Or Invalid Inputs

- Claude review status: $CLAUDE_REVIEW_STATUS
- Gemini review status: $GEMINI_REVIEW_STATUS
- Claude hash status: $CLAUDE_HASH_STATUS
- Gemini hash status: $GEMINI_HASH_STATUS
- Claude label status: $CLAUDE_LABEL_STATUS
- Gemini label status: $GEMINI_LABEL_STATUS
- Claude metadata status: $CLAUDE_METADATA_STATUS
- Gemini metadata status: $GEMINI_METADATA_STATUS
- Claude runtime noise status: $CLAUDE_NOISE_STATUS
- Gemini runtime noise status: $GEMINI_NOISE_STATUS
- Claude cross-audit status: ${CLAUDE_CROSS_STATUS:-Missing}
- Gemini cross-audit status: ${GEMINI_CROSS_STATUS:-Missing}
- Claude cross-audit hash status: $CLAUDE_CROSS_HASH_STATUS
- Gemini cross-audit hash status: $GEMINI_CROSS_HASH_STATUS
- Claude cross-audit size status: $CLAUDE_CROSS_SIZE_STATUS
- Gemini cross-audit size status: $GEMINI_CROSS_SIZE_STATUS
- Claude cross-audit metadata status: $CLAUDE_CROSS_METADATA_STATUS
- Gemini cross-audit metadata status: $GEMINI_CROSS_METADATA_STATUS
- Claude cross-audit runtime noise status: $CLAUDE_CROSS_NOISE_STATUS
- Gemini cross-audit runtime noise status: $GEMINI_CROSS_NOISE_STATUS

Use any generated handoff prompt in this run directory to collect missing party input.
If reviews are present but cross-audit is missing, run scripts/triparty-cross-audit.sh with the run directory and then run merge again.
EOF
  mv "$PARTIAL_TMP" "$RUN_DIR/partial-report.md"
fi

if [ -d "$RUN_DIR/status" ]; then
  cp "$OUT_FILE" "$RUN_DIR/status/merge-status.md.tmp.$$"
  mv "$RUN_DIR/status/merge-status.md.tmp.$$" "$RUN_DIR/status/merge-status.md"
fi

cat "$OUT_FILE"
exit "$EXIT_CODE"
