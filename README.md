# observo-ai/upload-pipeline-action

Publish per-layer JUnit results — plus optional coverage attachments and
per-case status — to [Observo](https://observoai.co) as a single
pipeline TestRun. One YAML step in your GitHub workflow.

```yaml
- uses: observo-ai/upload-pipeline-action@v1
  with:
    api-key: ${{ secrets.OBSERVO_API_KEY }}
    project-id: DEMO
    layers: |
      - id: frontend-unit
        display_name: Frontend (Vitest)
        framework: vitest
        junit: web-portal/junit.xml
      - id: backend
        display_name: Backend (Go)
        framework: go
        junit: server/junit.xml
```

The Action treats your test layers as a generic `N` — declare whatever
your stack uses (Vitest, Jest, Cypress, Playwright, Go, RSpec, pytest,
k6, …) and they all roll up into one Observo run with per-layer pass /
fail / flaky / skipped / duration aggregates.

---

## Prerequisites

1. **An Observo account-scoped API key** — created at
   `https://app.observoai.co/account-settings/api-keys`. Store it as a
   GitHub repo (or org) secret named `OBSERVO_API_KEY`.
2. **A project to attribute the run to** — pass either the project
   UUID or the short code (e.g. `DEMO`) visible in your project URL.
   Both are accepted server-side.
3. **JUnit XML output from each test layer**. Most modern test runners
   emit junit out of the box:
   - **Vitest** — `reporters: ['default', ['junit', { outputFile: './junit.xml' }]]` in vitest config
   - **Playwright** — `['junit', { outputFile: 'playwright-report/junit.xml' }]` in playwright config
   - **Jest** — `--reporters=default --reporters=jest-junit` (npm `jest-junit`)
   - **Go** — wrap `go test` with [`gotestsum`](https://github.com/gotestyourself/gotestsum) `--junitfile=junit.xml`
   - **pytest** — `pytest --junit-xml=junit.xml`
   - **RSpec** — `--require rspec_junit_formatter --format RspecJunitFormatter --out junit.xml`

---

## Inputs

| Input | Required | Default | Description |
|---|:---:|---|---|
| `api-key` | ✓ | — | Observo account-scoped API key. Use `${{ secrets.OBSERVO_API_KEY }}`. |
| `project-id` | ✓ | — | Project UUID or short code (e.g. `DEMO`). |
| `layers` | ✓ | — | Multi-line YAML; see [Layer schema](#layer-schema) below. |
| `base-url` | | `https://api.observoai.co` | Override only for self-hosted / staging environments. |
| `run-name` | | first line of head commit | Human-readable run name. |
| `commit-sha` | | `$GITHUB_SHA` | Override only for unusual setups. |
| `branch` | | `$GITHUB_REF_NAME` | Branch ref name. |
| `pr-url` | | `event.pull_request.html_url` | PR URL when the workflow was PR-triggered. |
| `actor` | | `$GITHUB_ACTOR` | Who triggered the workflow. |
| `ci-run-url` | | derived from `$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID` | Link back to this CI run. |
| `fail-on-test-fail` | | `false` | When `true`, action exits non-zero on layer failures (gates the GitHub check). Default `false` is **report, don't gate** — Observo surfaces the failures, GitHub stays green so the pipeline always lands. |

## Outputs

| Output | Description |
|---|---|
| `run-id` | UUID of the created Observo TestRun. Useful for chaining further steps. |
| `run-url` | Web URL of the run in the Observo dashboard. |

## Layer schema

Each entry in `layers:` is a YAML object:

```yaml
- id: frontend-unit              # required, unique within the layers[] block
  display_name: Frontend (Vitest)  # required, shown in the dashboard
  framework: vitest              # optional, drives the icon ("vitest" | "jest" |
                                 # "go" | "playwright" | "cypress" | "pytest" |
                                 # "rspec" | "junit5" | "k6" | …)
  junit: web-portal/junit.xml    # required, path relative to the workflow workdir
  coverage:                      # optional
    lcov: web-portal/coverage/lcov.info     # uploaded as an attachment
    html: web-portal/coverage/index.html    # uploaded as an attachment
```

Layer ids must be unique within a single Action invocation. The Action
fails fast with a clear error if you have duplicates.

### Per-case attribution (optional)

If a test name carries an `@observo:CODE-N` tag (where `CODE-N` is the
short code of a manual case in Observo), the Action will look it up,
batch-add the case to the run, and PATCH its status to match the test
outcome. The tag can live in:

- the testcase `name=` or `classname=` attribute
- a JUnit `<properties><property/></properties>` child
- the testcase `<system-out>` body

Tag pattern: `@observo:DEMO-42` (project code in uppercase, 2–10 letters;
case number is any positive integer).

---

## Scenario A — Node monorepo with Jest + Cypress

```yaml
# .github/workflows/observo-pipeline.yml
name: Observo Pipeline
on:
  push:
    branches: [main]
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - run: npm ci

      # Unit layer — Jest with jest-junit reporter
      - name: Unit tests
        run: npx jest --reporters=default --reporters=jest-junit
        continue-on-error: true  # let Observo surface failures; don't break the pipeline

      # E2E layer — Cypress with junit reporter
      - name: E2E tests
        run: npx cypress run --reporter junit --reporter-options "mochaFile=cypress/junit.xml"
        continue-on-error: true

      - uses: observo-ai/upload-pipeline-action@v1
        if: always()  # publish even when test steps failed
        with:
          api-key: ${{ secrets.OBSERVO_API_KEY }}
          project-id: WEB
          layers: |
            - id: unit
              display_name: Unit (Jest)
              framework: jest
              junit: junit.xml
              coverage:
                lcov: coverage/lcov.info
                html: coverage/lcov-report/index.html
            - id: e2e
              display_name: E2E (Cypress)
              framework: cypress
              junit: cypress/junit.xml
```

Note the `if: always()` on the Action step — without it, a failed test
step would skip the upload and the dashboard would never see the failure.

## Scenario B — Polyglot monorepo (TypeScript + Go + Playwright)

```yaml
# .github/workflows/observo-pipeline.yml
name: Observo Pipeline
on:
  push:
    branches: [main]
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: 'npm' }
      - uses: actions/setup-go@v5
        with: { go-version: '1.24' }

      - name: Install gotestsum
        run: go install gotest.tools/gotestsum@v1.12.1

      # Frontend
      - run: cd web-portal && npm ci && npm test
        continue-on-error: true

      # Backend unit
      - run: cd server && gotestsum --junitfile=junit-unit.xml -- -short ./...
        continue-on-error: true

      # Backend integration (testcontainers)
      - run: cd server && gotestsum --junitfile=junit-integration.xml -- -tags=integration -timeout=5m ./integration/...
        continue-on-error: true

      # E2E
      - run: cd e2e && npm ci && npx playwright install --with-deps chromium && npx playwright test
        continue-on-error: true

      - uses: observo-ai/upload-pipeline-action@v1
        if: always()
        with:
          api-key: ${{ secrets.OBSERVO_API_KEY }}
          project-id: ${{ vars.OBSERVO_PROJECT_ID }}
          layers: |
            - id: frontend-unit
              display_name: Frontend (Vitest)
              framework: vitest
              junit: web-portal/junit.xml
            - id: server-unit
              display_name: Backend Unit (Go)
              framework: go
              junit: server/junit-unit.xml
            - id: server-integration
              display_name: Backend Integration (Go)
              framework: go
              junit: server/junit-integration.xml
            - id: e2e
              display_name: End-to-End (Playwright)
              framework: playwright
              junit: e2e/playwright-report/junit.xml
```

---

## Troubleshooting

### "No layers parsed from input"
The Action's YAML parser handles the canonical `- id: …` shape only.
Common causes: tab-vs-space indentation mismatch, or wrapping the value
in an extra YAML object. Compare against the schema above and the
examples; the dashboard's onboarding empty-state also generates a
project-specific snippet you can copy-paste.

### "Layer 'X': junit file not found"
Path is resolved relative to the workflow workdir. Make sure your test
step actually wrote the file at the path you told the Action to look at.
The Action logs the lookup path so you can see exactly what it tried.

### Tests are red but `fail-on-test-fail: false` — is this a bug?
No. The default is to report results without gating the GitHub status
check. The philosophy: pipelines are most useful when they always run —
a flake shouldn't break the report. If you want a hard gate, set
`fail-on-test-fail: true`. Coverage / per-case PATCH steps stay
best-effort either way.

### How do I retroactively add a layer I forgot?
You can't — a pipeline run is a snapshot. Add the layer to your
`layers:` block in the workflow; the next pipeline run will include it.
Layers added retroactively to Observo by hand (via UI) are out of scope
for this Action.

---

## Compatibility

- GitHub Actions runners: `ubuntu-latest`, `ubuntu-22.04`, `ubuntu-24.04`
  (anything with `bash`, `python3`, `curl`, and `jq` — all stock).
- Self-hosted runners: same requirements. macOS / Windows runners are
  untested.
- Observo API: server commits implementing OB-322 + OB-326 must be live
  (`PipelineMetadata` proto + `GET /api/projects/{id}/pipelines`). For
  self-hosted Observo: ensure your deployment includes those migrations.

## Versioning

Follows [Semantic Versioning](https://semver.org/). Use the major-version
tag in your workflow:

```yaml
uses: observo-ai/upload-pipeline-action@v1
```

`@v1` always points at the latest 1.x release.

## License

MIT — see `LICENSE`.

## Contributing

Issues and PRs welcome. Run `bats test/` for the unit suite and
`shellcheck scripts/*.sh entrypoint.sh` before submitting.
