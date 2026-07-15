#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$(realpath -m -- "${TELE_BRAIN_DATA_DIR:-$HOME/.local/share/tele-brain}")"
STATE_DIR="${TELE_BRAIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tele-brain}"
INDEX_FILE="$DATA_DIR/index.yaml"
PREVIOUS_INDEX_FILE="$INDEX_FILE"
REFS_DIR="$DATA_DIR/references"
RAW_DIR="$DATA_DIR/raw_help"
GENERATIONS_DIR="$DATA_DIR/generations"
CURRENT_LINK="$DATA_DIR/current"
BUILD_DATA_DIR="$DATA_DIR"
BUILD_REFS_DIR="$REFS_DIR"
BUILD_RAW_DIR="$RAW_DIR"
LOG_FILE="$DATA_DIR/scan.log"
LOCK_FILE="${TELE_BRAIN_LOCK_FILE:-$STATE_DIR/operation.lock}"
MAX_REFERENCES="${TELE_BRAIN_MAX_REFERENCES:-25}"
MAX_CANONICAL="${TELE_BRAIN_MAX_CANONICAL:-200}"
MAX_HELP_BYTES="${TELE_BRAIN_MAX_HELP_BYTES:-1048576}"
CAPTURE_HELP="${TELE_BRAIN_CAPTURE_HELP:-0}"
SCHEMA_VERSION="1"
GENERATOR_NAME="tele-brain"
GENERATOR_COMPONENT="scan.sh"
GENERATOR_VERSION="${TELE_BRAIN_GENERATOR_VERSION:-}"
STATUS_STALE_AFTER="${TELE_BRAIN_STATUS_STALE_AFTER:-24h}"
TIMESTAMP="$(date -Iseconds)"
ACTIVE_INDEX_TMP=""
ACTIVE_REF_TMP=""
ACTIVE_RAW_TMP=""
ACTIVE_WORK_DIR=""
ACTIVE_GENERATION_DIR=""
ACTIVE_CURRENT_LINK=""

if [[ -z "$GENERATOR_VERSION" && -r "$SCRIPT_DIR/VERSION" ]]; then
	IFS= read -r GENERATOR_VERSION <"$SCRIPT_DIR/VERSION" || true
fi
GENERATOR_VERSION="${GENERATOR_VERSION:-unversioned}"

usage() {
	cat <<'EOF'
Usage:
  ./scan.sh [--refresh] [--if-stale DURATION] [--capture-help]
  ./scan.sh --status
  ./scan.sh --help

Commands:
  --refresh              Refresh the local software index (default).
  --status               Show index freshness and generator metadata.
  --help                 Show this help.

Options:
  --if-stale DURATION    Refresh only when the index is at least this old.
                         DURATION is an integer with s, m, h, d, or w suffix.
  --capture-help         Explicitly execute bounded CLI --help/-h collection.
  --no-capture-help      Disable CLI execution (default).

Environment:
  TELE_BRAIN_CAPTURE_HELP=1  Enable CLI help capture without the command option.
EOF
}

die() {
	printf 'tele-brain: %s\n' "$*" >&2
	exit 2
}

cleanup_active_temps() {
	[[ -z "$ACTIVE_INDEX_TMP" ]] || rm -f -- "$ACTIVE_INDEX_TMP"
	[[ -z "$ACTIVE_REF_TMP" ]] || rm -f -- "$ACTIVE_REF_TMP"
	[[ -z "$ACTIVE_RAW_TMP" ]] || rm -f -- "$ACTIVE_RAW_TMP"
	[[ -z "$ACTIVE_WORK_DIR" ]] || rm -rf -- "$ACTIVE_WORK_DIR"
	[[ -z "$ACTIVE_GENERATION_DIR" ]] || rm -rf -- "$ACTIVE_GENERATION_DIR"
	[[ -z "$ACTIVE_CURRENT_LINK" ]] || rm -f -- "$ACTIVE_CURRENT_LINK"
}

validate_config() {
	[[ "$MAX_REFERENCES" =~ ^[0-9]+$ ]] || die "TELE_BRAIN_MAX_REFERENCES must be a non-negative integer"
	[[ "$MAX_CANONICAL" =~ ^[0-9]+$ ]] || die "TELE_BRAIN_MAX_CANONICAL must be a non-negative integer"
	[[ "$MAX_HELP_BYTES" =~ ^[1-9][0-9]*$ ]] || die "TELE_BRAIN_MAX_HELP_BYTES must be a positive integer"
	[[ "$CAPTURE_HELP" == "0" || "$CAPTURE_HELP" == "1" ]] || die "TELE_BRAIN_CAPTURE_HELP must be 0 or 1"
}

