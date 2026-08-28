#!/usr/bin/env bash
# Per-worktree simulator isolation for scripts/test.sh.
#
# This is sourced rather than executed. The toolkit also runs as a standalone
# repository, so it cannot depend on the parent app's simulator helper.

readium_sim_hash() {
	local count="$1"
	local value="$2"
	printf '%s' "$value" | shasum -a 256 | awk -v count="$count" '{ print substr($1, 1, count) }'
}

readium_sim_owner_root() {
	local repository_root="$1"
	local superproject_root
	superproject_root="$(git -C "$repository_root" rev-parse --show-superproject-working-tree)"
	if [[ -n "$superproject_root" ]]; then
		printf '%s\n' "$superproject_root"
	else
		printf '%s\n' "$repository_root"
	fi
}

readium_sim_repo_id() {
	local owner_root="$1"
	local common_dir
	common_dir="$(git -C "$owner_root" rev-parse --path-format=absolute --git-common-dir)"
	readium_sim_hash 8 "$common_dir"
}

readium_sim_worktree_slug() {
	readium_sim_hash 12 "$1"
}

readium_sim_device_suffix() {
	local suffix
	suffix="$(printf '%s' "$1" | sed -E 's/[^A-Za-z0-9-]+/-/g; s/^-+//; s/-+$//')"
	printf '%s\n' "${suffix:-device}"
}

readium_sim_dedicated_name() {
	local repository_root="$1"
	local device_name="$2"
	local owner_root repo_id worktree_slug device_suffix
	owner_root="$(readium_sim_owner_root "$repository_root")"
	repo_id="$(readium_sim_repo_id "$owner_root")"
	worktree_slug="$(readium_sim_worktree_slug "$owner_root")"
	device_suffix="$(readium_sim_device_suffix "$device_name")"
	printf 'Readium-WT-%s__%s__%s\n' "$repo_id" "$worktree_slug" "$device_suffix"
}

readium_sim_find_udid() {
	local device_name="$1"
	xcrun simctl list devices available -j | python3 -c '
import json
import sys

name = sys.argv[1]
payload = json.load(sys.stdin)
for devices in payload.get("devices", {}).values():
    for device in devices:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
' "$device_name"
}

readium_sim_validate_udid() {
	local expected_udid="$1"
	xcrun simctl list devices available -j | python3 -c '
import json
import sys

expected = sys.argv[1]
payload = json.load(sys.stdin)
for devices in payload.get("devices", {}).values():
    for device in devices:
        if device.get("udid") == expected and device.get("isAvailable", True):
            raise SystemExit(0)
raise SystemExit(1)
' "$expected_udid"
}

readium_sim_acquire_create_lock() {
	local repository_root="$1"
	local lock_dir="$repository_root/.build/readium-simulator-create.lock.d"
	local waited=0
	mkdir -p "$repository_root/.build"
	while ! mkdir "$lock_dir" 2>/dev/null; do
		sleep 0.2
		waited=$((waited + 1))
		if [[ "$waited" -ge 300 ]]; then
			echo "Timed out waiting for the simulator create lock" >&2
			return 1
		fi
	done
	READIUM_SIM_CREATE_LOCK_DIR="$lock_dir"
}

readium_sim_release_create_lock() {
	if [[ -n "${READIUM_SIM_CREATE_LOCK_DIR:-}" ]]; then
		rmdir "$READIUM_SIM_CREATE_LOCK_DIR" 2>/dev/null || true
		unset READIUM_SIM_CREATE_LOCK_DIR
	fi
}

readium_sim_ensure_dedicated_device() {
	local repository_root="$1"
	local device_name="$2"
	local dedicated_name udid
	dedicated_name="$(readium_sim_dedicated_name "$repository_root" "$device_name")"
	udid="$(readium_sim_find_udid "$dedicated_name" 2>/dev/null || true)"
	if [[ -z "$udid" ]]; then
		readium_sim_acquire_create_lock "$repository_root"
		udid="$(readium_sim_find_udid "$dedicated_name" 2>/dev/null || true)"
		if [[ -z "$udid" ]]; then
			echo "Creating dedicated simulator: $dedicated_name" >&2
			if ! udid="$(xcrun simctl create "$dedicated_name" "$device_name")"; then
				# A concurrent creator can win after the second lookup.
				udid="$(readium_sim_find_udid "$dedicated_name" 2>/dev/null || true)"
			fi
		fi
		readium_sim_release_create_lock
	fi
	if [[ -z "$udid" ]]; then
		echo "Failed to resolve dedicated simulator: $dedicated_name" >&2
		return 1
	fi
	printf '%s\n' "$udid"
}

