#!/usr/bin/env bash
# OB-324: observo-ai/upload-pipeline-action — shared publish core.
#
# Intentionally CI-agnostic: every CI-specific bit (env var names, run
# URL composition) lives in the thin entrypoint that calls us. That keeps
# a future GitLab Component or Jenkins shared library to a 30-line
# wrapper around this same script.
#
# Required environment (entrypoint maps the GitHub Action inputs here):
#   OBSERVO_API_KEY            account-scoped API key
#   OBSERVO_PROJECT_ID         UUID or short project code
#   OBSERVO_BASE_URL           e.g. https://api.observoai.co
#   OBSERVO_LAYERS_YAML        multi-line YAML describing the layers
# Optional (sensible defaults applied):
#   OBSERVO_RUN_NAME           defaults to "Pipeline <short_sha>"
#   OBSERVO_COMMIT_SHA / OBSERVO_COMMIT_URL / OBSERVO_BRANCH
#   OBSERVO_PR_URL / OBSERVO_ACTOR / OBSERVO_CI_RUN_URL / OBSERVO_SOURCE_SYSTEM
#   OBSERVO_FAIL_ON_TEST_FAIL  "true" to exit non-zero on test failures
#
# Writes to stdout: progress log lines + the final run URL.
# Writes to $GITHUB_OUTPUT when present: run-id, run-url (for action outputs).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PARSER="$SCRIPT_DIR/parse-junit.py"

# -------------------------------------------------------------------------
# Input validation
# -------------------------------------------------------------------------

: "${OBSERVO_API_KEY:?api-key is required}"
: "${OBSERVO_PROJECT_ID:?project-id is required}"
: "${OBSERVO_BASE_URL:=https://api.observoai.co}"
: "${OBSERVO_LAYERS_YAML:?layers YAML is required}"

# Sensible defaults for the metadata block; entrypoint usually overrides.
: "${OBSERVO_SOURCE_SYSTEM:=github_actions}"
: "${OBSERVO_COMMIT_SHA:=}"
: "${OBSERVO_COMMIT_URL:=}"
: "${OBSERVO_BRANCH:=}"
: "${OBSERVO_PR_URL:=}"
: "${OBSERVO_ACTOR:=}"
: "${OBSERVO_CI_RUN_URL:=}"
: "${OBSERVO_FAIL_ON_TEST_FAIL:=false}"

if [[ -z "${OBSERVO_RUN_NAME:-}" ]]; then
    short_sha="${OBSERVO_COMMIT_SHA:0:7}"
    OBSERVO_RUN_NAME="Pipeline ${short_sha:-unknown}"
fi

# Required tools — fail early with a clear message instead of letting a
# downstream pipe break with a cryptic exit code.
for cmd in python3 jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "::error::observo-pipeline-publish: required tool '$cmd' not found on PATH" >&2
        exit 127
    fi
done

# -------------------------------------------------------------------------
# Layers YAML → JSON array (one helper Python call, then pure jq)
# -------------------------------------------------------------------------
#
# We avoid pulling yq onto the runner: Python stdlib `yaml` isn't there
# either, BUT we only need a small subset (- id / display_name / framework
# / junit / coverage.lcov / coverage.html). The inline parser below is
# permissive (ignores extra keys) and emits one JSON object per layer.

layers_json=$(python3 <<'PY'
"""Minimal multi-doc YAML → JSON list. Handles the `- key: value` shape
used by `layers:` Action input only — not a general YAML parser. We don't
import a third-party YAML lib so the action stays zero-deps.

The YAML body is read from $OBSERVO_LAYERS_YAML (not stdin) so the
caller's heredoc can stay clean — competing redirections on stdin trip
shellcheck SC2261 and are confusing to debug."""
import json
import os
import re
import sys

text = os.environ.get("OBSERVO_LAYERS_YAML", "")
lines = text.splitlines()

layers = []
current = None
indent_re = re.compile(r"^(\s*)(.+)$")
kv_re = re.compile(r"^([A-Za-z_][\w-]*):\s*(.*)$")

def commit():
    global current
    if current is not None:
        layers.append(current)
        current = None

for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    m = indent_re.match(raw)
    if not m:
        continue
    indent, body = m.group(1), m.group(2)

    if body.startswith("- "):
        commit()
        current = {}
        body = body[2:]
        km = kv_re.match(body)
        if km:
            current[km.group(1)] = km.group(2).strip()
        continue

    if current is None:
        continue

    # Nested coverage: when indented under a layer item.
    if body.startswith("coverage:"):
        current["coverage"] = {}
        continue

    km = kv_re.match(body)
    if not km:
        continue
    key, val = km.group(1), km.group(2).strip()

    # 4-space deeper than the layer key means we're inside coverage.
    if "coverage" in current and len(indent) >= 4 and key in ("lcov", "html"):
        current["coverage"][key] = val
    else:
        current[key] = val

commit()
print(json.dumps(layers, separators=(",", ":")))
PY
)

