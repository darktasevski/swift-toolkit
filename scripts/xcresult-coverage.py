#!/usr/bin/env python3
"""Classify how an xcresult bundle covered each requested `-only-testing` identifier.

xcodebuild exits 0 when every selected test skipped, and when an identifier matched nothing, so
its status alone cannot say whether a scoped run proved anything. This reads the two documents

    xcrun xcresulttool get test-results summary --path <bundle>
    xcrun xcresulttool get test-results tests --path <bundle>

and reports facts only: the run's counts, and for each identifier whether it selected a test that
ran (`executed`), selected only skipped tests (`skipped-only`), or selected nothing (`unmatched`).
The caller owns the verdict. Loaded directly by the app repository's test runners as well, so the
matching rules have one implementation.

Usage:  xcresult-coverage.py --summary FILE [--tests FILE] [IDENTIFIER ...]
        --tests is required when any identifier is given.
Output: one JSON object: {"totals": {...}, "testCaseCount": N, "identifiers": [{"identifier",
        "class", "skipped"}], "outcome": ...}. `outcome` is the one closed verdict input every
        runner maps to an exit; see OUTCOMES.
Exit:   0 classified; 2 an input, or any count, is unreadable (nothing printed); 64 usage error.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass

# Far above any suite either repository runs, and small enough that every count and every sum or
# difference of two stays inside the signed 64-bit range bash's `[` and `$(( ))` compare in.
MAX_COUNT = 10**9

COUNT_FIELDS = ("totalTestCount", "passedTests", "failedTests", "skippedTests")

# The bundle level xcresult reports test cases under. A test case's own `nodeIdentifier` is
# suite-relative (`FooTests/testBar()`), so the bundle name is carried down from its ancestor to
# reconstruct what `-only-testing:` accepts.
BUNDLE_NODE_TYPES = {"Unit test bundle", "UI test bundle"}

# The closed set `outcome` takes. Precedence lives in `outcome_of` alone, so the runners that map
# these to exits cannot disagree about which wins.
OUTCOMES = ("proven", "unmatched", "skipped-only", "nothing-unskipped", "empty", "inconsistent")


class Unreadable(Exception):
    """An input, or a count in it, is not in the shape xcresulttool documents."""


@dataclass(frozen=True)
class TestCase:
    swift_testing: bool
    skipped: bool


def read_counts(summary: object) -> dict[str, int]:
    """The summary's counts. A missing count is unknown, never zero: read as zero it would report an empty run."""
    if not isinstance(summary, dict):
        raise Unreadable
    counts: dict[str, int] = {}
    for field in COUNT_FIELDS:
        count = summary.get(field)
        if type(count) is not int or not 0 <= count <= MAX_COUNT:
            raise Unreadable
        counts[field] = count
    return counts


def recorded_by_swift_testing(node: dict) -> bool:
    """Whether Swift Testing recorded a test-case node, read from its `nodeIdentifierURL`.

    `nodeIdentifier` cannot tell the frameworks apart: both record the signature there
    (`FooTests/testBar()`, `FooTests/checkThing(text:)`). The URL can — measured 2026-09-29, a
    Swift Testing function's keeps the signature
    (`test://com.apple.xcode/Main/MainTests/FooTests/checkThing(text:)`) while an XCTest method's
    drops the parentheses (`test://com.apple.xcode/Main/MainTests/FooTests/testBar`).

    Only that exact shape counts. No URL, or a URL ending in anything else, reads as NOT Swift
    Testing, which `selects` treats permissively: this guard fails open on a shape it cannot read.
    """
    identifier = node.get("nodeIdentifier")
    url = node.get("nodeIdentifierURL")
    return isinstance(identifier, str) and isinstance(url, str) and url.endswith("/" + identifier)


def test_cases(payload: object) -> dict[str, TestCase]:
    """Every test case in the tree, bundle-qualified. A case recorded more than once (test
    iterations) is skipped only when every occurrence skipped."""
    if not isinstance(payload, dict):
        raise Unreadable
    roots = payload.get("testNodes") or []
    if not isinstance(roots, list):
        raise Unreadable
    found: dict[str, TestCase] = {}

    def walk(node: object, bundle: str | None) -> None:
        if not isinstance(node, dict):
            raise Unreadable
        node_type = node.get("nodeType")
        if node_type in BUNDLE_NODE_TYPES:
            bundle = node.get("name") or bundle
        if node_type == "Test Case":
            identifier = node.get("nodeIdentifier")
            if isinstance(identifier, str) and identifier:
                key = f"{bundle}/{identifier}" if bundle else identifier
                skipped = node.get("result") == "Skipped"
                if key in found:
                    skipped = skipped and found[key].skipped
                found[key] = TestCase(swift_testing=recorded_by_swift_testing(node), skipped=skipped)
        children = node.get("children") or []
        if not isinstance(children, list):
            raise Unreadable
        for child in children:
            walk(child, bundle)

    for root in roots:
        walk(root, None)
    return found


def executed_identifiers(payload: object) -> dict[str, bool]:
    """Every recorded test case mapped to `recorded_by_swift_testing`, skipped ones included: the
    app repository's guard reports an identifier that matched nothing, and a skip did match."""
    return {identifier: case.swift_testing for identifier, case in test_cases(payload).items()}


