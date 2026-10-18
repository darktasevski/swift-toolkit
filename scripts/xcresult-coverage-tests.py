#!/usr/bin/env python3
"""Unit tests for scripts/xcresult-coverage.py."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

# Load the subject from source every time, never from `__pycache__`: cached bytecode is keyed on
# mtime-to-the-second and size, so a same-length mutation restored inside one second would re-run
# the stale bytecode and a mutation check would stay green on a live mutant.
sys.dont_write_bytecode = True

SUBJECT = Path(__file__).resolve().parent / "xcresult-coverage.py"
SPEC = importlib.util.spec_from_file_location("xcresult_coverage", SUBJECT)
assert SPEC and SPEC.loader
mod = importlib.util.module_from_spec(SPEC)
sys.modules["xcresult_coverage"] = mod
SPEC.loader.exec_module(mod)


def summary(total: int, passed: int, failed: int, skipped: int) -> dict:
    return {"totalTestCount": total, "passedTests": passed, "failedTests": failed, "skippedTests": skipped}


def xctest(identifier: str, result: str = "Passed", bundle: str = "ReadiumNavigatorTests") -> dict:
    """An XCTest method as a real bundle records it: the URL drops the `()` the identifier keeps."""
    return {
        "nodeType": "Test Case",
        "name": identifier.split("/")[-1],
        "nodeIdentifier": identifier,
        "nodeIdentifierURL": f"test://com.apple.xcode/TestApp/{bundle}/{identifier.removesuffix('()')}",
        "result": result,
    }


def swift_testing(identifier: str, result: str = "Passed", bundle: str = "ReadiumNavigatorTests") -> dict:
    """A Swift Testing function as a real bundle records it: the URL keeps the whole signature."""
    return {
        "nodeType": "Test Case",
        "name": "a display name",
        "nodeIdentifier": identifier,
        "nodeIdentifierURL": f"test://com.apple.xcode/TestApp/{bundle}/{identifier}",
        "result": result,
    }


def tree(*bundles: tuple[str, list[dict]]) -> dict:
    return {
        "testNodes": [
            {
                "name": "TestApp",
                "nodeType": "Test Plan",
                "children": [
                    {"name": name, "nodeType": "Unit test bundle", "children": cases} for name, cases in bundles
                ],
            }
        ]
    }


def classify(totals: dict, payload: dict | None, *requested: str) -> dict:
    return mod.classify(json.dumps(totals), None if payload is None else json.dumps(payload), list(requested))


def classes(report: dict) -> dict[str, str]:
    return {entry["identifier"]: entry["class"] for entry in report["identifiers"]}


class ReadCountsTests(unittest.TestCase):
    def test_bounded_integers_are_read(self) -> None:
        self.assertEqual(
            mod.read_counts(summary(3, 2, 0, 1)),
            {"totalTestCount": 3, "passedTests": 2, "failedTests": 0, "skippedTests": 1},
        )

    def test_a_count_that_is_not_a_bounded_integer_is_unreadable(self) -> None:
        for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests"):
            for hostile in (True, -1, 1.0, "1", None, mod.MAX_COUNT + 1):
                with self.subTest(field=field, hostile=hostile):
                    counts = summary(1, 1, 0, 0)
                    counts[field] = hostile
                    with self.assertRaises(mod.Unreadable):
                        mod.read_counts(counts)

    def test_a_missing_count_is_unreadable_never_zero(self) -> None:
        counts = summary(1, 1, 0, 0)
        del counts["skippedTests"]
        with self.assertRaises(mod.Unreadable):
            mod.read_counts(counts)

    def test_a_summary_that_is_not_an_object_is_unreadable(self) -> None:
        for payload in ([], None, 5, "text"):
            with self.subTest(payload=payload), self.assertRaises(mod.Unreadable):
                mod.read_counts(payload)


class TestCasesTests(unittest.TestCase):
    def test_cases_are_bundle_qualified_and_carry_skip_and_framework(self) -> None:
        cases = mod.test_cases(
            tree(("ReadiumNavigatorTests", [xctest("FooTests/testBar()", "Skipped"), swift_testing("Suite/check()")]))
        )
        self.assertEqual(
            cases,
            {
                "ReadiumNavigatorTests/FooTests/testBar()": mod.TestCase(swift_testing=False, skipped=True),
                "ReadiumNavigatorTests/Suite/check()": mod.TestCase(swift_testing=True, skipped=False),
            },
        )

    def test_a_repeated_case_is_skipped_only_when_every_occurrence_skipped(self) -> None:
        cases = mod.test_cases(
            tree(("ReadiumNavigatorTests", [xctest("FooTests/testBar()"), xctest("FooTests/testBar()", "Skipped")]))
        )
        # Passed first: keeping only the last occurrence would read the case as skipped.
        self.assertFalse(cases["ReadiumNavigatorTests/FooTests/testBar()"].skipped)

    def test_malformed_shapes_are_unreadable(self) -> None:
        for payload in ([], None, 123, "s", {"testNodes": [None]}, {"testNodes": {"a": 1}}, {"testNodes": 5},
                        {"testNodes": [{"children": 5}]}):
            with self.subTest(payload=payload), self.assertRaises(mod.Unreadable):
                mod.test_cases(payload)

    def test_executed_identifiers_projects_the_framework_and_keeps_skips(self) -> None:
        payload = tree(("ReadiumNavigatorTests", [xctest("FooTests/testBar()", "Skipped")]))
        self.assertEqual(mod.executed_identifiers(payload), {"ReadiumNavigatorTests/FooTests/testBar()": False})


class SpellingTests(unittest.TestCase):
    """xcodebuild's measured selection rules (2026-09-29), one row of the `selects` table each."""

    def test_xctest_method_answers_to_its_bare_name_and_to_parentheses(self) -> None:
        self.assertTrue(mod.selects("B/FooTests/testBar", "B/FooTests/testBar()", False))
        self.assertTrue(mod.selects("B/FooTests/testBar()", "B/FooTests/testBar()", False))

    def test_swift_testing_function_answers_only_to_its_signature(self) -> None:
        self.assertFalse(mod.selects("B/Suite/check", "B/Suite/check()", True))
        self.assertTrue(mod.selects("B/Suite/check()", "B/Suite/check()", True))
        self.assertFalse(mod.selects("B/Suite/check()", "B/Suite/check(text:)", True))
        self.assertTrue(mod.selects("B/Suite/check(text:)", "B/Suite/check(text:)", True))

    def test_suite_and_bundle_prefixes_select_on_a_path_boundary_only(self) -> None:
        self.assertTrue(mod.selects("B", "B/FooTests/testBar()", False))
        self.assertTrue(mod.selects("B/FooTests", "B/FooTests/testBar()", False))
        self.assertFalse(mod.selects("B/Foo", "B/FooTests/testBar()", False))


