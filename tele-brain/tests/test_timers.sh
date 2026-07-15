#!/usr/bin/env bash
set -euo pipefail

SKILL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	local file="$1" expected="$2"
	grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

FAKE_SYSTEMCTL="$TEST_ROOT/systemctl"
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
cat >"$FAKE_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
case "$*" in
*' is-enabled '*) printf '%s\n' "${FAKE_ENABLED_STATE:-enabled}"; [[ "${FAKE_ENABLED_STATE:-enabled}" == enabled ]] ;;
*' is-active '*) printf '%s\n' "${FAKE_ACTIVE_STATE:-active}"; [[ "${FAKE_ACTIVE_STATE:-active}" == active ]] ;;
esac
EOF
chmod 0755 "$FAKE_SYSTEMCTL"

TEST_HOME="$TEST_ROOT/home"
OUTPUT="$TEST_ROOT/output"
export SYSTEMCTL_LOG
mkdir -p "$TEST_HOME/.local/state/tele-brain"
printf '%s\n' warning >"$TEST_HOME/.local/state/tele-brain/timer-refresh-required.json"

HOME="$TEST_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	"$SKILL_ROOT/install-timers.sh" install >"$OUTPUT"
UNIT_DIR="$TEST_HOME/.config/systemd/user"
for unit in tele-brain-refresh.service tele-brain-refresh.timer \
	tele-brain-update.service tele-brain-update.timer; do
	[[ -f "$UNIT_DIR/$unit" ]] || fail "unit was not installed: $unit"
	if grep -Fq '@TELE_BRAIN_ROOT@' "$UNIT_DIR/$unit"; then
		fail "unit still contains its template placeholder: $unit"
	fi
done
assert_contains "$UNIT_DIR/tele-brain-refresh.service" "$SKILL_ROOT/bin/tele-brain"
assert_contains "$UNIT_DIR/tele-brain-refresh.service" "EnvironmentFile=-$TEST_HOME/.config/tele-brain/environment"
assert_contains "$UNIT_DIR/tele-brain-refresh.service" 'ExecStart=/usr/bin/env TELE_BRAIN_CAPTURE_HELP=0'
assert_contains "$UNIT_DIR/tele-brain-refresh.timer" 'Persistent=true'
assert_contains "$UNIT_DIR/tele-brain-update.service" 'update scheduled'
assert_contains "$UNIT_DIR/tele-brain-update.service" 'TimeoutStartSec=10min'
assert_contains "$SYSTEMCTL_LOG" 'enable --now tele-brain-refresh.timer tele-brain-update.timer'
[[ ! -e "$TEST_HOME/.local/state/tele-brain/timer-refresh-required.json" ]] ||
	fail 'successful timer installation did not clear the updater warning'
printf 'ok - timer units install with safe rendered settings\n'

HOME="$TEST_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	"$SKILL_ROOT/install-timers.sh" install >"$OUTPUT"
assert_contains "$OUTPUT" 'unchanged:'
printf 'ok - repeated timer installation is idempotent\n'

XDG_HOME="$TEST_ROOT/xdg config"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$XDG_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	"$SKILL_ROOT/install-timers.sh" install >"$OUTPUT"
XDG_UNIT_DIR="$XDG_HOME/systemd/user"
assert_contains "$XDG_UNIT_DIR/tele-brain-refresh.service" \
	"EnvironmentFile=-${XDG_HOME// /\\x20}/tele-brain/environment"
assert_contains "$XDG_UNIT_DIR/tele-brain-update.service" \
	"EnvironmentFile=-${XDG_HOME// /\\x20}/tele-brain/environment"
printf 'ok - rendered services follow XDG_CONFIG_HOME for environment files\n'

HOME="$TEST_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	"$SKILL_ROOT/install-timers.sh" status >"$OUTPUT"
assert_contains "$OUTPUT" 'tele-brain-refresh.timer: enabled=enabled active=active'
assert_contains "$OUTPUT" 'tele-brain-update.timer: enabled=enabled active=active'
printf 'ok - timer status reports enabled and active units\n'

HOME="$TEST_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	FAKE_ENABLED_STATE=disabled FAKE_ACTIVE_STATE=inactive \
	"$SKILL_ROOT/install-timers.sh" status >"$OUTPUT"
assert_contains "$OUTPUT" 'tele-brain-refresh.timer: enabled=disabled active=inactive'
if grep -Fxq 'unknown' "$OUTPUT"; then
	fail 'disabled timer state was split across lines'
fi
printf 'ok - disabled and inactive states remain single-line status values\n'

HOME="$TEST_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	"$SKILL_ROOT/install-timers.sh" uninstall >"$OUTPUT"
for unit in tele-brain-refresh.service tele-brain-refresh.timer \
	tele-brain-update.service tele-brain-update.timer; do
	[[ ! -e "$UNIT_DIR/$unit" ]] || fail "unit remains after uninstall: $unit"
done
assert_contains "$SYSTEMCTL_LOG" 'disable --now tele-brain-refresh.timer tele-brain-update.timer'
printf 'ok - timer uninstall removes all managed units\n'

DRY_HOME="$TEST_ROOT/dry-home"
HOME="$DRY_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	"$SKILL_ROOT/install-timers.sh" install --dry-run >"$OUTPUT"
[[ ! -e "$DRY_HOME/.config/systemd/user" ]] || fail 'dry-run created the systemd user directory'
assert_contains "$OUTPUT" 'dry-run: render'
printf 'ok - dry-run performs no filesystem mutation\n'

if command -v systemd-analyze >/dev/null 2>&1; then
	VERIFY_HOME="$TEST_ROOT/verify-home"
	VERIFY_OUTPUT="$TEST_ROOT/systemd-verify.log"
	HOME="$VERIFY_HOME" TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" \
		"$SKILL_ROOT/install-timers.sh" install >/dev/null
	if ! systemd-analyze --user verify "$VERIFY_HOME/.config/systemd/user/"tele-brain-*.service \
		"$VERIFY_HOME/.config/systemd/user/"tele-brain-*.timer >"$VERIFY_OUTPUT" 2>&1; then
		sed -n '1,160p' "$VERIFY_OUTPUT" >&2
		fail 'rendered units failed systemd-analyze verify'
	fi
	if [[ -s "$VERIFY_OUTPUT" ]]; then
		sed -n '1,160p' "$VERIFY_OUTPUT" >&2
		fail 'rendered units produced systemd-analyze diagnostics'
	fi
	if ! systemd-analyze --user verify "$XDG_UNIT_DIR/"tele-brain-*.service \
		"$XDG_UNIT_DIR/"tele-brain-*.timer >"$VERIFY_OUTPUT" 2>&1; then
		sed -n '1,160p' "$VERIFY_OUTPUT" >&2
		fail 'XDG-rendered units failed systemd-analyze verify'
	fi
	if [[ -s "$VERIFY_OUTPUT" ]]; then
		sed -n '1,160p' "$VERIFY_OUTPUT" >&2
		fail 'XDG-rendered units produced systemd-analyze diagnostics'
	fi
	printf 'ok - rendered units pass systemd-analyze verify\n'
fi

printf 'all timer tests passed\n'
