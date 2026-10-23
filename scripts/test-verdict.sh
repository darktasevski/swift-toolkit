#!/usr/bin/env bash
# Sourced by scripts/test.sh, never executed. Turns xcodebuild's status and the result bundle into
# the runner's verdict, because xcodebuild exits 0 when every selected test skipped and when an
# -only-testing identifier matched nothing (#3679). First match wins:
#   xcodebuild's non-zero status;
#   75 (EX_TEMPFAIL) when the bundle's counts or coverage cannot be read, or disagree;
#   1 when an identifier selected no test;
#   75 when every test an identifier selected skipped, or an unscoped run executed nothing that
#      did not skip;
#   0 otherwise.
# The precedence is scripts/xcresult-coverage.py's `outcome`; this file maps it and renders.
# Reads the caller's SCRIPT_DIR.

READIUM_VERDICT_BUNDLE=""
READIUM_VERDICT_TEMP_DIR=""
READIUM_VERDICT_WORK=""

# An interrupted or aborted run never reaches readium_verdict_finish, so its scratch and its
# temporary bundle would otherwise stay behind with no message.
readium_verdict_abandon() {
	[[ -z "$READIUM_VERDICT_WORK" ]] || rm -rf "$READIUM_VERDICT_WORK"
	[[ -z "$READIUM_VERDICT_TEMP_DIR" ]] || rm -rf "$READIUM_VERDICT_TEMP_DIR"
}

# readium_verdict_prepare_bundle <the caller's bundle path, or empty>: sets READIUM_VERDICT_BUNDLE.
readium_verdict_prepare_bundle() {
	# A signal becomes an exit so the EXIT trap runs; bash runs no EXIT trap for an untrapped one.
	trap readium_verdict_abandon EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	if [[ -n "$1" ]]; then
		READIUM_VERDICT_BUNDLE="$1"
		# xcodebuild refuses to overwrite an existing bundle.
		rm -rf "$READIUM_VERDICT_BUNDLE"
	else
		# A kept bundle is evidence for an hour, as the app's runners keep theirs; nothing else
		# sweeps this prefix, and the fork runs without the app repository.
		find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'readium-test.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
		READIUM_VERDICT_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/readium-test.XXXXXX")"
		READIUM_VERDICT_BUNDLE="$READIUM_VERDICT_TEMP_DIR/run.xcresult"
	fi
}

# readium_verdict_finish <pipeline status> [identifier...]: prints the counts and the verdict, and exits.
readium_verdict_finish() {
	local pipeline_status="$1"
	shift
	local verdict=0
	READIUM_VERDICT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/readium-verdict.XXXXXX")"
	local work="$READIUM_VERDICT_WORK"
	local -a classify=(python3 -I "$SCRIPT_DIR/xcresult-coverage.py" --summary "$work/summary.json")
	[[ $# -eq 0 ]] || classify+=(--tests "$work/tests.json")

	if xcrun xcresulttool get test-results summary --path "$READIUM_VERDICT_BUNDLE" >"$work/summary.json" 2>/dev/null &&
		{ [[ $# -eq 0 ]] || xcrun xcresulttool get test-results tests --path "$READIUM_VERDICT_BUNDLE" >"$work/tests.json" 2>/dev/null; } &&
		"${classify[@]}" "$@" >"$work/coverage.json" 2>/dev/null; then
		# -I: a module planted in the working directory must not shadow `json` or `sys`.
		python3 -I - "$work/coverage.json" <<'PY' || verdict=$?
import json
import sys

SHOWN = 20
EXITS = {"proven": 0, "unmatched": 1, "empty": 1, "skipped-only": 75, "nothing-unskipped": 75, "inconsistent": 75}

try:
    with open(sys.argv[1]) as coverage:
        report = json.load(coverage)
    totals = report["totals"]
    outcome = report["outcome"]
    print(
        f"Executed {totals['totalTestCount'] - totals['skippedTests']} — passed {totals['passedTests']}, "
        f"failed {totals['failedTests']}, skipped {totals['skippedTests']}"
    )
    # An empty tree beside a positive total classes every identifier unmatched; the evidence
    # disagrees, so no identifier is to blame.
    if outcome == "inconsistent":
        print("NOT PROVEN: the summary counts tests the test tree does not hold.")
        sys.exit(EXITS[outcome])
    for entry in report["identifiers"]:
        if entry["class"] == "skipped-only":
            print(f"NOT PROVEN: {entry['identifier']} — every test it selected skipped:")
            for name in entry["skipped"][:SHOWN]:
                print(f"  • {name}")
            if len(entry["skipped"]) > SHOWN:
                print(f"  … and {len(entry['skipped']) - SHOWN} more")
    for entry in report["identifiers"]:
        if entry["class"] == "unmatched":
            print(f"NO MATCH: {entry['identifier']} selected no test.")
    if outcome in ("unmatched", "empty"):
        print("  -only-testing takes the declared type name and never a partial one; a Swift Testing")
        print("  function takes its full signature: Type/function(), or Type/function(label:).")
    elif outcome == "nothing-unskipped":
        print("NOT PROVEN: the run executed no test that did not skip.")
    sys.exit(EXITS[outcome])
except Exception:  # noqa: BLE001 — a fault here is "could not tell", never "matched nothing"
    print("Could not render the coverage report, so this run proves nothing.")
    sys.exit(75)
PY
	else
		echo "Could not read the result bundle's counts or coverage, so this run proves nothing."
		verdict=75
	fi
	rm -rf "$work"
	READIUM_VERDICT_WORK=""
	[[ "$pipeline_status" -eq 0 ]] || verdict="$pipeline_status"

	# Only the classifier can attest uncertainty; a pipeline failure with the
	# same numeric status must remain a failure to callers.
	if [[ "$pipeline_status" -eq 0 && "$verdict" -eq 75 ]]; then
		if [[ -n "${TEST_RUNNER_UNPROVEN_REPORT:-}" ]]; then
			printf '%s\0' UNPROVEN "$READIUM_VERDICT_BUNDLE" >"$TEST_RUNNER_UNPROVEN_REPORT" || exit 74
		fi
		echo "VERDICT: NOT PROVEN (exit 75) — a skipped or unread selection is not a pass."
	else
		case "$verdict" in
		0) echo "VERDICT: PASSED" ;;
		*) echo "VERDICT: FAILED (exit $verdict)" ;;
		esac
	fi
	if [[ -n "$READIUM_VERDICT_TEMP_DIR" ]]; then
		if [[ "$verdict" -eq 0 ]]; then
			rm -rf "$READIUM_VERDICT_TEMP_DIR"
		else
			# The prune reads this directory's mtime, which stops moving once run.xcresult exists.
			touch "$READIUM_VERDICT_TEMP_DIR"
			echo "Result bundle kept: $READIUM_VERDICT_BUNDLE (deleted by the next run after an hour)"
		fi
		READIUM_VERDICT_TEMP_DIR=""
	fi
	trap - EXIT INT TERM
	exit "$verdict"
}
