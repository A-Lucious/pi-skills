#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$SCRIPT_DIR"
TEMPLATE_DIR="$SKILL_ROOT/systemd"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tele-brain/environment"
UPDATER_WARNING_FILE="${TELE_BRAIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tele-brain}/timer-refresh-required.json"
SYSTEMCTL_BIN="${TELE_BRAIN_SYSTEMCTL:-systemctl}"
DRY_RUN=0
ACTION=""

UNIT_FILES=(
	tele-brain-refresh.service
	tele-brain-refresh.timer
	tele-brain-update.service
	tele-brain-update.timer
)
TIMER_UNITS=(tele-brain-refresh.timer tele-brain-update.timer)

usage() {
	cat <<'EOF'
Usage: ./install-timers.sh [install|uninstall|status] [--dry-run]

Commands:
  install    Install and enable the user timers (default)
  uninstall  Disable the timers and remove their unit files
  status     Show installed files and timer state

Options:
  --dry-run  Print mutating operations without performing them
  -h, --help Show this help

Set TELE_BRAIN_SYSTEMCTL to override the systemctl executable for testing.
EOF
}

while [[ "$#" -gt 0 ]]; do
	case "$1" in
	install|uninstall|status)
		if [[ -n "$ACTION" ]]; then
			printf 'install-timers: only one action may be specified\n' >&2
			exit 2
		fi
		ACTION="$1"
		;;
	--dry-run)
		DRY_RUN=1
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		printf 'install-timers: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done
ACTION="${ACTION:-install}"

print_command() {
	printf 'dry-run:'
	printf ' %q' "$@"
	printf '\n'
}

systemctl_user() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		print_command "$SYSTEMCTL_BIN" --user "$@"
		return 0
	fi
	"$SYSTEMCTL_BIN" --user "$@"
}

require_templates() {
	local unit
	for unit in "${UNIT_FILES[@]}"; do
		if [[ ! -f "$TEMPLATE_DIR/$unit" ]]; then
			printf 'install-timers: missing template: %s\n' "$TEMPLATE_DIR/$unit" >&2
			exit 1
		fi
	done
}

escaped_template_value() {
	local value="$1"
	if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
		printf 'install-timers: skill path contains a newline\n' >&2
		return 1
	fi
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//%/%%}"
	printf '%s' "$value" | sed 's/[\\&|]/\\&/g'
}

escaped_environment_file() {
	local value="$CONFIG_FILE"
	if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
		printf 'install-timers: config path contains a newline\n' >&2
		return 1
	fi
	value="${value//\\/\\x5c}"
	value="${value// /\\x20}"
	value="${value//$'\t'/\\x09}"
	value="${value//\"/\\x22}"
	value="${value//\'/\\x27}"
	value="${value//#/\\x23}"
	value="${value//;/\\x3b}"
	value="${value//%/%%}"
	printf '%s' "$value" | sed 's/[\\&|]/\\&/g'
}

render_unit() {
	local source="$1" root config_file
	root="$(escaped_template_value "$SKILL_ROOT")"
	config_file="$(escaped_environment_file)"
	sed -e "s|@TELE_BRAIN_ROOT@|$root|g" \
		-e "s|@TELE_BRAIN_CONFIG_FILE@|$config_file|g" "$source"
}

install_units() {
	local unit source destination temporary changed=0
	require_templates
	if [[ "$DRY_RUN" -eq 1 ]]; then
		print_command mkdir -p "$SYSTEMD_USER_DIR"
		for unit in "${UNIT_FILES[@]}"; do
			printf 'dry-run: render %s -> %s\n' "$TEMPLATE_DIR/$unit" "$SYSTEMD_USER_DIR/$unit"
		done
	else
		mkdir -p "$SYSTEMD_USER_DIR"
		for unit in "${UNIT_FILES[@]}"; do
			source="$TEMPLATE_DIR/$unit"
			destination="$SYSTEMD_USER_DIR/$unit"
			temporary="$(mktemp "$SYSTEMD_USER_DIR/.${unit}.XXXXXX")"
			if ! render_unit "$source" >"$temporary"; then
				rm -f "$temporary"
				return 1
			fi
			chmod 0644 "$temporary"
			if [[ -f "$destination" ]] && cmp -s "$temporary" "$destination"; then
				rm -f "$temporary"
				printf 'unchanged: %s\n' "$destination"
			else
				mv -f "$temporary" "$destination"
				printf 'installed: %s\n' "$destination"
				changed=1
			fi
		done
	fi

	systemctl_user daemon-reload
	systemctl_user enable --now "${TIMER_UNITS[@]}"
	if [[ "$DRY_RUN" -eq 0 ]]; then
		rm -f -- "$UPDATER_WARNING_FILE"
	fi
	if [[ "$changed" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
		printf 'install-timers: units already up to date\n'
	fi
}

uninstall_units() {
	local unit
	if ! systemctl_user disable --now "${TIMER_UNITS[@]}"; then
		printf 'install-timers: timers were not active or could not be disabled\n' >&2
	fi
	for unit in "${UNIT_FILES[@]}"; do
		if [[ "$DRY_RUN" -eq 1 ]]; then
			print_command rm -f "$SYSTEMD_USER_DIR/$unit"
		else
			rm -f "$SYSTEMD_USER_DIR/$unit"
			printf 'removed: %s\n' "$SYSTEMD_USER_DIR/$unit"
		fi
	done
	systemctl_user daemon-reload
}

show_status() {
	local unit missing=0 timer enabled_state active_state
	printf 'skill_root: %s\n' "$SKILL_ROOT"
	printf 'systemd_user_dir: %s\n' "$SYSTEMD_USER_DIR"
	for unit in "${UNIT_FILES[@]}"; do
		if [[ -f "$SYSTEMD_USER_DIR/$unit" ]]; then
			printf 'installed: %s\n' "$unit"
		else
			printf 'missing: %s\n' "$unit"
			missing=1
		fi
	done

	if ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
		printf 'systemctl: unavailable (%s)\n' "$SYSTEMCTL_BIN"
		return 1
	fi
	for timer in "${TIMER_UNITS[@]}"; do
		enabled_state="$("$SYSTEMCTL_BIN" --user is-enabled "$timer" 2>/dev/null || true)"
		active_state="$("$SYSTEMCTL_BIN" --user is-active "$timer" 2>/dev/null || true)"
		[[ -n "$enabled_state" ]] || enabled_state="unknown"
		[[ -n "$active_state" ]] || active_state="unknown"
		printf '%s: enabled=%s active=%s\n' "$timer" "$enabled_state" "$active_state"
	done
	[[ "$missing" -eq 0 ]]
}

if [[ "$ACTION" != "status" && "$DRY_RUN" -eq 0 ]] && ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
	printf 'install-timers: systemctl executable not found: %s\n' "$SYSTEMCTL_BIN" >&2
	exit 1
fi

case "$ACTION" in
install) install_units ;;
uninstall) uninstall_units ;;
status) show_status ;;
esac
