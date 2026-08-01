#!/usr/bin/env bash
# Self-test for scripts/test.sh. Uses PATH-local xcodebuild/xcbeautify fakes so
# the runner's pipeline contract is exercised without starting a simulator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPT_DIR/test.sh"
TEST_PLAN="$REPO_ROOT/TestApp/TestApp.xctestplan"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

scratch_candidate="$(mktemp -d "${TMPDIR:-/tmp}/readium-test-runner-self-test.XXXXXX")"
[[ -d "$scratch_candidate" ]] || fail "mktemp did not create a directory"
SCRATCH="$(cd "$scratch_candidate" && pwd -P)"
[[ -n "$SCRATCH" && "$SCRATCH" != "/" && -d "$SCRATCH" ]] ||
	fail "refusing unsafe scratch directory: $SCRATCH"

cleanup() {
	if [[ -n "$SCRATCH" && "$SCRATCH" != "/" && -d "$SCRATCH" ]]; then
		rm -rf -- "$SCRATCH"
	fi
}
trap cleanup EXIT

FAKE_BIN="$SCRATCH/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_XCODEBUILD_STREAM:-stdout}" == stderr ]]; then
    printf '%s\n' "${FAKE_XCODEBUILD_OUTPUT:?missing fake output}" >&2
else
    printf '%s\n' "${FAKE_XCODEBUILD_OUTPUT:?missing fake output}"
fi
exit "${FAKE_XCODEBUILD_STATUS:?missing fake status}"
EOF

cat >"$FAKE_BIN/xcbeautify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat
exit "${FAKE_XCBEAUTIFY_STATUS:-0}"
EOF

cat >"$FAKE_BIN/grep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_GREP_STATUS:-}" ]]; then
    exit "$FAKE_GREP_STATUS"
fi
exec /usr/bin/grep "$@"
EOF

chmod +x "$FAKE_BIN/xcodebuild" "$FAKE_BIN/xcbeautify" "$FAKE_BIN/grep"

run_runner_case() {
	local name="$1"
	local expected_exit="$2"
	local xcodebuild_exit="$3"
	local xcodebuild_output="$4"
	local xcodebuild_stream="$5"
	local xcbeautify_exit="$6"
	local grep_exit="${7:-}"
	local actual_exit=0
	local output="$SCRATCH/$name.out"

	if PATH="$FAKE_BIN:$PATH" \
		FAKE_XCODEBUILD_STATUS="$xcodebuild_exit" \
		FAKE_XCODEBUILD_OUTPUT="$xcodebuild_output" \
		FAKE_XCODEBUILD_STREAM="$xcodebuild_stream" \
		FAKE_XCBEAUTIFY_STATUS="$xcbeautify_exit" \
		FAKE_GREP_STATUS="$grep_exit" \
		"$RUNNER" >"$output" 2>&1; then
		actual_exit=0
	else
		actual_exit=$?
	fi

	if [[ "$actual_exit" -ne "$expected_exit" ]]; then
		cat "$output" >&2
		fail "$name — expected exit=$expected_exit, got $actual_exit"
	fi
	echo "  PASS: $name"
}

# Case A: downstream tools succeed, but xcodebuild's nonzero status remains authoritative.
run_runner_case "xcodebuild stderr and failure survive pipeline" 73 73 "visible failure" stderr 0
grep -q "visible failure" "$SCRATCH/xcodebuild stderr and failure survive pipeline.out" ||
	fail "xcodebuild stderr was discarded"

# Case B: grep filters every successful-run line and exits 1; xcodebuild's zero still wins.
run_runner_case "empty filtered output preserves success" 0 0 "Executed 1 test, with 0 failures" stdout 0

# Case C: formatter and filter errors are infrastructure failures, not green tests.
run_runner_case "xcbeautify failure survives pipeline" 44 0 "build output" stdout 44
run_runner_case "grep error survives pipeline" 45 0 "build output" stdout 0 45

# Case D: the unfiltered TestApp plan structurally includes ReadiumSharedTests.
if ! grep -Eq '"identifier"[[:space:]]*:[[:space:]]*"ReadiumSharedTests"' "$TEST_PLAN"; then
	fail "TestApp/TestApp.xctestplan omits ReadiumSharedTests"
fi
echo "  PASS: TestApp plan includes ReadiumSharedTests"

# The parent pins fork-extensions directly, so pushes to that branch must run
# this self-test rather than relying on a future PR into main/develop.
grep -Fq 'branches: [ main, develop, fork-extensions ]' "$REPO_ROOT/.github/workflows/checks.yml" ||
	fail "Checks workflow does not run for fork-extensions pushes"
echo "  PASS: fork-extensions pushes run Checks"

echo "OK: all test.sh self-tests passed"
