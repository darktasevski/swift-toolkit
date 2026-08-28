# AGENTS.md

The Readium Swift toolkit is used to develop reading apps for iOS, with support for EPUB, PDF, audiobooks and comics.

## Testing

- `scripts/test.sh` runs all tests
- `scripts/test.sh ReadiumSharedTests` runs only the tests for the ReadiumShared package
- `scripts/test.sh --only-testing ReadiumNavigatorTests/SomeSuite` scopes a run; repeat the flag for several identifiers
- Direct local runs use a per-worktree simulator by UDID. `SIM_ISOLATION=0`, `SIMULATOR_UDID=...`, `--device`, `CI=true`, or `READIUM_TEST_DESTINATION=...` are the escape hatches; `scripts/test.sh prune-simulators` removes orphaned dedicated devices.
- `scripts/test-test.sh` self-tests the test runner's exit-status and plan-membership contract