# Validate: every layer needs id + junit; ids unique.
layer_count=$(jq 'length' <<<"$layers_json")
if [[ "$layer_count" -eq 0 ]]; then
    echo "::error::No layers parsed from input. Did the YAML format match the README?" >&2
    exit 4
fi

dupe_ids=$(jq -r '[.[].id] | group_by(.) | map(select(length>1) | .[0]) | join(",")' <<<"$layers_json")
if [[ -n "$dupe_ids" ]]; then
    echo "::error::Duplicate layer id(s): $dupe_ids" >&2
    exit 5
fi

# -------------------------------------------------------------------------
# Per-layer aggregation
# -------------------------------------------------------------------------

aggregated_layers='[]'
all_tagged_cases='[]'
any_failures=0

# `jq -c '.[]'` keeps each object on its own line so the bash loop reads
# them one at a time. Using a here-string instead of a pipe so variables
# set inside the loop survive (no subshell).
while IFS= read -r layer_obj; do
    id=$(jq -r '.id' <<<"$layer_obj")
    display_name=$(jq -r '.display_name // .id' <<<"$layer_obj")
    framework=$(jq -r '.framework // ""' <<<"$layer_obj")
    junit_path=$(jq -r '.junit // ""' <<<"$layer_obj")

    if [[ -z "$junit_path" || ! -f "$junit_path" ]]; then
        echo "::warning::Layer '$id': junit file not found at '$junit_path' — skipping aggregation"
        continue
    fi

    echo "  layer '$id' ← $junit_path"
    parsed=$(python3 "$PARSER" "$junit_path")

    layer_failed=$(jq -r '.failed' <<<"$parsed")
    if (( layer_failed > 0 )); then any_failures=1; fi

    # Build a PipelineLayer object matching the proto schema (snake_case
    # because the server's protojson UseProtoNames=true expects it).
    layer_proto=$(jq -c \
        --arg id "$id" \
        --arg display_name "$display_name" \
        --arg framework "$framework" \
        '{
            id: $id,
            display_name: $display_name,
            framework: $framework,
            total: .total,
            passed: .passed,
            failed: .failed,
            flaky: .flaky,
            skipped: .skipped,
            duration_ms: .duration_ms
        }' <<<"$parsed")

    aggregated_layers=$(jq -c ". + [$layer_proto]" <<<"$aggregated_layers")

    # Carry forward tagged-case rows; we'll PATCH them after the run is created.
    tagged=$(jq -c --arg layer_id "$id" '.tagged_cases | map(. + {layer_id: $layer_id})' <<<"$parsed")
    all_tagged_cases=$(jq -c ". + $tagged" <<<"$all_tagged_cases")
done < <(jq -c '.[]' <<<"$layers_json")

# -------------------------------------------------------------------------
# Build CreateRun payload + POST it
# -------------------------------------------------------------------------

# Use --argjson for the layers array so jq embeds the structure (vs --arg
# which would treat it as a string).
pipeline_payload=$(jq -nc \
    --arg kind "pipeline" \
    --arg source_system "$OBSERVO_SOURCE_SYSTEM" \
    --arg commit_sha "$OBSERVO_COMMIT_SHA" \
    --arg commit_url "$OBSERVO_COMMIT_URL" \
    --arg branch "$OBSERVO_BRANCH" \
    --arg pr_url "$OBSERVO_PR_URL" \
    --arg actor "$OBSERVO_ACTOR" \
    --arg ci_run_url "$OBSERVO_CI_RUN_URL" \
    --argjson layers "$aggregated_layers" \
    '{
        kind: $kind,
        source_system: $source_system,
        commit_sha: $commit_sha,
        commit_url: $commit_url,
        branch: $branch,
        pr_url: $pr_url,
        actor: $actor,
        ci_run_url: $ci_run_url,
        layers: $layers
    }')

create_run_body=$(jq -nc \
    --arg project_id "$OBSERVO_PROJECT_ID" \
    --arg name "$OBSERVO_RUN_NAME" \
    --arg automation_status "automated" \
    --argjson pipeline "$pipeline_payload" \
    '{
        project_id: $project_id,
        name: $name,
        automation_status: $automation_status,
        pipeline: $pipeline
    }')

# URL-encode project id for the path. POSIX shell doesn't have a clean
# encoder; we lean on python for it. Project codes are [A-Z0-9-]; UUIDs
# are [A-Za-z0-9-]; both pass through unchanged but the encoder is
# defensive against future formats.
project_id_enc=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$OBSERVO_PROJECT_ID")

