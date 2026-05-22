# Publishing observo-ai/upload-pipeline-action (one-shot)

This folder was developed inside the `yatsinaba/observo` monorepo
during OB-324. To ship v1.0.0 as a standalone GitHub Action, copy these
files to a fresh repo under the `observo-ai` org and tag.

## Prerequisites

- `gh` CLI authenticated as a user with admin rights on the `observo-ai` org.
- `git` configured locally.
- This folder (`_external/upload-pipeline-action/`) has all the files
  the published repo should carry — nothing in it references monorepo
  paths.

## One-shot publish (recommended)

```bash
# From the monorepo root.
cd _external/upload-pipeline-action

# Verify shellcheck + bats locally one last time
shellcheck entrypoint.sh scripts/observo-pipeline-publish.sh
bats test/    # requires bats: brew install bats-core (macOS) / apt install bats (linux)

# 1. Create the public repo on GitHub.
gh repo create observo-ai/upload-pipeline-action \
    --public \
    --description "GitHub Action: parse JUnit XML per layer, publish a single Observo pipeline TestRun." \
    --homepage "https://observoai.co"

# 2. Initialize this folder as its own git history.
#    NB: do NOT use `git init` if a parent .git already exists — that's
#    why we explicitly --git-dir to a fresh location.
GIT_DIR=$(mktemp -d)/.git
GIT_WORK_TREE=$(pwd)
export GIT_DIR GIT_WORK_TREE
git init -b main
git remote add origin git@github.com:observo-ai/upload-pipeline-action.git
git add .
git commit -m "feat: initial v1.0.0 — JUnit aggregator + pipeline publish"
git push -u origin main

# 3. Tag v1.0.0 + move the v1 floating tag to the same commit.
git tag -a v1.0.0 -m "v1.0.0 — initial release (OB-324)"
git tag -f v1   # major-version floating tag, GitHub Marketplace convention
git push origin v1.0.0
git push origin v1 --force
```

## After publish

1. **Smoke test in CI** — add a step in the monorepo's
   `.github/workflows/observo-pipeline.yml` (OB-325) that uses
   `observo-ai/upload-pipeline-action@v1` against the dogfood project.
2. **Marketplace listing** — OB-329 covers this. Brief: enable the
   "Publish this Action to the GitHub Marketplace" checkbox on the
   v1.0.0 release page, fill out the description, pick a category
   ("Testing").
3. **Delete `_external/upload-pipeline-action/`** from the monorepo
   once v1.0.0 is live — it lives upstream now. Keep the OB-324 PR
   branch for history only; it never merges into `epic` or `main`.

## What's intentionally NOT here

- **A compiled JS bundle** (`dist/index.js`). The Action is composite
  bash, not a node20 action, so there's nothing to compile.
- **A `package.json`**. Same reason.
- **A `Dockerfile`**. Composite actions don't ship containers.
- **`tools.go`**. The Python parser and the bash core have no Go deps.