class ClassifyTests(unittest.TestCase):
    def test_every_selected_test_skipped_is_skipped_only_and_names_them(self) -> None:
        report = classify(
            summary(2, 0, 0, 2),
            tree(("ReadiumNavigatorTests", [xctest("OutcomeTests/testOne()", "Skipped"),
                                             xctest("OutcomeTests/testTwo()", "Skipped")])),
            "ReadiumNavigatorTests/OutcomeTests",
        )
        self.assertEqual(classes(report), {"ReadiumNavigatorTests/OutcomeTests": "skipped-only"})
        self.assertEqual(
            report["identifiers"][0]["skipped"],
            ["ReadiumNavigatorTests/OutcomeTests/testOne()", "ReadiumNavigatorTests/OutcomeTests/testTwo()"],
        )

    def test_a_passing_warm_up_does_not_cover_a_skipped_target(self) -> None:
        report = classify(
            summary(2, 1, 0, 1),
            tree(("ReadiumNavigatorTests", [xctest("WarmUpTests/testWarm()"), xctest("OutcomeTests/testTarget()", "Skipped")])),
            "ReadiumNavigatorTests/WarmUpTests",
            "ReadiumNavigatorTests/OutcomeTests/testTarget",
        )
        self.assertEqual(
            classes(report),
            {"ReadiumNavigatorTests/WarmUpTests": "executed", "ReadiumNavigatorTests/OutcomeTests/testTarget": "skipped-only"},
        )

    def test_one_executed_test_beside_skips_is_executed(self) -> None:
        report = classify(
            summary(2, 1, 0, 1),
            tree(("ReadiumNavigatorTests", [xctest("OutcomeTests/testOne()"), xctest("OutcomeTests/testTwo()", "Skipped")])),
            "ReadiumNavigatorTests/OutcomeTests",
        )
        self.assertEqual(classes(report), {"ReadiumNavigatorTests/OutcomeTests": "executed"})
        self.assertEqual(report["identifiers"][0]["skipped"], ["ReadiumNavigatorTests/OutcomeTests/testTwo()"])

    def test_failed_and_expected_failure_count_as_executed(self) -> None:
        for result in ("Failed", "Expected Failure"):
            with self.subTest(result=result):
                report = classify(summary(1, 0, 1, 0), tree(("B", [xctest("T/testX()", result, "B")])), "B/T")
                self.assertEqual(classes(report), {"B/T": "executed"})

    def test_an_identifier_that_selects_nothing_is_unmatched(self) -> None:
        report = classify(summary(1, 1, 0, 0), tree(("B", [xctest("T/testX()", bundle="B")])), "B/Typo", "/")
        self.assertEqual(classes(report), {"B/Typo": "unmatched", "/": "unmatched"})

    def test_a_trailing_slash_is_the_same_identifier(self) -> None:
        report = classify(summary(1, 1, 0, 0), tree(("B", [xctest("T/testX()", bundle="B")])), "B/T/")
        self.assertEqual(classes(report), {"B/T/": "executed"})

    def test_an_unscoped_run_reads_the_summary_alone(self) -> None:
        report = classify(summary(4, 3, 0, 1), None)
        self.assertEqual(report["identifiers"], [])
        self.assertEqual(report["totals"]["skippedTests"], 1)
        self.assertEqual(report["testCaseCount"], 0)

    def test_a_scoped_run_without_a_tree_is_unreadable(self) -> None:
        with self.assertRaises(mod.Unreadable):
            classify(summary(1, 1, 0, 0), None, "B/T")

    def test_invalid_json_is_unreadable(self) -> None:
        with self.assertRaises(mod.Unreadable):
            mod.classify("not json", None, [])
        with self.assertRaises(mod.Unreadable):
            mod.classify(json.dumps(summary(1, 1, 0, 0)), "not json", ["B/T"])


