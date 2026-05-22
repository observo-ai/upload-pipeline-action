#!/usr/bin/env bats
# OB-324: bats unit tests for scripts/parse-junit.py.
#
# Why bats and not pytest: the parser is invoked from shell, and the
# Action ships nothing Python-test-framework-shaped. bats lets us assert
# on the same wire shape (stdout JSON) the shell core actually consumes.

setup() {
  PARSER="$BATS_TEST_DIRNAME/../scripts/parse-junit.py"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
}

@test "vitest-mixed: counts 5 total / 4 passed / 1 failed / 0 flaky" {
  run python3 "$PARSER" "$FIXTURES/vitest-mixed.xml"
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq '.total')" -eq 5 ]
  [ "$(echo "$output" | jq '.passed')" -eq 4 ]
  [ "$(echo "$output" | jq '.failed')" -eq 1 ]
  [ "$(echo "$output" | jq '.flaky')" -eq 0 ]
  [ "$(echo "$output" | jq '.skipped')" -eq 0 ]
  # duration sums all testcase.time values (seconds → ms): 0.123+0.234+0.099+0.444+1.441 = 2.341s
  [ "$(echo "$output" | jq '.duration_ms')" -eq 2341 ]
}

@test "vitest-mixed: extracts both @observo:DEMO-N tags with correct status" {
  run python3 "$PARSER" "$FIXTURES/vitest-mixed.xml"
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq '.tagged_cases | length')" -eq 2 ]
  # DEMO-1 passed, DEMO-2 failed (tag on the failing case)
  [ "$(echo "$output" | jq -r '.tagged_cases[] | select(.short_code=="DEMO-1") | .status')" = "passed" ]
  [ "$(echo "$output" | jq -r '.tagged_cases[] | select(.short_code=="DEMO-2") | .status')" = "failed" ]
}

@test "playwright-flaky: counts retries as flaky, not passed" {
  run python3 "$PARSER" "$FIXTURES/playwright-flaky.xml"
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq '.total')" -eq 3 ]
  [ "$(echo "$output" | jq '.passed')" -eq 1 ]
  [ "$(echo "$output" | jq '.flaky')" -eq 1 ]
  [ "$(echo "$output" | jq '.skipped')" -eq 1 ]
  [ "$(echo "$output" | jq '.failed')" -eq 0 ]
}

@test "playwright-flaky: tagged_cases keeps flaky status (not passed)" {
  run python3 "$PARSER" "$FIXTURES/playwright-flaky.xml"
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq -r '.tagged_cases[] | select(.short_code=="DEMO-7") | .status')" = "flaky" ]
}

@test "gotestsum-all-pass: handles bare <testsuite> root (no <testsuites> wrap)" {
  run python3 "$PARSER" "$FIXTURES/gotestsum-all-pass.xml"
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq '.total')" -eq 4 ]
  [ "$(echo "$output" | jq '.passed')" -eq 4 ]
  [ "$(echo "$output" | jq '.tagged_cases | length')" -eq 0 ]
}

@test "missing file: exits 2 with clear stderr" {
  run python3 "$PARSER" /nonexistent/path/junit.xml
  [ "$status" -eq 2 ]
  [[ "$output" == *"file not found"* ]]
}

@test "malformed XML: exits 3 with parse error" {
  tmp=$(mktemp)
  echo "<not xml at all" > "$tmp"
  run python3 "$PARSER" "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 3 ]
  [[ "$output" == *"malformed XML"* ]]
}
