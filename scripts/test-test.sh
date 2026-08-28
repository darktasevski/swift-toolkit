#!/usr/bin/env bash
# Self-test for scripts/test.sh. Uses PATH-local xcodebuild/xcbeautify fakes so
# the runner's pipeline contract is exercised without starting a simulator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPT_DIR/test.sh"
TEST_PLAN="$REPO_ROOT/TestApp/Integrations/Local/TestApp.xctestplan"

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
if [[ -n "${FAKE_XCODEBUILD_ARGS:-}" ]]; then
	printf '%s\n' "$@" >"$FAKE_XCODEBUILD_ARGS"
fi
if [[ "${FAKE_XCODEBUILD_STREAM:-stdout}" == stderr ]]; then
    printf '%s\n' "${FAKE_XCODEBUILD_OUTPUT:?missing fake output}" >&2
else
    printf '%s\n' "${FAKE_XCODEBUILD_OUTPUT:?missing fake output}"
fi
exit "${FAKE_XCODEBUILD_STATUS:?missing fake status}"
EOF

cat >"$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_XCRUN_LOG:?missing fake xcrun log}"

if [[ "$*" == "simctl list devices available -j" ]]; then
	if [[ -n "${FAKE_SIMCTL_DEVICES_JSON:-}" ]]; then
		printf '%s\n' "$FAKE_SIMCTL_DEVICES_JSON"
	else
		printf '%s\n' '{"devices":{}}'
	fi
	exit 0
fi
if [[ "${1:-}" == simctl && "${2:-}" == create ]]; then
	printf '%s\n' "${FAKE_CREATED_UDID:-11111111-2222-3333-4444-555555555555}"
	exit 0
fi
if [[ "${1:-}" == simctl && "${2:-}" == delete ]]; then
	exit 0
fi

echo "unexpected fake xcrun invocation: $*" >&2
exit 97
EOF

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
*"rev-parse --show-superproject-working-tree")
	printf '%s\n' "${FAKE_SUPERPROJECT_ROOT:-}"
	;;
*"rev-parse --path-format=absolute --git-common-dir")
	printf '%s\n' "${FAKE_GIT_COMMON_DIR:-/tmp/readium-common.git}"
	;;
*"worktree list --porcelain")
	if [[ "${FAKE_GIT_WORKTREE_STATUS:-0}" -ne 0 ]]; then
		exit "$FAKE_GIT_WORKTREE_STATUS"
	fi
	printf 'worktree %s\n' "${FAKE_SUPERPROJECT_ROOT:-/tmp/readium-worktree}"
	;;
*)
	echo "unexpected fake git invocation: $*" >&2
	exit 96
	;;
esac
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
	cat >/dev/null
	exit "$FAKE_GREP_STATUS"
fi
exec /usr/bin/grep "$@"
EOF

chmod +x "$FAKE_BIN/xcodebuild" "$FAKE_BIN/xcbeautify" "$FAKE_BIN/grep" \
	"$FAKE_BIN/xcrun" "$FAKE_BIN/git"

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
		READIUM_TEST_DESTINATION="platform=iOS Simulator,id=OVERRIDE-UDID" \
		FAKE_XCODEBUILD_STATUS="$xcodebuild_exit" \
		FAKE_XCODEBUILD_OUTPUT="$xcodebuild_output" \
		FAKE_XCODEBUILD_STREAM="$xcodebuild_stream" \
		FAKE_XCODEBUILD_ARGS="$SCRATCH/$name.args" \
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