readium_sim_active_slugs() {
	local owner_root="$1"
	local line worktree_root worktree_list
	if ! worktree_list="$(git -C "$owner_root" worktree list --porcelain)"; then
		echo "Failed to enumerate active worktrees; refusing simulator prune" >&2
		return 1
	fi
	while IFS= read -r line; do
		case "$line" in
		"worktree "*)
			worktree_root="${line#worktree }"
			readium_sim_worktree_slug "$worktree_root"
			;;
		esac
	done <<<"$worktree_list"
}

readium_sim_prune_orphans() {
	local repository_root="$1"
	local owner_root repo_id active_slugs orphan_udids udid
	owner_root="$(readium_sim_owner_root "$repository_root")"
	repo_id="$(readium_sim_repo_id "$owner_root")"
	if ! active_slugs="$(readium_sim_active_slugs "$owner_root")"; then
		return 1
	fi
	orphan_udids="$({ xcrun simctl list devices available -j; } | python3 -c '
import json
import sys

prefix = sys.argv[1]
active = set(filter(None, sys.argv[2].splitlines()))
payload = json.load(sys.stdin)
for devices in payload.get("devices", {}).values():
    for device in devices:
        name = str(device.get("name", ""))
        if not name.startswith(prefix):
            continue
        remainder = name[len(prefix):]
        slug, separator, _ = remainder.partition("__")
        if separator and slug not in active and device.get("isAvailable", True):
            print(device["udid"])
' "Readium-WT-${repo_id}__" "$active_slugs")"
	while IFS= read -r udid; do
		[[ -n "$udid" ]] || continue
		xcrun simctl delete "$udid"
	done <<<"$orphan_udids"
}

readium_sim_maybe_prune_orphans() {
	local repository_root="$1"
	local stamp="$repository_root/.build/readium-simulator-prune-stamp"
	if [[ "${SIM_PRUNE_ORPHANS:-1}" == 0 ]]; then
		return 0
	fi
	if [[ -f "$stamp" ]] && find "$stamp" -mtime -1 -print -quit 2>/dev/null | grep -q .; then
		return 0
	fi
	readium_sim_prune_orphans "$repository_root"
	mkdir -p "$repository_root/.build"
	touch "$stamp"
}

readium_sim_prune_current() {
	local repository_root="$1"
	local device_name="$2"
	local dedicated_name udid
	dedicated_name="$(readium_sim_dedicated_name "$repository_root" "$device_name")"
	udid="$(readium_sim_find_udid "$dedicated_name" 2>/dev/null || true)"
	if [[ -z "$udid" ]]; then
		echo "No dedicated simulator to prune for this worktree ($dedicated_name)"
		return 0
	fi
	xcrun simctl delete "$udid"
	echo "Pruned dedicated simulator: $dedicated_name ($udid)"
}

readium_sim_resolve_destination() {
	local repository_root="$1"
	local device_name="$2"
	local device_explicitly_set="$3"
	local udid

	if [[ -n "${READIUM_TEST_DESTINATION:-}" ]]; then
		printf '%s\n' "$READIUM_TEST_DESTINATION"
		return 0
	fi

	if [[ -n "${SIMULATOR_UDID:-}" ]]; then
		if ! readium_sim_validate_udid "$SIMULATOR_UDID"; then
			echo "SIMULATOR_UDID not found: $SIMULATOR_UDID" >&2
			return 1
		fi
		printf 'platform=iOS Simulator,id=%s\n' "$SIMULATOR_UDID"
		return 0
	fi

	if [[ "$device_explicitly_set" == true || "${SIM_ISOLATION:-1}" == 0 || "${CI:-}" == true ]]; then
		printf 'platform=iOS Simulator,name=%s\n' "$device_name"
		return 0
	fi

	readium_sim_maybe_prune_orphans "$repository_root"
	udid="$(readium_sim_ensure_dedicated_device "$repository_root" "$device_name")"
	printf 'platform=iOS Simulator,id=%s\n' "$udid"
}