def selects(candidate: str, identifier: str, swift_testing: bool) -> bool:
    """Whether xcodebuild's `-only-testing:<candidate>` selects the executed test `identifier`.

    A bundle or suite identifier selects every test under it, in either framework — a nested
    Swift Testing suite included (`Outer/Inner`). A METHOD identifier's accepted spellings differ
    by framework — measured 2026-09-29 through test-ios.sh, one identifier per run:

    | Spelling           | XCTest `testBar()` | Swift Testing `check()` | Parameterized `check(text:)` |
    | ------------------ | ------------------ | ----------------------- | ---------------------------- |
    | `testBar`/`check`  | selects it         | selects nothing         | selects nothing              |
    | `…()`              | selects it         | selects it              | selects nothing              |
    | `…(text:)`         | —                  | —                       | selects it                   |
    | `…(foo:)`          | —                  | —                       | selects nothing              |

    So a Swift Testing function is selected only by the exact signature the bundle records. A
    spelling that selects nothing leaves no trace in the tree, so the node a bare Swift Testing
    name points at is present only when another identifier in the same run selected that test.
    Accepting the bare name there would pass an identifier that does not work — harmless in that
    run, and a zero-test selection once the identifier that did the work is dropped.

    Every other node also answers to its bare name. For an XCTest method, whose only signature is
    `()`, that is the measured rule; for a node this guard cannot read, it is the fail-open one,
    since not knowing which rule applies is not evidence of a typo. Neither accepts `()` against a
    labelled signature, which only Swift Testing records.
    """
    if identifier == candidate or identifier.startswith(candidate + "/"):
        return True
    return not swift_testing and identifier.startswith(candidate + "(")


def matches(requested: str, executed: dict[str, bool]) -> bool:
    """Whether `requested` selected at least one of `executed`."""
    candidate = requested.rstrip("/")
    if not candidate:
        return False
    return any(selects(candidate, identifier, swift_testing) for identifier, swift_testing in executed.items())


def outcome_of(report: dict, scoped: bool) -> str:
    """The run's verdict input. Scoped: a tree with no case is `empty` when the summary agrees
    nothing ran and `inconsistent` when it does not; otherwise an unmatched identifier outranks a
    skipped-only one, since a rerun cannot clear a typo. Unscoped: nothing that did not skip is
    `nothing-unskipped`."""
    totals = report["totals"]
    if scoped:
        if report["testCaseCount"] == 0:
            return "empty" if totals["totalTestCount"] == 0 else "inconsistent"
        classes = {entry["class"] for entry in report["identifiers"]}
        if "unmatched" in classes:
            return "unmatched"
        if "skipped-only" in classes:
            return "skipped-only"
        return "proven"
    if totals["totalTestCount"] - totals["skippedTests"] <= 0:
        return "nothing-unskipped"
    return "proven"


def classify(summary_text: str | bytes, tests_text: str | bytes | None, requested: list[str]) -> dict:
    """The report `main` prints. Raises `Unreadable`; `tests_text` may be None only when nothing was requested."""
    try:
        summary = json.loads(summary_text)
        payload = None if tests_text is None else json.loads(tests_text)
    except (ValueError, RecursionError) as error:
        raise Unreadable from error
    report: dict = {"totals": read_counts(summary), "testCaseCount": 0, "identifiers": []}
    if not requested:
        report["outcome"] = outcome_of(report, scoped=False)
        return report
    cases = test_cases(payload)
    report["testCaseCount"] = len(cases)
    for identifier in requested:
        candidate = identifier.rstrip("/")
        selected = [name for name, case in cases.items() if candidate and selects(candidate, name, case.swift_testing)]
        skipped = sorted(name for name in selected if cases[name].skipped)
        if not selected:
            kind = "unmatched"
        elif len(skipped) == len(selected):
            kind = "skipped-only"
        else:
            kind = "executed"
        report["identifiers"].append({"identifier": identifier, "class": kind, "skipped": skipped})
    report["outcome"] = outcome_of(report, scoped=True)
    return report


def main(argv: list[str]) -> int:
    arguments = argv[1:]
    paths: dict[str, str] = {}
    requested: list[str] = []
    while arguments:
        argument = arguments.pop(0)
        if argument in ("--summary", "--tests"):
            if not arguments:
                print(__doc__.strip().splitlines()[0], file=sys.stderr)
                return 64
            paths[argument] = arguments.pop(0)
        else:
            requested.append(argument)
    if "--summary" not in paths or (requested and "--tests" not in paths):
        print("usage: xcresult-coverage.py --summary FILE [--tests FILE] [IDENTIFIER ...]", file=sys.stderr)
        return 64
    try:
        # Bytes, not text: `json.loads` decodes them itself, so a byte that is not UTF-8 is refused
        # as unreadable instead of the read failing before it.
        with open(paths["--summary"], "rb") as summary_file:
            summary_text = summary_file.read()
        tests_text = None
        if "--tests" in paths:
            with open(paths["--tests"], "rb") as tests_file:
                tests_text = tests_file.read()
        report = classify(summary_text, tests_text, requested)
    except (OSError, Unreadable):
        return 2
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