ensure_state_dir() {
	local lock_parent mode
	mkdir -p -m 0700 -- "$STATE_DIR"
	[[ -d "$STATE_DIR" && -O "$STATE_DIR" ]] || die "state directory must be owned by the current user: $STATE_DIR"
	chmod 0700 -- "$STATE_DIR"

	lock_parent="$(dirname -- "$LOCK_FILE")"
	if [[ "$lock_parent" != "$STATE_DIR" ]]; then
		mkdir -p -m 0700 -- "$lock_parent"
		[[ -d "$lock_parent" && -O "$lock_parent" ]] || die "lock directory must be owned by the current user: $lock_parent"
		mode="$(stat -Lc '%a' -- "$lock_parent")"
		if (( (8#$mode & 0022) != 0 )); then
			die "lock directory must not be group- or world-writable: $lock_parent"
		fi
	fi
}

supports_atomic_exchange() {
	mv --help 2>/dev/null | grep -q -- '--exchange' && mv --help 2>/dev/null | grep -q -- '--no-copy'
}

install_view_link() {
	local path="$1" target="$2" temporary
	if [[ -L "$path" && "$(readlink -- "$path")" == "$target" ]]; then
		return 0
	fi
	temporary="$DATA_DIR/.${path##*/}.view.$$"
	rm -f -- "$temporary"
	ln -s -- "$target" "$temporary"
	if [[ -e "$path" || -L "$path" ]]; then
		mv -T --exchange --no-copy -- "$path" "$temporary" || {
			rm -f -- "$temporary"
			return 1
		}
		rm -rf -- "$temporary"
	else
		mv -T -- "$temporary" "$path"
	fi
}

ensure_generation_layout() {
	local current_real bootstrap generation_name generation_path link_temp
	mkdir -p -- "$DATA_DIR" "$GENERATIONS_DIR"
	supports_atomic_exchange || die "GNU mv with --exchange and --no-copy is required for atomic data generations"

	if [[ -L "$CURRENT_LINK" ]]; then
		current_real="$(realpath -e -- "$CURRENT_LINK")" || die "current data generation is missing"
		case "$current_real" in
		"$GENERATIONS_DIR"/*) ;;
		*) die "current data generation points outside $GENERATIONS_DIR" ;;
		esac
		[[ -f "$current_real/index.yaml" && -d "$current_real/references" && -d "$current_real/raw_help" ]] ||
			die "current data generation is incomplete"
	elif [[ -e "$CURRENT_LINK" ]]; then
		die "$CURRENT_LINK must be a managed symlink"
	else
		bootstrap="$(mktemp -d "$GENERATIONS_DIR/.bootstrap.XXXXXX")"
		ACTIVE_GENERATION_DIR="$bootstrap"
		mkdir -p -- "$bootstrap/references" "$bootstrap/raw_help"
		if [[ -s "$INDEX_FILE" ]]; then
			cp -pL -- "$INDEX_FILE" "$bootstrap/index.yaml"
		else
			: >"$bootstrap/index.yaml"
		fi
		if [[ -d "$REFS_DIR" ]]; then
			cp -aL -- "$REFS_DIR/." "$bootstrap/references/"
		fi
		if [[ -d "$RAW_DIR" ]]; then
			cp -aL -- "$RAW_DIR/." "$bootstrap/raw_help/"
		fi
		generation_name="bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$"
		generation_path="$GENERATIONS_DIR/$generation_name"
		mv -- "$bootstrap" "$generation_path"
		ACTIVE_GENERATION_DIR=""
		link_temp="$DATA_DIR/.current.$$"
		rm -f -- "$link_temp"
		ln -s -- "generations/$generation_name" "$link_temp"
		mv -T -- "$link_temp" "$CURRENT_LINK"
	fi

	install_view_link "$RAW_DIR" 'current/raw_help' || die "could not install raw_help generation view"
	install_view_link "$REFS_DIR" 'current/references' || die "could not install references generation view"
	install_view_link "$INDEX_FILE" 'current/index.yaml' || die "could not install index generation view"
}

log() {
	printf '%s %s\n' "$TIMESTAMP" "$*" >>"$LOG_FILE"
}

with_lock() {
	if [[ "${TELE_BRAIN_LOCK_HELD:-}" == "1" ]]; then
		"$@"
		return
	fi

	ensure_state_dir
	command -v flock >/dev/null 2>&1 || die "flock is required"
	exec 9>>"$LOCK_FILE"
	chmod 0600 -- "$LOCK_FILE"
	if ! flock -n 9; then
		[[ -d "$DATA_DIR" ]] && log "scan skipped: operation lock is held"
		echo "tele-brain: operation lock is held, skipped"
		return 0
	fi
	"$@"
}

parse_duration() {
	local value="$1" amount suffix multiplier
	if [[ ! "$value" =~ ^([0-9]+)([smhdw]?)$ ]]; then
		return 1
	fi
	amount="$((10#${BASH_REMATCH[1]}))"
	suffix="${BASH_REMATCH[2]}"
	case "$suffix" in
	'' | s) multiplier=1 ;;
	m) multiplier=60 ;;
	h) multiplier=3600 ;;
	d) multiplier=86400 ;;
	w) multiplier=604800 ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$((amount * multiplier))"
}

index_age_seconds() {
	local modified now age last_scan
	[[ -s "$INDEX_FILE" ]] || {
		printf '%s\n' -1
		return
	}
	last_scan="$(sed -n 's/^last_scan: "\(.*\)"$/\1/p' "$INDEX_FILE" | head -1)"
	if [[ -n "$last_scan" ]]; then
		modified="$(date -d "$last_scan" +%s 2>/dev/null || true)"
		[[ "$modified" =~ ^[0-9]+$ ]] || {
			printf '%s\n' -1
			return
		}
	else
		modified="$(stat -Lc '%Y' -- "$INDEX_FILE")"
	fi
	now="$(date +%s)"
	age="$((now - modified))"
	((age < 0)) && age=0
	printf '%s\n' "$age"
}

is_index_stale() {
	local threshold="$1" age
	age="$(index_age_seconds)"
	((age < 0 || age >= threshold))
}

index_value() {
	local key="$1"
	sed -n "s/^${key}: \"\(.*\)\"$/\1/p" "$INDEX_FILE" | head -1
}

generator_version_from_index() {
	awk '
		/^generator:/ { in_generator=1; next }
		in_generator && /^  version: / {
			sub(/^  version: "/, "")
			sub(/"$/, "")
			print
			exit
		}
		in_generator && /^[^ ]/ { exit }
	' "$INDEX_FILE"
}

show_status() {
	local age stale_seconds status last_scan schema generator_version
	stale_seconds="$(parse_duration "$STATUS_STALE_AFTER")" || die "invalid TELE_BRAIN_STATUS_STALE_AFTER: $STATUS_STALE_AFTER"
	if [[ ! -s "$INDEX_FILE" ]]; then
		printf 'status=missing\nindex=%s\nage_seconds=-1\nstale_after_seconds=%s\n' "$INDEX_FILE" "$stale_seconds"
		return 0
	fi

	age="$(index_age_seconds)"
	status="fresh"
	((age < 0 || age >= stale_seconds)) && status="stale"
	last_scan="$(index_value last_scan)"
	schema="$(sed -n 's/^schema_version: //p' "$INDEX_FILE" | head -1)"
	generator_version="$(generator_version_from_index)"
	printf 'status=%s\n' "$status"
	printf 'index=%s\n' "$INDEX_FILE"
	printf 'last_scan=%s\n' "${last_scan:-unknown}"
	printf 'age_seconds=%s\n' "$age"
	printf 'stale_after_seconds=%s\n' "$stale_seconds"
	printf 'schema_version=%s\n' "${schema:-unknown}"
	printf 'generator=%s\n' "$GENERATOR_NAME"
	printf 'generator_version=%s\n' "${generator_version:-unknown}"
}

safe_id() {
	local input="$1" sanitized digest
	sanitized="$(printf '%s' "$input" | tr '/: ' '___' | tr -cd '[:alnum:]_.#-')"
	if [[ -n "$sanitized" && "$sanitized" == "$input" && ${#sanitized} -le 180 ]]; then
		printf '%s' "$sanitized"
		return
	fi
	digest="$(printf '%s' "$input" | sha256sum | awk '{print tolower($1)}')"
	[[ -n "$sanitized" ]] || sanitized="id"
	printf '%s-%s' "${sanitized:0:160}" "${digest:0:16}"
}

legacy_safe_id() {
	printf '%s' "$1" | tr '/: ' '___' | tr -cd '[:alnum:]_.#-'
}

previous_entry_has_path() {
	local key="$1" field="$2" path="$3" expected_id expected_path
	[[ -s "$PREVIOUS_INDEX_FILE" ]] || return 1
	expected_id="  - id: \"$(quote_yaml "$key")\""
	case "$field" in
	reference|raw_help) ;;
	*) return 1 ;;
	esac
	expected_path="    $field: \"$(quote_yaml "$path")\""
	EXPECTED_ID_LINE="$expected_id" EXPECTED_PATH_LINE="$expected_path" awk '
		/^  - id: / {
			in_entry = ($0 == ENVIRON["EXPECTED_ID_LINE"])
			next
		}
		in_entry && $0 == ENVIRON["EXPECTED_PATH_LINE"] { found = 1; exit }
		END { exit(found ? 0 : 1) }
	' "$PREVIOUS_INDEX_FILE"
}

hash_file() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || printf unknown
}

executable_fingerprint() {
	local canonical="$1" version="$2" metadata
	[[ -n "$canonical" && -e "$canonical" ]] || return 1
	metadata="$(stat -Lc '%d:%i:%s:%Y' -- "$canonical")" || return 1
	printf '%s\n%s\n' "$version" "$metadata" | sha256sum | awk '{print tolower($1)}'
}

write_help_metadata() {
	local metadata_path="$1" fingerprint="$2" temporary
	temporary="$(mktemp "$BUILD_RAW_DIR/.${metadata_path##*/}.tmp.XXXXXX")" || return 1
	if ! printf '%s\n' "$fingerprint" >"$temporary"; then
		rm -f -- "$temporary"
		return 1
	fi
	chmod 0644 -- "$temporary" || {
		rm -f -- "$temporary"
		return 1
	}
	if ! mv -f -- "$temporary" "$metadata_path"; then
		rm -f -- "$temporary"
		return 1
	fi
}

quote_yaml() {
	local value="$1"
	value="$(printf '%s' "$value" | tr '[:cntrl:]' ' ')"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '%s' "$value"
}

version_for() {
	local name="$1" source="$2" path="${3:-}"
	case "$source" in
	apt) dpkg-query -W -f='${Version}' "$name" 2>/dev/null || true ;;
	snap) snap list "$name" 2>/dev/null | awk 'NR==2{print $2}' ;;
	flatpak) flatpak info "$name" 2>/dev/null | awk -F: '/^Version:/{gsub(/^ +/,"",$2); print $2; exit}' ;;
	pip-user | pip-global | npm | brew) printf '%s' "$path" ;;
	cargo) printf unknown ;;
	path | manual | gui | plugin-browser | plugin-ide) printf unknown ;;
	*) printf unknown ;;
	esac
}