echo "==> POST $OBSERVO_BASE_URL/api/projects/$project_id_enc/runs"
http_code=$(mktemp)
response=$(mktemp)
curl_status=0
curl -sS -L -X POST \
    -H "Authorization: Bearer $OBSERVO_API_KEY" \
    -H "Content-Type: application/json" \
    -o "$response" \
    -w "%{http_code}" \
    --data-binary "$create_run_body" \
    "$OBSERVO_BASE_URL/api/projects/$project_id_enc/runs" >"$http_code" || curl_status=$?

code=$(<"$http_code")
if [[ "$curl_status" -ne 0 || "$code" -lt 200 || "$code" -ge 300 ]]; then
    echo "::error::CreateRun failed (HTTP $code, curl_status=$curl_status)" >&2
    head -c 2000 "$response" >&2 || true
    rm -f "$http_code" "$response"
    exit 6
fi

run_json=$(<"$response")
rm -f "$http_code" "$response"

run_id=$(jq -r '.run.id // ""' <<<"$run_json")
if [[ -z "$run_id" ]]; then
    echo "::error::CreateRun response did not include a run.id" >&2
    head -c 2000 <<<"$run_json" >&2 || true
    exit 7
fi

echo "==> Run created: $run_id"

# -------------------------------------------------------------------------
# Per-case status PATCH for @observo:<short_code> tagged tests
# -------------------------------------------------------------------------
#
# We don't bail on individual PATCH failures — they're enrichment, not
# correctness. The TestRun itself is already created with the layer
# aggregates; per-case linkage is bonus signal for the dashboard.

tagged_count=$(jq 'length' <<<"$all_tagged_cases")
if (( tagged_count > 0 )); then
    echo "==> Updating per-case status for $tagged_count tagged tests"

    # batch_add the tagged cases first, so the per-case PATCH below has
    # somewhere to write to. We send a single batch_add with the union of
    # short_codes (deduped).
    short_codes=$(jq -c '[.[].short_code] | unique' <<<"$all_tagged_cases")
    batch_body=$(jq -nc --argjson test_case_ids "$short_codes" '{ test_case_ids: $test_case_ids }')
    curl -sS -L -X POST \
        -H "Authorization: Bearer $OBSERVO_API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "$batch_body" \
        "$OBSERVO_BASE_URL/api/runs/$run_id/cases:batch_add" \
        >/dev/null || echo "::warning::batch_add tagged cases failed; per-case PATCH may attach zero cases"

    while IFS= read -r tagged_obj; do
        short_code=$(jq -r '.short_code' <<<"$tagged_obj")
        status=$(jq -r '.status' <<<"$tagged_obj")

        # Map our internal statuses to the server's run-case enum. The
        # `flaky` bucket goes through as "passed" with the run-level
        # flake counter still capturing the layer-side signal.
        case "$status" in
            passed|flaky) rc_status="passed" ;;
            failed)       rc_status="failed" ;;
            skipped)      rc_status="skipped" ;;
            *)            rc_status="passed" ;;
        esac

        patch_body=$(jq -nc --arg status "$rc_status" '{ status: $status }')
        curl -sS -L -X PATCH \
            -H "Authorization: Bearer $OBSERVO_API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary "$patch_body" \
            "$OBSERVO_BASE_URL/api/runs/$run_id/cases/$short_code" \
            >/dev/null || echo "::warning::Per-case PATCH failed for $short_code (status=$rc_status)"
    done < <(jq -c '.[]' <<<"$all_tagged_cases")
fi

# -------------------------------------------------------------------------
# Per-layer attachments — upload junit + coverage.lcov + coverage.html,
# capture each attachment.id from the server response, splice the IDs
# back into the aggregated_layers JSON so the final PATCH below carries
# them. v1.0.1: this is the chain that activates "Open HTML report" /
# "Download LCOV" / junit links inside the Observo dashboard's
# PipelineLayersPanel detail view. v1.0.0 dropped the response on the
# floor and the IDs were never persisted.
# -------------------------------------------------------------------------

# Helper: POST a single file to the attachments endpoint, return the
# attachment.id on stdout (empty string on any failure). Caller decides
# whether an empty result is fatal; we treat attachment uploads as
# best-effort enrichment.
upload_attachment() {
    local file=$1
    local resp
    if ! resp=$(curl -sS -L -X POST \
            -H "Authorization: Bearer $OBSERVO_API_KEY" \
            -F "file=@$file" \
            -F "run_id=$run_id" \
            "$OBSERVO_BASE_URL/api/projects/$project_id_enc/attachments:upload"); then
        return 1
    fi
    jq -r '.attachment.id // empty' <<<"$resp"
}

