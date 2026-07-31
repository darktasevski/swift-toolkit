#!/usr/bin/env bash
# =============================================================================
# test.sh [FILTER]
# =============================================================================
# Run the test suite.
#
# FILTER - Optional target to run (e.g. ReadiumSharedTests)
#
# Environment:
#   READIUM_TEST_DESTINATION  xcodebuild -destination to use, overriding the
#                             device-name default below. A caller running this
#                             alongside other suites on the same machine should
#                             pass a UDID-targeted destination: concurrent runs
#                             that share a simulator BY NAME clobber each
#                             other's installed test host.
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

DESTINATION="${READIUM_TEST_DESTINATION:-platform=iOS Simulator,name=iPad (A16)}"
FILTER="${1:-}"

ARGS=(
    -project "$REPO_ROOT/TestApp/TestApp.xcodeproj"
    -scheme TestApp
    -testPlan TestApp
    -destination "$DESTINATION"
)
[ -n "$FILTER" ] && ARGS+=(-only-testing:"$FILTER")

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

# The trailing filters must not decide the exit status. `grep -Ev` reports 1 when it filters
# every line away, and under `pipefail` that alone would fail a passing run — which is why this
# line used to end in `; true`. That silenced the real signal too: the script reported success for
# every run, whatever the tests did. Take xcodebuild's own status out of PIPESTATUS instead.
set +e
xcodebuild test "${ARGS[@]}" 2> /dev/null |
    xcbeautify --quieter --disable-logging |
    grep -Ev "^Executed |Test Suite 'All tests'|Test run started\.|Test session results:"
status=${PIPESTATUS[0]}
set -e

exit "$status"