write_reference() {
	local name="$1" version="$2" source="$3" type="$4" raw_rel="$5" ref_path="$6" desc="$7"
	local ref_tmp
	ref_tmp="$(mktemp "$(dirname -- "$ref_path")/.${ref_path##*/}.tmp.XXXXXX")"
	ACTIVE_REF_TMP="$ref_tmp"
	if {
		printf '# %s\n\n' "$name"
		printf '## Version\n%s\n\n' "${version:-unknown}"
		printf '## Description\n%s\n\n' "${desc:-No description captured yet.}"
		printf '## Usage\n'
		if [[ -n "$raw_rel" && -f "$BUILD_DATA_DIR/$raw_rel" ]]; then
			sed -n '1,120p' "$BUILD_DATA_DIR/$raw_rel"
		else
			printf 'No local help output captured.\n'
		fi
		printf '\n## Common Commands\n'
		if [[ -n "$raw_rel" && -f "$BUILD_DATA_DIR/$raw_rel" ]]; then
			grep -E '^  (-|--|[[:alnum:]_.-]+[[:space:]])' "$BUILD_DATA_DIR/$raw_rel" | head -40 || true
		else
			printf '%s\n' '- See official documentation.'
		fi
		printf '\n## Source\nsource: %s\ntype: %s\n' "$source" "$type"
	} >"$ref_tmp"; then
		chmod 0644 -- "$ref_tmp" || {
			rm -f -- "$ref_tmp"
			ACTIVE_REF_TMP=""
			return 1
		}
		if ! mv -f -- "$ref_tmp" "$ref_path"; then
			rm -f -- "$ref_tmp"
			ACTIVE_REF_TMP=""
			return 1
		fi
		ACTIVE_REF_TMP=""
	else
		rm -f -- "$ref_tmp"
		ACTIVE_REF_TMP=""
		return 1
	fi
}

capture_help() {
	local cmd="$1" raw_path="$2" work_dir raw_tmp file_blocks actual_size capture_succeeded=0
	[[ "$CAPTURE_HELP" == "1" ]] || return 1
	work_dir="$(mktemp -d "$STATE_DIR/help.XXXXXX")"
	ACTIVE_WORK_DIR="$work_dir"
	raw_tmp="$(mktemp "$BUILD_RAW_DIR/.${raw_path##*/}.tmp.XXXXXX")"
	ACTIVE_RAW_TMP="$raw_tmp"
	file_blocks="$(((MAX_HELP_BYTES + 1023) / 1024))"
	if (
		cd "$work_dir"
		ulimit -f "$file_blocks"
		timeout --kill-after=2s 8s "$cmd" --help >"$raw_tmp" 2>&1 ||
			timeout --kill-after=2s 8s "$cmd" -h >"$raw_tmp" 2>&1
	) 2>/dev/null; then
		capture_succeeded=1
	fi
	rm -rf -- "$work_dir"
	ACTIVE_WORK_DIR=""
	actual_size="$(stat -c '%s' -- "$raw_tmp" 2>/dev/null || printf 0)"
	if [[ "$capture_succeeded" == 1 && -s "$raw_tmp" && "$actual_size" -le "$MAX_HELP_BYTES" ]]; then
		chmod 0644 -- "$raw_tmp" || {
			rm -f -- "$raw_tmp"
			ACTIVE_RAW_TMP=""
			return 1
		}
		if ! mv -f -- "$raw_tmp" "$raw_path"; then
			rm -f -- "$raw_tmp"
			ACTIVE_RAW_TMP=""
			return 1
		fi
		ACTIVE_RAW_TMP=""
		return 0
	fi
	rm -f -- "$raw_tmp"
	ACTIVE_RAW_TMP=""
	return 1
}

declare -A NAME VERSION SOURCE TYPE PATH_HINT DESC

reset_entries() {
	NAME=()
	VERSION=()
	SOURCE=()
	TYPE=()
	PATH_HINT=()
	DESC=()
}

add_entry() {
	local key="$1" name="$2" version="$3" source="$4" type="$5" path_hint="${6:-}" desc="${7:-}"
	[[ ! "$key" =~ [[:cntrl:]] ]] || return 0
	NAME["$key"]="$name"
	VERSION["$key"]="${version:-unknown}"
	SOURCE["$key"]="$source"
	TYPE["$key"]="$type"
	PATH_HINT["$key"]="$path_hint"
	DESC["$key"]="$desc"
}

scan_apt() {
	local output name version
	command -v dpkg-query >/dev/null 2>&1 || return 0
	output="$(dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null)" || return 1
	while IFS=$'\t' read -r name version; do
		[[ -n "$name" ]] && add_entry "$name#apt" "$name" "$version" apt cli ""
	done <<<"$output"
}

scan_snap() {
	local output name version
	command -v snap >/dev/null 2>&1 || return 0
	output="$(snap list 2>/dev/null | awk 'NR>1{print $1"\t"$2}')" || return 1
	while IFS=$'\t' read -r name version; do
		[[ -n "$name" ]] && add_entry "$name#snap" "$name" "$version" snap gui ""
	done <<<"$output"
}

scan_flatpak() {
	local output app name version
	command -v flatpak >/dev/null 2>&1 || return 0
	output="$(flatpak list --app --columns=application,name,version 2>/dev/null)" || return 1
	while IFS=$'\t' read -r app name version; do
		[[ -n "$app" ]] && add_entry "$app#flatpak" "$app" "${version:-unknown}" flatpak gui "" "$name"
	done <<<"$output"
}

scan_pip() {
	local output name unused version
	command -v pip >/dev/null 2>&1 || return 0
	output="$(PIP_DISABLE_PIP_VERSION_CHECK=1 pip list --user --format=freeze 2>/dev/null)" || return 1
	while IFS='=' read -r name unused version; do
		[[ -n "$name" ]] && add_entry "$name#pip-user" "$name" "${version:-unknown}" pip-user cli ""
	done <<<"$output"

	output="$(PIP_DISABLE_PIP_VERSION_CHECK=1 pip list --format=freeze 2>/dev/null)" || return 1
	while IFS='=' read -r name unused version; do
		[[ -n "$name" ]] && add_entry "$name#pip-global" "$name" "${version:-unknown}" pip-global cli ""
	done <<<"$output"
}

scan_npm() {
	local output pkg name
	command -v npm >/dev/null 2>&1 || return 0
	output="$(npm list -g --depth=0 --parseable 2>/dev/null | tail -n +2)" || return 1
	while IFS= read -r pkg; do
		name="$(basename -- "$pkg")"
		[[ -n "$name" ]] && add_entry "$name#npm" "$name" unknown npm cli "$pkg"
	done <<<"$output"
}

scan_cargo() {
	local output name
	command -v cargo >/dev/null 2>&1 || return 0
	output="$(cargo install --list 2>/dev/null | awk '/^[^ ].*:$/ {gsub(":", "", $1); print $1}')" || return 1
	while IFS= read -r name; do
		[[ -n "$name" ]] && add_entry "$name#cargo" "$name" unknown cargo cli ""
	done <<<"$output"
}

scan_brew() {
	local output name version unused
	command -v brew >/dev/null 2>&1 || return 0
	output="$(brew list --versions 2>/dev/null)" || return 1
	while read -r name version unused; do
		[[ -n "$name" ]] && add_entry "$name#brew" "$name" "${version:-unknown}" brew cli ""
	done <<<"$output"
}

scan_path() {
	local dir file name path_key
	local -a dirs
	IFS=: read -ra dirs <<<"${PATH:-}"
	dirs+=("$HOME/.local/bin" "/opt")
	for dir in "${dirs[@]}"; do
		[[ -d "$dir" ]] || continue
		while IFS= read -r -d '' file; do
			[[ -x "$file" && ! -d "$file" ]] || continue
			name="$(basename -- "$file")"
			path_key="$(safe_id "$file")"
			add_entry "$name#path-$path_key" "$name" unknown path cli "$file"
		done < <(find "$dir" -maxdepth 2 -type f -print0 2>/dev/null | head -z -n 2000)
	done
}

scan_gui_desktop() {
	local desktop name app_id
	for desktop in /usr/share/applications/*.desktop "$HOME"/.local/share/applications/*.desktop; do
		[[ -f "$desktop" ]] || continue
		app_id="$(basename -- "$desktop" .desktop)"
		name="$(awk -F= '/^Name=/{print $2; exit}' "$desktop")"
		add_entry "$app_id#desktop" "$app_id" unknown gui gui "$desktop" "$name"
	done
}

scan_browser_plugins() {
	local base ext name
	for base in "$HOME/.config/google-chrome" "$HOME/.config/chromium" "$HOME/.mozilla/firefox"; do
		[[ -d "$base" ]] || continue
		while IFS= read -r -d '' ext; do
			name="$(basename -- "$ext")"
			add_entry "$name#plugin-browser" "$name" unknown plugin-browser plugin-browser "$ext"
		done < <(find "$base" -path '*Extensions/*' -type d -mindepth 3 -maxdepth 5 -print0 2>/dev/null | head -z -n 500)
	done
}

scan_ide_plugins() {
	local dir item name
	for dir in "$HOME/.vscode/extensions" "$HOME/.var/app/com.visualstudio.code/config/Code/User/extensions" "$HOME/.local/share/JetBrains"; do
		[[ -d "$dir" ]] || continue
		while IFS= read -r -d '' item; do
			name="$(basename -- "$item")"
			add_entry "$name#plugin-ide" "$name" unknown plugin-ide plugin-ide "$item"
		done < <(find "$dir" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null | head -z -n 500)
	done
}

SCAN_CANONICAL_COUNT=0
SCAN_CANONICAL_CHECKED=0
SCAN_REFERENCE_COUNT=0
SCAN_NEW_REFERENCE_COUNT=0
SCAN_HELP_CAPTURE_COUNT=0
SCAN_HELP_ATTEMPT_COUNT=0

generate_index() {
	local key name source type version path_hint canonical raw_rel ref_rel safe raw_path ref_path help_hash status desc
	local raw_candidate existing_ref fingerprint metadata_path previous_fingerprint reference_stale legacy_safe
	declare -A legacy_counts=()
	SCAN_CANONICAL_COUNT=0
	SCAN_CANONICAL_CHECKED=0
	SCAN_REFERENCE_COUNT=0
	SCAN_NEW_REFERENCE_COUNT=0
	SCAN_HELP_CAPTURE_COUNT=0
	SCAN_HELP_ATTEMPT_COUNT=0
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		legacy_safe="$(legacy_safe_id "$key")"
		[[ -n "$legacy_safe" ]] || continue
		legacy_counts["$legacy_safe"]=$(( ${legacy_counts["$legacy_safe"]:-0} + 1 ))
	done < <(
		if ((${#NAME[@]} > 0)); then
			printf '%s\n' "${!NAME[@]}" | sort
		fi
	)

	printf '# tele-brain index - auto-generated %s\n' "$TIMESTAMP"
	printf 'schema_version: %s\n' "$SCHEMA_VERSION"
	printf 'generator:\n'
	printf '  name: "%s"\n' "$(quote_yaml "$GENERATOR_NAME")"
	printf '  component: "%s"\n' "$(quote_yaml "$GENERATOR_COMPONENT")"
	printf '  version: "%s"\n' "$(quote_yaml "$GENERATOR_VERSION")"
	printf '  generated_at: "%s"\n' "$TIMESTAMP"
	printf 'last_scan: "%s"\n' "$TIMESTAMP"
	printf 'entries:\n'
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		name="${NAME[$key]}"
		source="${SOURCE[$key]}"
		type="${TYPE[$key]}"
		version="${VERSION[$key]}"
		path_hint="${PATH_HINT[$key]}"
		desc="${DESC[$key]}"
		canonical=""
		if [[ "$type" == cli ]]; then
			if [[ -f "$path_hint" && -x "$path_hint" ]]; then
				canonical="$path_hint"
			elif [[ "$SCAN_CANONICAL_CHECKED" -lt "$MAX_CANONICAL" ]]; then
				canonical="$(command -v "$name" 2>/dev/null || true)"
				[[ -f "$canonical" && -x "$canonical" ]] || canonical=""
				SCAN_CANONICAL_CHECKED=$((SCAN_CANONICAL_CHECKED + 1))
			fi
		fi
		status="active"
		safe="$(safe_id "$key")"
		raw_rel=""
		help_hash="unknown"
		ref_rel=""
		reference_stale="false"
		ref_path="$BUILD_REFS_DIR/$safe.md"
		legacy_safe="$(legacy_safe_id "$key")"
		if [[ -n "$legacy_safe" && "$safe" != "$legacy_safe" && "${legacy_counts["$legacy_safe"]:-0}" == 1 ]]; then
			if [[ ! -e "$ref_path" && -f "$BUILD_REFS_DIR/$legacy_safe.md" ]] &&
				previous_entry_has_path "$key" reference "references/$legacy_safe.md"; then
				cp -p -- "$BUILD_REFS_DIR/$legacy_safe.md" "$ref_path"
			fi
			if [[ "$type" == cli ]]; then
				if [[ ! -e "$BUILD_DATA_DIR/raw_help/$safe.txt" && -f "$BUILD_DATA_DIR/raw_help/$legacy_safe.txt" ]] &&
					previous_entry_has_path "$key" raw_help "raw_help/$legacy_safe.txt"; then
					cp -p -- "$BUILD_DATA_DIR/raw_help/$legacy_safe.txt" "$BUILD_DATA_DIR/raw_help/$safe.txt"
					if [[ ! -e "$BUILD_RAW_DIR/$safe.meta" && -f "$BUILD_RAW_DIR/$legacy_safe.meta" ]]; then
						cp -p -- "$BUILD_RAW_DIR/$legacy_safe.meta" "$BUILD_RAW_DIR/$safe.meta"
					fi
				fi
			fi
		fi
		existing_ref=0
		[[ -f "$ref_path" ]] && existing_ref=1

		if [[ "$type" == "cli" ]]; then
			raw_candidate="raw_help/$safe.txt"
			raw_path="$BUILD_DATA_DIR/$raw_candidate"
			metadata_path="$BUILD_RAW_DIR/$safe.meta"
			fingerprint=""
			previous_fingerprint=""
			if [[ -n "$canonical" && -e "$canonical" ]]; then
				fingerprint="$(executable_fingerprint "$canonical" "$version" || true)"
			fi
			if [[ -s "$metadata_path" ]]; then
				IFS= read -r previous_fingerprint <"$metadata_path" || true
			fi
			if [[ -s "$raw_path" ]]; then
				raw_rel="$raw_candidate"
				if [[ -z "$fingerprint" || "$fingerprint" != "$previous_fingerprint" ]]; then
					reference_stale="true"
				fi
			fi
			if [[ "$CAPTURE_HELP" == "1" && "$reference_stale" == "true" && -n "$canonical" && -f "$canonical" && -x "$canonical" && "$SCAN_HELP_ATTEMPT_COUNT" -lt "$MAX_REFERENCES" ]]; then
				SCAN_HELP_ATTEMPT_COUNT=$((SCAN_HELP_ATTEMPT_COUNT + 1))
				if capture_help "$canonical" "$raw_path"; then
					raw_rel="$raw_candidate"
					write_help_metadata "$metadata_path" "$fingerprint" || return 1
					reference_stale="false"
					SCAN_HELP_CAPTURE_COUNT=$((SCAN_HELP_CAPTURE_COUNT + 1))
				fi
			elif [[ ! -s "$raw_path" && "$CAPTURE_HELP" == "1" && -n "$canonical" && -f "$canonical" && -x "$canonical" && "$SCAN_HELP_ATTEMPT_COUNT" -lt "$MAX_REFERENCES" ]]; then
				SCAN_HELP_ATTEMPT_COUNT=$((SCAN_HELP_ATTEMPT_COUNT + 1))
				if capture_help "$canonical" "$raw_path"; then
					raw_rel="$raw_candidate"
					write_help_metadata "$metadata_path" "$fingerprint" || return 1
					reference_stale="false"
					SCAN_HELP_CAPTURE_COUNT=$((SCAN_HELP_CAPTURE_COUNT + 1))
				fi
			fi
			[[ -n "$raw_rel" ]] && help_hash="$(hash_file "$raw_path")"

			if [[ "$reference_stale" == "true" && "$existing_ref" == "1" ]]; then
				ref_rel="references/$safe.md"
			elif [[ "$CAPTURE_HELP" == "0" && "$existing_ref" == "1" ]]; then
				ref_rel="references/$safe.md"
			elif [[ -n "$raw_rel" && ( "$existing_ref" == 1 || "$SCAN_NEW_REFERENCE_COUNT" -lt "$MAX_REFERENCES" ) ]]; then
				write_reference "$name" "$version" "$source" "$type" "$raw_rel" "$ref_path" "$desc" || return 1
				ref_rel="references/$safe.md"
				SCAN_REFERENCE_COUNT=$((SCAN_REFERENCE_COUNT + 1))
				if [[ "$existing_ref" == 0 ]]; then
					SCAN_NEW_REFERENCE_COUNT=$((SCAN_NEW_REFERENCE_COUNT + 1))
				fi
			elif [[ "$existing_ref" == "1" ]]; then
				ref_rel="references/$safe.md"
			elif [[ "$CAPTURE_HELP" == "1" && "$SCAN_NEW_REFERENCE_COUNT" -lt "$MAX_REFERENCES" ]]; then
				write_reference "$name" "$version" "$source" "$type" "" "$ref_path" "$desc" || return 1
				ref_rel="references/$safe.md"
				SCAN_REFERENCE_COUNT=$((SCAN_REFERENCE_COUNT + 1))
				SCAN_NEW_REFERENCE_COUNT=$((SCAN_NEW_REFERENCE_COUNT + 1))
			else
				reference_stale="true"
			fi
		elif [[ "$existing_ref" == 1 || "$SCAN_NEW_REFERENCE_COUNT" -lt "$MAX_REFERENCES" ]]; then
			write_reference "$name" "$version" "$source" "$type" "" "$ref_path" "$desc" || return 1
			ref_rel="references/$safe.md"
			SCAN_REFERENCE_COUNT=$((SCAN_REFERENCE_COUNT + 1))
			if [[ "$existing_ref" == 0 ]]; then
				SCAN_NEW_REFERENCE_COUNT=$((SCAN_NEW_REFERENCE_COUNT + 1))
			fi
		elif [[ "$existing_ref" == "1" ]]; then
			ref_rel="references/$safe.md"
		fi

		[[ -n "$canonical" ]] && SCAN_CANONICAL_COUNT=$((SCAN_CANONICAL_COUNT + 1))
		printf '  - id: "%s"\n' "$(quote_yaml "$key")"
		printf '    name: "%s"\n' "$(quote_yaml "$name")"
		printf '    version: "%s"\n' "$(quote_yaml "$version")"
		printf '    source: "%s"\n' "$(quote_yaml "$source")"
		printf '    type: "%s"\n' "$(quote_yaml "$type")"
		printf '    canonical_path: "%s"\n' "$(quote_yaml "$canonical")"
		printf '    help_hash: "%s"\n' "$(quote_yaml "$help_hash")"
		printf '    reference: "%s"\n' "$(quote_yaml "$ref_rel")"
		printf '    reference_stale: %s\n' "$reference_stale"
		printf '    raw_help: "%s"\n' "$(quote_yaml "$raw_rel")"
		printf '    status: "%s"\n' "$status"
		printf '    last_checked: "%s"\n' "$TIMESTAMP"
	done < <(
		if ((${#NAME[@]} > 0)); then
			printf '%s\n' "${!NAME[@]}" | sort
		fi
	)
}

write_index() {
	local index_tmp
	index_tmp="$(mktemp "$BUILD_DATA_DIR/.index.yaml.tmp.XXXXXX")"
	ACTIVE_INDEX_TMP="$index_tmp"
	if generate_index >"$index_tmp"; then
		chmod 0644 -- "$index_tmp"
		mv -f -- "$index_tmp" "$BUILD_DATA_DIR/index.yaml"
		ACTIVE_INDEX_TMP=""
	else
		rm -f -- "$index_tmp"
		ACTIVE_INDEX_TMP=""
		return 1
	fi
}

prepare_generation() {
	local current_real
	ensure_generation_layout
	current_real="$(realpath -e -- "$CURRENT_LINK")" || die "current data generation is missing"
	PREVIOUS_INDEX_FILE="$current_real/index.yaml"
	ACTIVE_GENERATION_DIR="$(mktemp -d "$GENERATIONS_DIR/.staging.XXXXXX")"
	mkdir -p -- "$ACTIVE_GENERATION_DIR/references" "$ACTIVE_GENERATION_DIR/raw_help"
	cp -a -- "$current_real/references/." "$ACTIVE_GENERATION_DIR/references/"
	cp -a -- "$current_real/raw_help/." "$ACTIVE_GENERATION_DIR/raw_help/"
	BUILD_DATA_DIR="$ACTIVE_GENERATION_DIR"
	BUILD_REFS_DIR="$ACTIVE_GENERATION_DIR/references"
	BUILD_RAW_DIR="$ACTIVE_GENERATION_DIR/raw_help"
}

prune_generations() {
	local current_real path kept=0
	current_real="$(realpath -e -- "$CURRENT_LINK")" || return 0
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		if [[ "$path" == "$current_real" ]]; then
			continue
		fi
		if (( kept < 2 )); then
			kept=$((kept + 1))
		else
			rm -rf -- "$path"
		fi
	done < <(
		find "$GENERATIONS_DIR" -mindepth 1 -maxdepth 1 -type d \
			\( -name 'generation-*' -o -name 'bootstrap-*' \) -printf '%T@ %p\n' 2>/dev/null |
			sort -nr | sed 's/^[^ ]* //'
	)
}

activate_generation() {
	local generation_name generation_path link_temp generation_nonce
	generation_nonce="${ACTIVE_GENERATION_DIR##*.}"
	generation_name="generation-$(date -u +%Y%m%dT%H%M%SZ)-$$-$generation_nonce"
	generation_path="$GENERATIONS_DIR/$generation_name"
	[[ ! -e "$generation_path" ]] || die "generation path already exists: $generation_path"
	mv -T -- "$ACTIVE_GENERATION_DIR" "$generation_path"
	ACTIVE_GENERATION_DIR=""
	link_temp="$DATA_DIR/.current.next.$$"
	ACTIVE_CURRENT_LINK="$link_temp"
	rm -f -- "$link_temp"
	ln -s -- "generations/$generation_name" "$link_temp"
	mv -Tf -- "$link_temp" "$CURRENT_LINK"
	ACTIVE_CURRENT_LINK=""
	prune_generations
}

refresh_index() {
	ensure_state_dir
	validate_config
	prepare_generation
	TIMESTAMP="$(date -Iseconds)"
	reset_entries

	scan_apt || log "apt scan failed"
	scan_snap || log "snap scan failed"
	scan_flatpak || log "flatpak scan failed"
	scan_pip || log "pip scan failed"
	scan_npm || log "npm scan failed"
	scan_cargo || log "cargo scan failed"
	scan_brew || log "brew scan failed"
	scan_path || log "path scan failed"
	scan_gui_desktop || log "gui scan failed"
	scan_browser_plugins || log "browser plugin scan failed"
	scan_ide_plugins || log "ide plugin scan failed"

	if ! write_index; then
		rm -rf -- "$ACTIVE_GENERATION_DIR"
		ACTIVE_GENERATION_DIR=""
		return 1
	fi
	activate_generation
	log "scan complete: entries=${#NAME[@]} canonical=$SCAN_CANONICAL_COUNT canonical_checked=$SCAN_CANONICAL_CHECKED references=$SCAN_REFERENCE_COUNT new_references=$SCAN_NEW_REFERENCE_COUNT help_attempts=$SCAN_HELP_ATTEMPT_COUNT help_captures=$SCAN_HELP_CAPTURE_COUNT max_references=$MAX_REFERENCES capture_help=$CAPTURE_HELP schema=$SCHEMA_VERSION generator=$GENERATOR_VERSION index=$INDEX_FILE"
	echo "tele-brain: indexed ${#NAME[@]} entries -> $INDEX_FILE"
}

refresh_if_stale() {
	local stale_seconds="$1"
	if ! is_index_stale "$stale_seconds"; then
		echo "tele-brain: index is fresh, skipped"
		return 0
	fi
	refresh_index
}

run_cli() {
	local command="refresh" stale_value="" stale_seconds
	while (($# > 0)); do
		case "$1" in
		--help | -h)
			usage
			return 0
			;;
		--status)
			command="status"
			shift
			;;
		--refresh)
			command="refresh"
			shift
			;;
		--if-stale)
			(($# >= 2)) || die "--if-stale requires a duration"
			stale_value="$2"
			shift 2
			;;
		--capture-help)
			CAPTURE_HELP=1
			shift
			;;
		--no-capture-help)
			CAPTURE_HELP=0
			shift
			;;
		*) die "unknown argument: $1" ;;
		esac
	done

	validate_config
	if [[ "$command" == "status" ]]; then
		[[ -z "$stale_value" ]] || die "--if-stale can only be used with --refresh"
		show_status
		return
	fi

	if [[ -n "$stale_value" ]]; then
		stale_seconds="$(parse_duration "$stale_value")" || die "invalid duration: $stale_value"
		with_lock refresh_if_stale "$stale_seconds"
	else
		with_lock refresh_index
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	trap cleanup_active_temps EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	run_cli "$@"
fi
