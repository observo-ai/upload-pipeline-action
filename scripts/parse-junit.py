#!/usr/bin/env python3
"""OB-324 — JUnit XML aggregator for observo-ai/upload-pipeline-action.

Reads one JUnit XML file and emits a single-line JSON with per-layer
aggregates the shell core can pipe straight into `jq` when building the
PipelineMetadata request body.

Why Python stdlib instead of jq/xmlstarlet:
  - xml.etree is available on every GitHub Actions runner (no install),
  - jq / xmlstarlet flake on JUnit's mixed schemas (Vitest, gotestsum,
    Playwright, jest, junit5 all differ in attribute names and nesting),
  - aggregation needs branching logic that's painful in pure shell.

Schemas this script tolerates (verified against real-world fixtures):
  - <testsuites><testsuite><testcase> nesting (standard)
  - bare <testsuite><testcase> (no wrapping root)
  - tests/failures/errors/skipped/skips on either testsuites OR testsuite
  - durations on `time` (seconds, may be float) — converted to ms
  - retries: gotestsum re-emits passing testcases on rerun; this counter
    treats them as "flaky" (passed on retry). Playwright/junit5 mark via
    a <flaky/> child or attribute — both detected.
  - per-case @observo:OB-123 tags extracted from <properties> for the
    per-case PATCH step downstream.

Output JSON shape (single line, snake_case to match the server proto):
  {
    "total": int, "passed": int, "failed": int, "skipped": int,
    "flaky": int, "duration_ms": int,
    "tagged_cases": [
      { "short_code": "DEMO-1", "status": "passed" | "failed" | "skipped" | "flaky",
        "name": "test name", "duration_ms": int }
    ]
  }
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET

# Match @observo:DEMO-123 or observo:DEMO-123 in property values / names /
# testcase names. Project codes are 2-10 uppercase letters; case numbers
# are positive integers (matches server val.ValidateCode).
OBSERVO_TAG_RE = re.compile(r"@?observo:([A-Z]{2,10}-\d+)")


def _to_ms(seconds_str: str | None) -> int:
    if not seconds_str:
        return 0
    try:
        return int(round(float(seconds_str) * 1000))
    except (TypeError, ValueError):
        return 0


def _is_failed(case: ET.Element) -> bool:
    # JUnit dialects: <failure/> or <error/> as child means the case failed.
    return case.find("failure") is not None or case.find("error") is not None


def _is_skipped(case: ET.Element) -> bool:
    if case.find("skipped") is not None:
        return True
    # gotestsum sometimes emits `status="skip"` attribute instead.
    return case.attrib.get("status", "").lower() in {"skip", "skipped"}


def _is_flaky(case: ET.Element) -> bool:
    """Was this case retried before passing?

    Three signals we treat as flaky-on-retry:
      - <flaky/> child (junit5, some custom reporters)
      - <rerunFailure/> child (Maven Surefire) — case eventually passed
      - `retries` attribute > 0 (Playwright junit reporter)
    """
    if case.find("flaky") is not None:
        return True
    if case.find("rerunFailure") is not None:
        return True
    retries = case.attrib.get("retries") or case.attrib.get("retry")
    if retries:
        try:
            return int(retries) > 0
        except ValueError:
            return False
    return False


def _short_codes(case: ET.Element) -> list[str]:
    """Extract every @observo:CODE-N tag attached to a testcase.

    Looked up in three places (any source wins):
      - <properties><property name="..." value="..."/> children
      - testcase's own `name` / `classname` attributes
      - testcase's <system-out> body
    A single test can carry multiple tags (e.g. one Playwright spec
    covering two cases); each contributes a row to tagged_cases.
    """
    found: set[str] = set()

    props = case.find("properties")
    if props is not None:
        for p in props.findall("property"):
            for source in (p.attrib.get("name", ""), p.attrib.get("value", "")):
                for m in OBSERVO_TAG_RE.finditer(source):
                    found.add(m.group(1))

    for attr in ("name", "classname"):
        for m in OBSERVO_TAG_RE.finditer(case.attrib.get(attr, "")):
            found.add(m.group(1))

    sys_out = case.find("system-out")
    if sys_out is not None and sys_out.text:
        for m in OBSERVO_TAG_RE.finditer(sys_out.text):
            found.add(m.group(1))

    return sorted(found)


def aggregate(path: str) -> dict:
    tree = ET.parse(path)
    root = tree.getroot()

    # `iter("testcase")` walks both <testsuites><testsuite> and bare
    # <testsuite> layouts uniformly. ET preserves source order, so case
    # numbering downstream is stable.
    cases = list(root.iter("testcase"))

    total = len(cases)
    failed = 0
    skipped = 0
    flaky = 0
    duration_ms = 0
    tagged_cases: list[dict] = []

    for c in cases:
        is_fail = _is_failed(c)
        is_skip = _is_skipped(c)
        is_flak = _is_flaky(c)
        case_ms = _to_ms(c.attrib.get("time"))
        duration_ms += case_ms

        if is_fail:
            failed += 1
            status = "failed"
        elif is_skip:
            skipped += 1
            status = "skipped"
        elif is_flak:
            flaky += 1
            status = "flaky"
        else:
            status = "passed"

        for code in _short_codes(c):
            tagged_cases.append({
                "short_code": code,
                "status": status,
                "name": c.attrib.get("name", ""),
                "duration_ms": case_ms,
            })

    passed = total - failed - skipped - flaky
    if passed < 0:
        # Defensive: if a junit emitter double-counts (e.g. flaky + failure),
        # clamp so downstream consumers don't see negative arithmetic.
        passed = 0

    return {
        "total": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "flaky": flaky,
        "duration_ms": duration_ms,
        "tagged_cases": tagged_cases,
    }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("junit_path", help="Path to a JUnit XML file.")
    args = p.parse_args()

    try:
        result = aggregate(args.junit_path)
    except FileNotFoundError:
        print(f"parse-junit: file not found: {args.junit_path}", file=sys.stderr)
        return 2
    except ET.ParseError as e:
        print(f"parse-junit: malformed XML in {args.junit_path}: {e}", file=sys.stderr)
        return 3

    # Single-line JSON keeps it cheap to pipe into jq from shell.
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