while IFS= read -r layer_obj; do
    id=$(jq -r '.id' <<<"$layer_obj")
    junit_path=$(jq -r '.junit // ""' <<<"$layer_obj")
    lcov_path=$(jq -r '.coverage.lcov // ""' <<<"$layer_obj")
    html_path=$(jq -r '.coverage.html // ""' <<<"$layer_obj")

    junit_id=""
    lcov_id=""
    html_id=""

    # JUnit: v1.0.0 already parsed this file for aggregates; uploading
    # the raw XML lets operators download it from the dashboard for
    # offline triage of failures.
    if [[ -n "$junit_path" && -f "$junit_path" ]]; then
        if ! junit_id=$(upload_attachment "$junit_path"); then
            echo "::warning::Layer '$id': junit upload failed"
            junit_id=""
        fi
    fi

    if [[ -n "$lcov_path" ]]; then
        if [[ -f "$lcov_path" ]]; then
            if ! lcov_id=$(upload_attachment "$lcov_path"); then
                echo "::warning::Layer '$id': lcov upload failed"
                lcov_id=""
            fi
        else
            echo "::warning::Layer '$id': lcov file '$lcov_path' not found — skipping"
        fi
    fi

    if [[ -n "$html_path" ]]; then
        if [[ -f "$html_path" ]]; then
            if ! html_id=$(upload_attachment "$html_path"); then
                echo "::warning::Layer '$id': html upload failed"
                html_id=""
            fi
        else
            echo "::warning::Layer '$id': html file '$html_path' not found — skipping"
        fi
    fi

    # Splice the captured IDs into the matching layer in aggregated_layers.
    # `coverage //= {}` creates the nested object on demand — v1.0.0's
    # aggregation step omits it entirely, so we add it here when any
    # coverage attachment landed.
    if [[ -n "$junit_id" || -n "$lcov_id" || -n "$html_id" ]]; then
        aggregated_layers=$(jq -c \
            --arg id "$id" \
            --arg j "$junit_id" \
            --arg l "$lcov_id" \
            --arg h "$html_id" \
            'map(if .id == $id then
                    (if $j != "" then .junit_attachment_id = $j else . end)
                    | (if $l != "" then (.coverage //= {}) | .coverage.lcov_attachment_id = $l else . end)
                    | (if $h != "" then (.coverage //= {}) | .coverage.html_attachment_id = $h else . end)
                 else . end)' <<<"$aggregated_layers")
    fi
done < <(jq -c '.[]' <<<"$layers_json")

# Rebuild pipeline_payload from the (now ID-enriched) aggregated_layers
# so the final PATCH below carries them. Server PATCH semantics replace
# the pipeline column wholesale, so we must re-send the full structure.
pipeline_payload=$(jq -c \
    --argjson layers "$aggregated_layers" \
    '.layers = $layers' <<<"$pipeline_payload")

# -------------------------------------------------------------------------
# Final status PATCH — close the run with passed/failed + finished_at
# -------------------------------------------------------------------------

final_status="passed"
if (( any_failures > 0 )); then
    final_status="failed"
fi
finished_at=$(python3 -c 'import datetime; print(datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"))')

# Re-send pipeline metadata with the same shape, only finished_at filled.
# Server PATCH semantics replace pipeline wholesale (see OB-322 review fixup).
pipeline_final=$(jq -c --arg finished_at "$finished_at" '. + { finished_at: $finished_at }' <<<"$pipeline_payload")
patch_body=$(jq -nc --arg status "$final_status" --argjson pipeline "$pipeline_final" \
    '{ status: $status, pipeline: $pipeline }')

curl -sS -L -X PATCH \
    -H "Authorization: Bearer $OBSERVO_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "$patch_body" \
    "$OBSERVO_BASE_URL/api/projects/$project_id_enc/runs/$run_id" \
    >/dev/null || echo "::warning::Final status PATCH failed (run still exists with layer aggregates intact)"

# -------------------------------------------------------------------------
# Action outputs + final exit code
# -------------------------------------------------------------------------

# Build a hosted-URL guess for the run-url output. We assume the API base
# URL has an `api.` prefix that we can swap for the dashboard host.
dashboard_base=${OBSERVO_BASE_URL/#https:\/\/api./https://app.}
dashboard_base=${dashboard_base/#http:\/\/api./http://app.}
run_url="$dashboard_base/run/$run_id"

echo "==> Pipeline run: $run_url"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "run-id=$run_id"
        echo "run-url=$run_url"
    } >> "$GITHUB_OUTPUT"
fi

if [[ "$OBSERVO_FAIL_ON_TEST_FAIL" == "true" && "$any_failures" -ne 0 ]]; then
    echo "::error::fail-on-test-fail=true and at least one layer has failures."
    exit 1
fi

exit 0