run_cli_case() {
	local name="$1"
	local expected_exit="$2"
	shift 2
	local actual_exit=0
	local output="$SCRATCH/$name.out"
	local args_log="$SCRATCH/$name.args"
	local xcrun_log="$SCRATCH/$name.xcrun"
	: >"$xcrun_log"

	local -a environment=(
		"PATH=$FAKE_BIN:$PATH"
		"FAKE_XCODEBUILD_STATUS=0"
		"FAKE_XCODEBUILD_OUTPUT=Test Succeeded"
		"FAKE_XCODEBUILD_STREAM=stdout"
		"FAKE_XCODEBUILD_ARGS=$args_log"
		"FAKE_XCRUN_LOG=$xcrun_log"
		"FAKE_SIMCTL_DEVICES_JSON=${CASE_SIMCTL_DEVICES_JSON:-}"
		"FAKE_CREATED_UDID=${CASE_CREATED_UDID:-11111111-2222-3333-4444-555555555555}"
		"FAKE_SUPERPROJECT_ROOT=${CASE_SUPERPROJECT_ROOT:-/tmp/reader-app-worktree-a}"
		"FAKE_GIT_COMMON_DIR=${CASE_GIT_COMMON_DIR:-/tmp/reader-app-common.git}"
		"FAKE_GIT_WORKTREE_STATUS=${CASE_GIT_WORKTREE_STATUS:-0}"
		"SIM_ISOLATION=${CASE_SIM_ISOLATION:-1}"
		"SIM_PRUNE_ORPHANS=0"
		"SIMULATOR_NAME=${CASE_SIMULATOR_NAME:-iPad (A16)}"
		"SIMULATOR_UDID=${CASE_SIMULATOR_UDID:-}"
		"CI=${CASE_CI:-false}"
	)
	if [[ -n "${CASE_READIUM_DESTINATION:-}" ]]; then
		environment+=("READIUM_TEST_DESTINATION=$CASE_READIUM_DESTINATION")
	fi

	if env -u READIUM_TEST_DESTINATION "${environment[@]}" "$RUNNER" "$@" >"$output" 2>&1; then
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

assert_arg_pair() {
	local args_file="$1"
	local flag="$2"
	local value="$3"
	awk -v flag="$flag" -v value="$value" \
		'previous == flag && $0 == value { found = 1 } { previous = $0 } END { exit !found }' \
		"$args_file" || {
		cat "$args_file" >&2
		fail "missing xcodebuild argument pair: $flag $value"
	}
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

# Case D: a direct local run creates and targets a per-worktree simulator by
# UDID. The dedicated name must vary with the owning worktree path even when
# the linked repository's common directory is shared.
unset CASE_READIUM_DESTINATION CASE_SIMULATOR_UDID CASE_SIMCTL_DEVICES_JSON
CASE_SUPERPROJECT_ROOT=/tmp/reader-app-worktree-a
run_cli_case "default creates dedicated simulator" 0
assert_arg_pair "$SCRATCH/default creates dedicated simulator.args" \
	-destination "platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555"
create_a="$(sed -n 's/^simctl create \(.*\) iPad (A16)$/\1/p' \
	"$SCRATCH/default creates dedicated simulator.xcrun")"
[[ "$create_a" =~ ^Readium-WT-[0-9a-f]{8}__[0-9a-f]{12}__iPad-A16$ ]] ||
	fail "default run did not create a width-bounded Readium-WT simulator: $create_a"

CASE_SUPERPROJECT_ROOT=/tmp/reader-app-worktree-b
run_cli_case "second worktree gets another simulator" 0
create_b="$(sed -n 's/^simctl create \(.*\) iPad (A16)$/\1/p' \
	"$SCRATCH/second worktree gets another simulator.xcrun")"
[[ -n "$create_b" && "$create_b" != "$create_a" ]] ||
	fail "dedicated simulator name did not vary by worktree"

CASE_SUPERPROJECT_ROOT=/tmp/reader-app-worktree-a
CASE_SIMCTL_DEVICES_JSON="{\"devices\":{\"runtime\":[{\"name\":\"$create_a\",\"udid\":\"99999999-8888-7777-6666-555555555555\",\"isAvailable\":true}]}}"
run_cli_case "existing dedicated simulator is reused" 0
assert_arg_pair "$SCRATCH/existing dedicated simulator is reused.args" \
	-destination "platform=iOS Simulator,id=99999999-8888-7777-6666-555555555555"
if grep -Fq 'simctl create' "$SCRATCH/existing dedicated simulator is reused.xcrun"; then
	fail "existing dedicated simulator was created again"
fi
unset CASE_SIMCTL_DEVICES_JSON

# Case E: every documented escape hatch bypasses dedicated creation.
CASE_READIUM_DESTINATION="platform=iOS Simulator,id=PARENT-OVERRIDE"
run_cli_case "parent destination override wins" 0
assert_arg_pair "$SCRATCH/parent destination override wins.args" \
	-destination "platform=iOS Simulator,id=PARENT-OVERRIDE"
[[ ! -s "$SCRATCH/parent destination override wins.xcrun" ]] ||
	fail "destination override unexpectedly invoked simctl"
unset CASE_READIUM_DESTINATION

CASE_SIMULATOR_UDID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
CASE_SIMCTL_DEVICES_JSON='{"devices":{"runtime":[{"name":"Explicit","udid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","isAvailable":true}]}}'
run_cli_case "explicit UDID wins" 0
assert_arg_pair "$SCRATCH/explicit UDID wins.args" \
	-destination "platform=iOS Simulator,id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
unset CASE_SIMULATOR_UDID CASE_SIMCTL_DEVICES_JSON

CASE_SIMULATOR_UDID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
run_cli_case "unknown explicit UDID fails" 1
[[ ! -s "$SCRATCH/unknown explicit UDID fails.args" ]] ||
	fail "unknown explicit UDID still invoked xcodebuild"
unset CASE_SIMULATOR_UDID

CASE_SIM_ISOLATION=0
run_cli_case "environment disables isolation" 0
assert_arg_pair "$SCRATCH/environment disables isolation.args" \
	-destination "platform=iOS Simulator,name=iPad (A16)"
unset CASE_SIM_ISOLATION

CASE_CI=true
run_cli_case "CI keeps shared simulator behavior" 0
assert_arg_pair "$SCRATCH/CI keeps shared simulator behavior.args" \
	-destination "platform=iOS Simulator,name=iPad (A16)"
unset CASE_CI

run_cli_case "device option disables isolation" 0 --device "iPhone 15"
assert_arg_pair "$SCRATCH/device option disables isolation.args" \
	-destination "platform=iOS Simulator,name=iPhone 15"

# Case F: scoped identifiers are repeatable, while the original positional
# target remains supported.
CASE_READIUM_DESTINATION="platform=iOS Simulator,id=SCOPE-UDID"
run_cli_case "repeatable scoped filters" 0 \
	--only-testing ReadiumNavigatorTests/First \
	--only-testing ReadiumSharedTests/Second
grep -Fxq -- '-only-testing:ReadiumNavigatorTests/First' \
	"$SCRATCH/repeatable scoped filters.args" || fail "first scoped filter was not forwarded"
grep -Fxq -- '-only-testing:ReadiumSharedTests/Second' \
	"$SCRATCH/repeatable scoped filters.args" || fail "second scoped filter was not forwarded"

run_cli_case "legacy positional filter" 0 ReadiumSharedTests
grep -Fxq -- '-only-testing:ReadiumSharedTests' \
	"$SCRATCH/legacy positional filter.args" || fail "legacy positional filter was not forwarded"

run_cli_case "missing device value fails before xcodebuild" 64 --device
[[ ! -s "$SCRATCH/missing device value fails before xcodebuild.args" ]] ||
	fail "missing --device value still invoked xcodebuild"
run_cli_case "missing only-testing value fails before xcodebuild" 64 --only-testing
[[ ! -s "$SCRATCH/missing only-testing value fails before xcodebuild.args" ]] ||
	fail "missing --only-testing value still invoked xcodebuild"
run_cli_case "unknown option fails before xcodebuild" 64 --bogus
[[ ! -s "$SCRATCH/unknown option fails before xcodebuild.args" ]] ||
	fail "unknown option still invoked xcodebuild"
unset CASE_READIUM_DESTINATION

# Case G: explicit cleanup preserves active worktrees and removes only the
# requested current or orphaned dedicated simulator.
CASE_SUPERPROJECT_ROOT=/tmp/reader-app-worktree-a
name_prefix="${create_a%%__*}__"
orphan_name="${name_prefix}deadbeefdead__iPad-A16"
CASE_SIMCTL_DEVICES_JSON="{\"devices\":{\"runtime\":[{\"name\":\"$create_a\",\"udid\":\"ACTIVE-UDID\",\"isAvailable\":true},{\"name\":\"$orphan_name\",\"udid\":\"ORPHAN-UDID\",\"isAvailable\":true}]}}"
run_cli_case "orphan prune preserves active simulator" 0 prune-simulators
grep -Fxq 'simctl delete ORPHAN-UDID' "$SCRATCH/orphan prune preserves active simulator.xcrun" ||
	fail "orphan simulator was not pruned"
if grep -Fq 'simctl delete ACTIVE-UDID' "$SCRATCH/orphan prune preserves active simulator.xcrun"; then
	fail "orphan prune deleted the active worktree simulator"
fi
[[ ! -s "$SCRATCH/orphan prune preserves active simulator.args" ]] ||
	fail "orphan prune unexpectedly invoked xcodebuild"

CASE_GIT_WORKTREE_STATUS=55
run_cli_case "orphan prune fails closed without worktree inventory" 1 prune-simulators
[[ ! -s "$SCRATCH/orphan prune fails closed without worktree inventory.xcrun" ]] ||
	fail "failed worktree inventory still reached simctl"
[[ ! -s "$SCRATCH/orphan prune fails closed without worktree inventory.args" ]] ||
	fail "failed worktree inventory unexpectedly invoked xcodebuild"
unset CASE_GIT_WORKTREE_STATUS

run_cli_case "current simulator prune" 0 --prune-current-simulator
grep -Fxq 'simctl delete ACTIVE-UDID' "$SCRATCH/current simulator prune.xcrun" ||
	fail "current simulator was not pruned"
[[ ! -s "$SCRATCH/current simulator prune.args" ]] ||
	fail "current simulator prune unexpectedly invoked xcodebuild"
unset CASE_SIMCTL_DEVICES_JSON

run_cli_case "help exits without testing" 0 --help
grep -Fq -- '--only-testing IDENTIFIER' "$SCRATCH/help exits without testing.out" ||
	fail "help omitted scoped-filter usage"
[[ ! -s "$SCRATCH/help exits without testing.args" ]] ||
	fail "help unexpectedly invoked xcodebuild"

# Case H: the unfiltered TestApp plan structurally includes ReadiumSharedTests.
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
