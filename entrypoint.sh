#!/usr/bin/env bash
# OB-324: thin wrapper that turns GitHub-Action INPUT_* env vars + the
# native github context into the CI-agnostic OBSERVO_* vars expected by
# scripts/observo-pipeline-publish.sh.
#
# Keep this file boring: only env normalization + default resolution.
# Anything that touches the Observo API belongs in the shared core so a
# future GitLab Component / Jenkins shared library can reuse it
# byte-identically.

set -euo pipefail

# action.yml runs this script via `${{ github.action_path }}/entrypoint.sh`
# so $0 is an absolute path inside the action checkout. The shared core
# lives alongside.
ACTION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CORE="$ACTION_DIR/scripts/observo-pipeline-publish.sh"

if [[ ! -x "$CORE" ]]; then
    # The action repo is meant to ship with executable bits set, but
    # tarball-style checkouts sometimes strip them. Re-add defensively.
    chmod +x "$CORE" "$ACTION_DIR/scripts/parse-junit.py" 2>/dev/null || true
fi

# -------------------------------------------------------------------------
# Required inputs — surface a clear error rather than letting the core
# fail later with a parameter-expansion error.
# -------------------------------------------------------------------------

if [[ -z "${INPUT_API_KEY:-}" ]]; then
    echo "::error::api-key input is required (pass via secrets.OBSERVO_API_KEY)" >&2
    exit 2
fi
if [[ -z "${INPUT_PROJECT_ID:-}" ]]; then
    echo "::error::project-id input is required (UUID or short project code)" >&2
    exit 2
fi
if [[ -z "${INPUT_LAYERS:-}" ]]; then
    echo "::error::layers input is required (multi-line YAML)" >&2
    exit 2
fi

# -------------------------------------------------------------------------
# Default resolution from the github context. Action inputs win when set;
# otherwise we fall back to the standard env vars GH provides for every
# step.
# -------------------------------------------------------------------------

commit_sha="${INPUT_COMMIT_SHA:-${GITHUB_SHA:-}}"
branch="${INPUT_BRANCH:-${GITHUB_REF_NAME:-}}"
actor="${INPUT_ACTOR:-${GITHUB_ACTOR:-}}"
base_url="${INPUT_BASE_URL:-https://api.observoai.co}"

# ci-run-url: built from server URL + repo + run id when not explicitly
# passed. GITHUB_SERVER_URL covers github.com AND GitHub Enterprise Server
# without us hardcoding the host.
ci_run_url="${INPUT_CI_RUN_URL:-}"
if [[ -z "$ci_run_url" && -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    ci_run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
fi

# commit-url: same idea — derive when missing.
commit_url=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "$commit_sha" ]]; then
    commit_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/commit/$commit_sha"
fi

# pr-url: only available when the workflow was triggered by a PR. The
# GH context exposes it as event.pull_request.html_url; the action input
# is the canonical override.
pr_url="${INPUT_PR_URL:-}"
if [[ -z "$pr_url" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    pr_url=$(python3 -c '
import json, os, sys
try:
    with open(os.environ["GITHUB_EVENT_PATH"]) as f:
        ev = json.load(f)
    print(ev.get("pull_request", {}).get("html_url") or "")
except Exception:
    sys.exit(0)
' 2>/dev/null || true)
fi

# run-name: when the user did not pass one, use the first line of the
# head commit message — that's what every other GitHub-native tool
# (Slack notifications, GitHub status checks) does, so it stays familiar.
run_name="${INPUT_RUN_NAME:-}"
if [[ -z "$run_name" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    run_name=$(python3 -c '
import json, os, sys
try:
    with open(os.environ["GITHUB_EVENT_PATH"]) as f:
        ev = json.load(f)
    msg = (ev.get("head_commit", {}) or {}).get("message", "")
    print(msg.splitlines()[0] if msg else "")
except Exception:
    sys.exit(0)
' 2>/dev/null || true)
fi

# Final fallback so the core's "Pipeline <short_sha>" naming kicks in.
[[ -z "$run_name" ]] && run_name=""

# -------------------------------------------------------------------------
# Hand off to the shared core.
# -------------------------------------------------------------------------

export OBSERVO_API_KEY="$INPUT_API_KEY"
export OBSERVO_PROJECT_ID="$INPUT_PROJECT_ID"
export OBSERVO_BASE_URL="$base_url"
export OBSERVO_RUN_NAME="$run_name"
export OBSERVO_COMMIT_SHA="$commit_sha"
export OBSERVO_COMMIT_URL="$commit_url"
export OBSERVO_BRANCH="$branch"
export OBSERVO_PR_URL="$pr_url"
export OBSERVO_ACTOR="$actor"
export OBSERVO_CI_RUN_URL="$ci_run_url"
export OBSERVO_LAYERS_YAML="$INPUT_LAYERS"
export OBSERVO_SOURCE_SYSTEM="github_actions"
export OBSERVO_FAIL_ON_TEST_FAIL="${INPUT_FAIL_ON_TEST_FAIL:-false}"

exec "$CORE"