class OutcomeTests(unittest.TestCase):
    """The one closed verdict input every runner maps; its precedence lives here and nowhere else."""

    def outcome(self, totals: dict, payload: dict | None, *requested: str) -> str:
        return classify(totals, payload, *requested)["outcome"]

    def test_a_scoped_run_whose_identifiers_each_ran_something_is_proven(self) -> None:
        payload = tree(("B", [xctest("T/testX()", bundle="B"), xctest("T/testY()", "Skipped", "B")]))
        self.assertEqual(self.outcome(summary(2, 1, 0, 1), payload, "B/T"), "proven")

    def test_an_unmatched_identifier_outranks_a_skipped_only_one(self) -> None:
        payload = tree(("B", [xctest("T/testX()", "Skipped", "B")]))
        self.assertEqual(self.outcome(summary(1, 0, 0, 1), payload, "B/T", "B/Typo"), "unmatched")

    def test_a_skipped_only_identifier_is_not_proven(self) -> None:
        payload = tree(("B", [xctest("T/testX()", "Skipped", "B")]))
        self.assertEqual(self.outcome(summary(1, 0, 0, 1), payload, "B/T"), "skipped-only")

    def test_a_scoped_run_with_no_case_and_a_zero_total_is_empty(self) -> None:
        self.assertEqual(self.outcome(summary(0, 0, 0, 0), {"testNodes": []}, "B/T"), "empty")

    def test_a_scoped_run_with_no_case_but_a_positive_total_is_inconsistent(self) -> None:
        self.assertEqual(self.outcome(summary(3, 3, 0, 0), {"testNodes": []}, "B/T"), "inconsistent")

    def test_an_unscoped_run_with_nothing_unskipped_is_not_proven(self) -> None:
        self.assertEqual(self.outcome(summary(2, 0, 0, 2), None), "nothing-unskipped")
        self.assertEqual(self.outcome(summary(0, 0, 0, 0), None), "nothing-unskipped")

    def test_an_unscoped_run_with_one_unskipped_test_is_proven(self) -> None:
        self.assertEqual(self.outcome(summary(2, 1, 0, 1), None), "proven")


class MainTests(unittest.TestCase):
    def run_main(self, *args: str, summary_text: str | None = None, tests_text: str | None = None) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as directory:
            argv = ["prog"]
            if summary_text is not None:
                Path(directory, "summary.json").write_text(summary_text)
                argv += ["--summary", str(Path(directory, "summary.json"))]
            if tests_text is not None:
                Path(directory, "tests.json").write_text(tests_text)
                argv += ["--tests", str(Path(directory, "tests.json"))]
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                status = mod.main(argv + list(args))
        return status, buffer.getvalue()

    def test_a_classified_run_prints_one_json_object(self) -> None:
        status, out = self.run_main(
            "B/T",
            summary_text=json.dumps(summary(1, 1, 0, 0)),
            tests_text=json.dumps(tree(("B", [xctest("T/testX()", bundle="B")]))),
        )
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out)["identifiers"][0]["class"], "executed")

    def test_unreadable_input_exits_two_and_prints_nothing(self) -> None:
        status, out = self.run_main(summary_text="not json")
        self.assertEqual((status, out), (2, ""))

    def test_a_missing_file_exits_two(self) -> None:
        status, out = self.run_main("--summary", "/nonexistent/summary.json")
        self.assertEqual((status, out), (2, ""))

    def test_usage_errors_exit_sixty_four(self) -> None:
        self.assertEqual(self.run_main()[0], 64)
        self.assertEqual(self.run_main("B/T", summary_text=json.dumps(summary(1, 1, 0, 0)))[0], 64)
        self.assertEqual(self.run_main("--summary")[0], 64)


if __name__ == "__main__":
    unittest.main(verbosity=2)
