#!/usr/bin/env bash
set -euo pipefail

SCAN="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scan.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	local actual="$1" expected="$2"
	[[ "$actual" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

test_cli_help_and_missing_status() {
	local case_dir="$TMP_ROOT/cli" output
	mkdir -p "$case_dir/home"
	output="$(HOME="$case_dir/home" TELE_BRAIN_DATA_DIR="$case_dir/data" TELE_BRAIN_STATE_DIR="$case_dir/state" "$SCAN" --help)"
	assert_contains "$output" './scan.sh --status'
	assert_contains "$output" '--if-stale DURATION'
	assert_contains "$output" '--capture-help'

	output="$(HOME="$case_dir/home" TELE_BRAIN_DATA_DIR="$case_dir/data" TELE_BRAIN_STATE_DIR="$case_dir/state" "$SCAN" --status)"
	assert_contains "$output" 'status=missing'
	assert_contains "$output" 'age_seconds=-1'
	printf 'ok - CLI help and missing status\n'
}

test_capture_help_cli_override() (
	local case_dir="$TMP_ROOT/capture-option"
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=1
	mkdir -p "$HOME"
	# shellcheck source=../scan.sh
	source "$SCAN"
	[[ "$CAPTURE_HELP" == 1 ]] || fail 'environment did not enable capture help'
	run_cli --status --no-capture-help >/dev/null
	[[ "$CAPTURE_HELP" == 0 ]] || fail '--no-capture-help did not override the environment'
	run_cli --status --capture-help >/dev/null
	[[ "$CAPTURE_HELP" == 1 ]] || fail '--capture-help did not enable explicit capture'
	printf 'ok - capture-help CLI options override the environment\n'
)

test_safe_ids_do_not_collide() (
	local case_dir="$TMP_ROOT/safe-id" first second unchanged long_id empty_slug
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	mkdir -p "$HOME"
	# shellcheck source=../scan.sh
	source "$SCAN"
	first="$(safe_id 'scope/tool:name')"
	second="$(safe_id 'scope:tool/name')"
	unchanged="$(safe_id 'demo#apt')"
	long_id="$(safe_id "$(printf '%0200d' 0)")"
	empty_slug="$(safe_id '@@@')"
	[[ "$first" != "$second" ]] || fail 'distinct IDs collapsed to the same filename'
	[[ "$first" == scope_tool_name-* && "$second" == scope_tool_name-* ]] ||
		fail 'transformed IDs do not retain a readable prefix and digest'
	[[ "$unchanged" == 'demo#apt' ]] || fail 'an existing safe ID was needlessly renamed'
	(( ${#long_id} <= 177 )) || fail 'safe ID can exceed the filesystem filename budget'
	[[ "$empty_slug" == id-* ]] || fail 'an ID with no slug did not receive a safe filename'
	printf 'ok - safe IDs remain readable and collision resistant\n'
)

test_legacy_safe_id_migration() (
	local case_dir="$TMP_ROOT/legacy-migration" fake new_id
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=0
	export TELE_BRAIN_MAX_CANONICAL=0
	mkdir -p "$HOME" "$TELE_BRAIN_DATA_DIR/raw_help" "$TELE_BRAIN_DATA_DIR/references"
	fake="$case_dir/demo"
	printf '%s\n' '#!/usr/bin/env bash' 'printf legacy-help' >"$fake"
	chmod +x "$fake"
	printf 'legacy-help\n' >"$TELE_BRAIN_DATA_DIR/raw_help/foo_bar#path.txt"
	printf 'legacy-reference\n' >"$TELE_BRAIN_DATA_DIR/references/foo_bar#path.md"
	cat >"$TELE_BRAIN_DATA_DIR/index.yaml" <<'EOF'
entries:
  - id: "foo/bar#path"
    reference: "references/foo_bar#path.md"
    raw_help: "raw_help/foo_bar#path.txt"
EOF
	# shellcheck source=../scan.sh
	source "$SCAN"
	new_id="$(safe_id 'foo/bar#path')"
	[[ "$new_id" != 'foo_bar#path' ]] || fail 'migration fixture did not require a new ID'
	scan_apt() { :; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() { add_entry 'foo/bar#path' foo unknown path cli "$fake"; }
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }
	with_lock refresh_index
	grep -q "reference: \"references/$new_id.md\"" "$TELE_BRAIN_DATA_DIR/index.yaml" ||
		fail 'legacy reference was not associated with its new collision-safe ID'
	[[ "$(<"$TELE_BRAIN_DATA_DIR/references/$new_id.md")" == 'legacy-reference' ]] ||
		fail 'legacy reference content was not migrated'
	[[ "$(<"$TELE_BRAIN_DATA_DIR/raw_help/$new_id.txt")" == 'legacy-help' ]] ||
		fail 'legacy raw help content was not migrated'
	printf 'ok - legacy reference paths migrate without conflating collisions\n'
)

test_cross_generation_legacy_collision_is_rejected() (
	local case_dir="$TMP_ROOT/legacy-collision" fake new_id
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=0
	export TELE_BRAIN_MAX_CANONICAL=0
	mkdir -p "$HOME" "$TELE_BRAIN_DATA_DIR/raw_help" "$TELE_BRAIN_DATA_DIR/references"
	fake="$case_dir/new-demo"
	printf '%s\n' '#!/usr/bin/env bash' 'printf new-help' >"$fake"
	chmod +x "$fake"
	printf 'old-tool-help\n' >"$TELE_BRAIN_DATA_DIR/raw_help/foo_bar#path.txt"
	printf 'old-tool-reference\n' >"$TELE_BRAIN_DATA_DIR/references/foo_bar#path.md"
	cat >"$TELE_BRAIN_DATA_DIR/index.yaml" <<'EOF'
entries:
  - id: "foo/bar#path"
    reference: "references/foo_bar#path.md"
    raw_help: "raw_help/foo_bar#path.txt"
EOF
	# shellcheck source=../scan.sh
	source "$SCAN"
	new_id="$(safe_id 'foo:bar#path')"
	scan_apt() { :; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() { add_entry 'foo:bar#path' foo unknown path cli "$fake"; }
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }
	with_lock refresh_index
	[[ ! -e "$TELE_BRAIN_DATA_DIR/references/$new_id.md" ]] ||
		fail 'a new software ID inherited an unrelated legacy reference'
	[[ ! -e "$TELE_BRAIN_DATA_DIR/raw_help/$new_id.txt" ]] ||
		fail 'a new software ID inherited unrelated legacy raw help'
	grep -q 'reference: ""' "$TELE_BRAIN_DATA_DIR/index.yaml" ||
		fail 'new software retained an unrelated legacy reference association'
	grep -q 'raw_help: ""' "$TELE_BRAIN_DATA_DIR/index.yaml" ||
		fail 'new software retained unrelated legacy raw help association'
	printf 'ok - cross-generation legacy slug collisions are not migrated\n'
)

test_if_stale_skips_fresh_index() {
	local case_dir="$TMP_ROOT/fresh" before after output
	mkdir -p "$case_dir/home" "$case_dir/data"
	printf '%s\n' 'sentinel-index' >"$case_dir/data/index.yaml"
	before="$(sha256sum "$case_dir/data/index.yaml")"
	output="$(HOME="$case_dir/home" TELE_BRAIN_DATA_DIR="$case_dir/data" TELE_BRAIN_STATE_DIR="$case_dir/state" "$SCAN" --refresh --if-stale 1d)"
	after="$(sha256sum "$case_dir/data/index.yaml")"
	[[ "$before" == "$after" ]] || fail 'fresh index was unexpectedly replaced'
	assert_contains "$output" 'index is fresh, skipped'
	[[ -f "$case_dir/state/operation.lock" ]] || fail 'operation lock was not created in the state directory'
	printf 'ok - --if-stale skips a fresh index\n'
}

test_symlinked_data_root_refreshes_repeatedly() (
	local case_dir="$TMP_ROOT/symlinked-root" target alias
	export HOME="$case_dir/home"
	target="$case_dir/real-data"
	alias="$case_dir/data-alias"
	mkdir -p "$HOME" "$target"
	ln -s -- "$target" "$alias"
	export TELE_BRAIN_DATA_DIR="$alias"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=0
	# shellcheck source=../scan.sh
	source "$SCAN"
	scan_apt() { :; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() { :; }
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }
	with_lock refresh_index
	with_lock refresh_index
	[[ "$DATA_DIR" == "$target" ]] || fail 'symlinked data root was not canonicalized'
	[[ "$(readlink -f "$alias/current")" == "$target"/generations/generation-* ]] ||
		fail 'repeated refresh did not retain a generation under the real data root'
	printf 'ok - symlinked data roots support repeated refreshes\n'
)

test_pipeline_scanners_persist_entries() (
	local case_dir="$TMP_ROOT/pipelines"
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	mkdir -p "$HOME"
	# shellcheck source=../scan.sh
	source "$SCAN"
	reset_entries

	snap() { printf 'Name Version Rev Tracking Publisher Notes\nfoo 1.2 1 stable - -\n'; }
	flatpak() { printf 'org.demo.App\tDemo\t3.4\n'; }
	pip() {
		if [[ "$*" == *--user* ]]; then
			printf 'userpkg==1.0\n'
		else
			printf 'globalpkg==2.0\n'
		fi
	}
	npm() { printf '/usr/lib/node_modules\n/usr/lib/node_modules/npm-demo\n'; }
	cargo() { printf 'cargo-demo v1.0:\n'; }
	brew() { printf 'brew-demo 4.0\n'; }

	scan_snap
	scan_flatpak
	scan_pip
	scan_npm
	scan_cargo
	scan_brew

	[[ "${NAME[foo#snap]:-}" == 'foo' ]] || fail 'snap entry was lost'
	[[ "${NAME[org.demo.App#flatpak]:-}" == 'org.demo.App' ]] || fail 'flatpak entry was lost'
	[[ "${NAME[userpkg#pip-user]:-}" == 'userpkg' ]] || fail 'pip user entry was lost'
	[[ "${NAME[globalpkg#pip-global]:-}" == 'globalpkg' ]] || fail 'pip global entry was lost'
	[[ "${NAME[npm-demo#npm]:-}" == 'npm-demo' ]] || fail 'npm entry was lost'
	[[ "${NAME[cargo-demo#cargo]:-}" == 'cargo-demo' ]] || fail 'cargo entry was lost'
	[[ "${NAME[brew-demo#brew]:-}" == 'brew-demo' ]] || fail 'brew entry was lost'
	printf 'ok - pipeline scanners persist entries\n'
)

test_atomic_index_and_capture_disabled() (
	local case_dir="$TMP_ROOT/atomic" fake marker index leftovers
	case_dir="$TMP_ROOT/atomic"
	fake="$case_dir/fake-cli"
	marker="$case_dir/help-was-executed"
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=0
	export TELE_BRAIN_MAX_REFERENCES=25
	export TELE_BRAIN_MAX_CANONICAL=0
	export MARKER="$marker"
	mkdir -p "$HOME" "$TELE_BRAIN_DATA_DIR/raw_help" "$TELE_BRAIN_DATA_DIR/references"
	printf '%s\n' '#!/usr/bin/env bash' ': >"${MARKER:?}"' "printf 'new help output\\n'" >"$fake"
	chmod +x "$fake"
	printf 'old help output\n' >"$TELE_BRAIN_DATA_DIR/raw_help/demo#path-test.txt"
	printf 'sentinel reference\n' >"$TELE_BRAIN_DATA_DIR/references/demo#path-test.md"
	printf 'orphaned help output\n' >"$TELE_BRAIN_DATA_DIR/raw_help/orphan#apt.txt"
	printf 'orphaned reference\n' >"$TELE_BRAIN_DATA_DIR/references/orphan#apt.md"

	# shellcheck source=../scan.sh
	source "$SCAN"
	scan_apt() { add_entry 'orphan#apt' orphan 0.9 apt cli ''; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() { add_entry 'demo#path-test' demo unknown path cli "$fake"; }
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }

	with_lock refresh_index
	index="$TELE_BRAIN_DATA_DIR/index.yaml"
	[[ ! -e "$marker" ]] || fail 'CLI help ran while TELE_BRAIN_CAPTURE_HELP=0'
	grep -q '^schema_version: 1$' "$index" || fail 'schema metadata is missing'
	grep -q '^generator:$' "$index" || fail 'generator metadata is missing'
	grep -q 'reference: "references/demo#path-test.md"' "$index" || fail 'existing reference association was lost'
	grep -q 'raw_help: "raw_help/demo#path-test.txt"' "$index" || fail 'existing raw help association was lost'
	grep -q 'reference: "references/orphan#apt.md"' "$index" || fail 'orphaned CLI reference association was lost'
	grep -q 'raw_help: "raw_help/orphan#apt.txt"' "$index" || fail 'orphaned CLI raw help association was lost'
	[[ "$(<"$TELE_BRAIN_DATA_DIR/references/demo#path-test.md")" == 'sentinel reference' ]] || fail 'existing reference was unexpectedly rewritten'
	[[ "$(<"$TELE_BRAIN_DATA_DIR/references/orphan#apt.md")" == 'orphaned reference' ]] || fail 'orphaned CLI reference was unexpectedly rewritten'
	[[ "$(stat -Lc '%a' "$TELE_BRAIN_STATE_DIR")" == '700' ]] || fail 'state directory is not private'
	[[ -f "$TELE_BRAIN_STATE_DIR/operation.lock" ]] || fail 'shared operation lock is missing'
	leftovers="$(find "$TELE_BRAIN_DATA_DIR" -name '*.tmp.*' -print -quit)"
	[[ -z "$leftovers" ]] || fail "temporary output was not cleaned up: $leftovers"
	printf 'ok - atomic metadata output and capture-disabled preservation\n'
)

test_invalid_duration_fails_closed() {
	local case_dir="$TMP_ROOT/invalid" output_file="$TMP_ROOT/invalid-output"
	mkdir -p "$case_dir/home"
	if HOME="$case_dir/home" TELE_BRAIN_DATA_DIR="$case_dir/data" TELE_BRAIN_STATE_DIR="$case_dir/state" "$SCAN" --refresh --if-stale tomorrow >"$output_file" 2>&1; then
		fail 'invalid duration was accepted'
	fi
	grep -q 'invalid duration: tomorrow' "$output_file" || fail 'invalid duration error was not reported'
	printf 'ok - invalid duration fails closed\n'
}

test_generation_failure_preserves_live_view() (
	local case_dir="$TMP_ROOT/generation-failure" current_before current_after
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=0
	mkdir -p "$HOME" "$TELE_BRAIN_DATA_DIR/references" "$TELE_BRAIN_DATA_DIR/raw_help"
	printf 'old-index\n' >"$TELE_BRAIN_DATA_DIR/index.yaml"
	printf 'old-reference\n' >"$TELE_BRAIN_DATA_DIR/references/demo.md"
	printf 'old-raw\n' >"$TELE_BRAIN_DATA_DIR/raw_help/demo.txt"
	# shellcheck source=../scan.sh
	source "$SCAN"
	scan_apt() { :; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() { :; }
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }
	write_index() {
		printf 'new-reference\n' >"$BUILD_REFS_DIR/demo.md"
		printf 'partial-index\n' >"$BUILD_DATA_DIR/index.yaml"
		return 1
	}
	if with_lock refresh_index; then
		fail 'forced generation failure unexpectedly succeeded'
	fi
	[[ "$(<"$TELE_BRAIN_DATA_DIR/index.yaml")" == 'old-index' ]] || fail 'failed generation replaced the live index'
	[[ "$(<"$TELE_BRAIN_DATA_DIR/references/demo.md")" == 'old-reference' ]] || fail 'failed generation replaced a live reference'
	[[ "$(<"$TELE_BRAIN_DATA_DIR/raw_help/demo.txt")" == 'old-raw' ]] || fail 'failed generation replaced live raw help'
	current_before="$(realpath "$TELE_BRAIN_DATA_DIR/current")"
	current_after="$(realpath "$TELE_BRAIN_DATA_DIR/index.yaml" | xargs dirname)"
	[[ "$current_before" == "$current_after" ]] || fail 'generation views do not share one current target'
	[[ -z "$(find "$TELE_BRAIN_DATA_DIR/generations" -maxdepth 1 -name '.staging.*' -print -quit)" ]] ||
		fail 'failed generation left a staging directory'
	printf 'ok - failed generation preserves the complete live data view\n'
)

test_help_fingerprint_and_size_limit() (
	local case_dir="$TMP_ROOT/help-fingerprint" fake raw metadata
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=1
	export TELE_BRAIN_MAX_REFERENCES=25
	export TELE_BRAIN_MAX_CANONICAL=0
	export TELE_BRAIN_MAX_HELP_BYTES=1024
	mkdir -p "$HOME"
	fake="$case_dir/demo"
	printf '%s\n' '#!/usr/bin/env bash' "printf 'help-v1\\n'" >"$fake"
	chmod +x "$fake"
	# shellcheck source=../scan.sh
	source "$SCAN"
	scan_apt() { :; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() { add_entry 'demo#path-test' demo unknown path cli "$fake"; }
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }

	with_lock refresh_index
	raw="$TELE_BRAIN_DATA_DIR/raw_help/demo#path-test.txt"
	metadata="$TELE_BRAIN_DATA_DIR/raw_help/demo#path-test.meta"
	grep -q 'help-v1' "$raw" || fail 'initial explicit help capture failed'
	[[ -s "$metadata" ]] || fail 'help fingerprint metadata was not written'
	grep -q 'reference_stale: false' "$TELE_BRAIN_DATA_DIR/index.yaml" || fail 'fresh help was marked stale'

	printf '%s\n' '#!/usr/bin/env bash' "printf 'help-v2-changed\\n'" >"$fake"
	chmod +x "$fake"
	CAPTURE_HELP=0
	with_lock refresh_index
	grep -q 'help-v1' "$raw" || fail 'safe refresh replaced stale help without consent'
	grep -q 'reference_stale: true' "$TELE_BRAIN_DATA_DIR/index.yaml" || fail 'changed executable did not mark help stale'

	CAPTURE_HELP=1
	with_lock refresh_index
	grep -q 'help-v2-changed' "$raw" || fail 'explicit capture did not refresh changed help'
	grep -q 'reference_stale: false' "$TELE_BRAIN_DATA_DIR/index.yaml" || fail 'refreshed help remained stale'

	printf '%s\n' '#!/usr/bin/env bash' 'head -c 4096 /dev/zero' >"$fake"
	chmod +x "$fake"
	CAPTURE_HELP=1
	with_lock refresh_index
	grep -q 'help-v2-changed' "$raw" || fail 'oversized help replaced the last valid capture'
	grep -q 'reference_stale: true' "$TELE_BRAIN_DATA_DIR/index.yaml" || fail 'oversized rejected help was not marked stale'
	printf 'ok - help fingerprints refresh changed CLIs and reject oversized output\n'
)

test_fresh_references_do_not_consume_capture_budget() (
	local case_dir="$TMP_ROOT/capture-budget" fresh changed fresh_fp changed_fp
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=1
	export TELE_BRAIN_MAX_REFERENCES=1
	export TELE_BRAIN_MAX_CANONICAL=0
	mkdir -p "$HOME" "$TELE_BRAIN_DATA_DIR/references" "$TELE_BRAIN_DATA_DIR/raw_help"
	fresh="$case_dir/fresh"
	changed="$case_dir/changed"
	printf '%s\n' '#!/usr/bin/env bash' "printf 'fresh-help\\n'" >"$fresh"
	printf '%s\n' '#!/usr/bin/env bash' "printf 'old-changed-help\\n'" >"$changed"
	chmod +x "$fresh" "$changed"
	# shellcheck source=../scan.sh
	source "$SCAN"
	fresh_fp="$(executable_fingerprint "$fresh" unknown)"
	changed_fp="$(executable_fingerprint "$changed" unknown)"
	printf 'fresh-help\n' >"$TELE_BRAIN_DATA_DIR/raw_help/a#path.txt"
	printf '%s\n' "$fresh_fp" >"$TELE_BRAIN_DATA_DIR/raw_help/a#path.meta"
	printf 'old-changed-help\n' >"$TELE_BRAIN_DATA_DIR/raw_help/z#path.txt"
	printf '%s\n' "$changed_fp" >"$TELE_BRAIN_DATA_DIR/raw_help/z#path.meta"
	printf 'fresh-reference\n' >"$TELE_BRAIN_DATA_DIR/references/a#path.md"
	printf 'changed-reference\n' >"$TELE_BRAIN_DATA_DIR/references/z#path.md"
	printf '%s\n' '#!/usr/bin/env bash' "printf 'new-changed-help-longer\\n'" >"$changed"
	chmod +x "$changed"
	scan_apt() { :; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() {
		add_entry 'a#path' fresh unknown path cli "$fresh"
		add_entry 'z#path' changed unknown path cli "$changed"
	}
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }
	with_lock refresh_index
	grep -q 'new-changed-help-longer' "$TELE_BRAIN_DATA_DIR/raw_help/z#path.txt" ||
		fail 'fresh reference consumed the only help capture slot'
	[[ "$SCAN_HELP_CAPTURE_COUNT" == 1 ]] || fail 'help capture counter is incorrect'
	[[ "$SCAN_HELP_ATTEMPT_COUNT" == 1 ]] || fail 'help attempt counter is incorrect'
	printf 'ok - fresh references do not consume changed-help capture budget\n'
)

test_failed_help_consumes_attempt_budget() (
	local case_dir="$TMP_ROOT/failed-help-budget" failing second marker
	export HOME="$case_dir/home"
	export TELE_BRAIN_DATA_DIR="$case_dir/data"
	export TELE_BRAIN_STATE_DIR="$case_dir/state"
	export TELE_BRAIN_CAPTURE_HELP=1
	export TELE_BRAIN_MAX_REFERENCES=1
	export TELE_BRAIN_MAX_CANONICAL=0
	mkdir -p "$HOME"
	failing="$case_dir/failing"
	second="$case_dir/second"
	marker="$case_dir/second-executed"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$failing"
	printf '%s\n' '#!/usr/bin/env bash' ": >\"$marker\"" 'printf second-help' >"$second"
	chmod +x "$failing" "$second"
	# shellcheck source=../scan.sh
	source "$SCAN"
	scan_apt() { :; }
	scan_snap() { :; }
	scan_flatpak() { :; }
	scan_pip() { :; }
	scan_npm() { :; }
	scan_cargo() { :; }
	scan_brew() { :; }
	scan_path() {
		add_entry 'a#path' failing unknown path cli "$failing"
		add_entry 'z#path' second unknown path cli "$second"
	}
	scan_gui_desktop() { :; }
	scan_browser_plugins() { :; }
	scan_ide_plugins() { :; }
	with_lock refresh_index
	[[ ! -e "$marker" ]] || fail 'a failed capture did not consume the only attempt slot'
	[[ "$SCAN_HELP_ATTEMPT_COUNT" == 1 ]] || fail 'failed capture attempt counter is incorrect'
	[[ "$SCAN_HELP_CAPTURE_COUNT" == 0 ]] || fail 'failed capture was counted as successful'
	printf 'ok - failed help captures consume the bounded attempt budget\n'
)

bash -n "$SCAN"
test_cli_help_and_missing_status
test_capture_help_cli_override
test_safe_ids_do_not_collide
test_legacy_safe_id_migration
test_cross_generation_legacy_collision_is_rejected
test_if_stale_skips_fresh_index
test_symlinked_data_root_refreshes_repeatedly
test_pipeline_scanners_persist_entries
test_atomic_index_and_capture_disabled
test_invalid_duration_fails_closed
test_generation_failure_preserves_live_view
test_help_fingerprint_and_size_limit
test_fresh_references_do_not_consume_capture_budget
test_failed_help_consumes_attempt_budget
printf 'all scan tests passed\n'
