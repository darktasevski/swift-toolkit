#!/usr/bin/env bash
# =============================================================================
# test.sh [FILTER] [OPTIONS]
# =============================================================================
# Run the test suite.
#
# FILTER - Optional target to run (e.g. ReadiumSharedTests). Prefer the
#          repeatable --only-testing option for new callers.
#
# Options:
#   --only-testing IDENTIFIER  Run only this target, suite, or test. Repeatable.
#   --device NAME             Use a shared simulator by name.
#   prune-simulators          Delete dedicated simulators for removed worktrees.
#   --prune-current-simulator Delete this worktree's dedicated simulator.
#
# Environment:
#   READIUM_TEST_DESTINATION  Exact xcodebuild -destination override. The parent
#                             pre-PR harness uses this to share its resolver.
#   SIM_ISOLATION=0           Use the shared simulator by name.
#   SIMULATOR_UDID=...        Target an existing simulator by UDID.
#   SIMULATOR_NAME=...        Base device name (default: iPad (A16)).
#   SIM_PRUNE_ORPHANS=0       Skip the daily orphan-simulator prune.
#   CI=true                   Keep the shared name-based CI behavior.
#   READIUM_SKIP_TESTING      Space-separated -skip-testing identifiers, e.g.
#                             "ReadiumNavigatorTests/SomeFlakyTests". A caller
#                             that quarantines a class is responsible for saying
#                             so in its own output; this script does not.
#   READIUM_TEST_RESULT_BUNDLE
#                             Path to write the xcresult bundle to. Without it
#                             this script's entire output on a green run is the
#                             word "Test Succeeded" — xcbeautify --quieter plus
#                             the filter below strip every count — so a caller
#                             cannot tell a full run from one that executed or
#                             skipped almost nothing. Pass this to assert counts.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./scripts/test-simulator-isolation.sh
source "$SCRIPT_DIR/test-simulator-isolation.sh"

DEVICE="${SIMULATOR_NAME:-iPad (A16)}"
DEVICE_EXPLICITLY_SET=false
PRUNE_ORPHANS=false
PRUNE_CURRENT=false
ONLY_TESTING=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--only-testing | --filter)
		[[ $# -ge 2 ]] || {
			echo "$1 requires an identifier" >&2
			exit 64
		}
		ONLY_TESTING+=("$2")
		shift 2
		;;
	--device)
		[[ $# -ge 2 ]] || {
			echo "--device requires a name" >&2
			exit 64
		}
		DEVICE="$2"
		DEVICE_EXPLICITLY_SET=true
		shift 2
		;;
	prune-simulators | --prune-orphan-simulators)
		PRUNE_ORPHANS=true
		shift
		;;
	--prune-current-simulator)
		PRUNE_CURRENT=true
		shift
		;;
	--help)
		sed -n -e '3s/^# //p' -e '5,/^# =/s/^# \{0,1\}//p' "$0"
		exit 0
		;;
	--*)
		echo "Unknown option: $1" >&2
		exit 64
		;;
	*)
		ONLY_TESTING+=("$1")
		shift
		;;
	esac
done

if [[ "$PRUNE_ORPHANS" == true ]]; then
	readium_sim_prune_orphans "$REPO_ROOT"
	exit 0
fi
if [[ "$PRUNE_CURRENT" == true ]]; then
	readium_sim_prune_current "$REPO_ROOT" "$DEVICE"
	exit 0
fi

DESTINATION="$(readium_sim_resolve_destination "$REPO_ROOT" "$DEVICE" "$DEVICE_EXPLICITLY_SET")"

ARGS=(
	-project "$REPO_ROOT/TestApp/TestApp.xcodeproj"
	-scheme TestApp
	-testPlan TestApp
	-destination "$DESTINATION"
)
for identifier in ${ONLY_TESTING+"${ONLY_TESTING[@]}"}; do
	ARGS+=(-only-testing:"$identifier")
done

RESULT_BUNDLE="${READIUM_TEST_RESULT_BUNDLE:-}"
if [ -n "$RESULT_BUNDLE" ]; then
	# xcodebuild refuses to overwrite an existing bundle.
	rm -rf "$RESULT_BUNDLE"
	ARGS+=(-resultBundlePath "$RESULT_BUNDLE")
fi

# Word-split deliberately: the variable carries a list of identifiers.
# shellcheck disable=SC2206
skip_testing=(${READIUM_SKIP_TESTING:-})
for skip in ${skip_testing+"${skip_testing[@]}"}; do
	ARGS+=(-skip-testing:"$skip")
done

# `grep -Ev` reports 1 when it filters every line away, which is an expected successful outcome.
# Every other pipeline failure is authoritative: xcodebuild owns the test result, xcbeautify owns
# diagnostic rendering, and grep statuses above 1 mean the filter itself failed.
set +e
xcodebuild test "${ARGS[@]}" |
	xcbeautify --quieter --disable-logging |
	grep -Ev "^Executed |Test Suite 'All tests'|Test run started\.|Test session results:"
pipeline_status=("${PIPESTATUS[@]}")
set -e

if [[ "${pipeline_status[0]}" -ne 0 ]]; then
	status="${pipeline_status[0]}"
elif [[ "${pipeline_status[1]}" -ne 0 ]]; then
	status="${pipeline_status[1]}"
elif [[ "${pipeline_status[2]}" -gt 1 ]]; then
	status="${pipeline_status[2]}"
else
	status=0
fi

exit "$status"
