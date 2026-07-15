#!/usr/bin/env bash
set -euo pipefail

umask 077
export LC_ALL=C

PROGRAM="tele-brain-update"
DEFAULT_MANIFEST_URL="${TELE_BRAIN_DEFAULT_MANIFEST_URL:-https://raw.githubusercontent.com/A-Lucious/pi-skills/master/tele-brain/release-manifest.json}"
DEFAULT_MANIFEST_SIGNATURE_URL="${DEFAULT_MANIFEST_URL}.sig"
SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)"
INSTALL_DIR="${TELE_BRAIN_INSTALL_DIR:-$SCRIPT_DIR}"
STATE_DIR="${TELE_BRAIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tele-brain}"
CACHE_DIR="${TELE_BRAIN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/tele-brain}"
MANIFEST_URL="${TELE_BRAIN_MANIFEST_URL:-$DEFAULT_MANIFEST_URL}"
MANIFEST_URL_EXPLICIT=0
[[ -v TELE_BRAIN_MANIFEST_URL ]] && MANIFEST_URL_EXPLICIT=1
LOCAL_BOOTSTRAP_MANIFEST="$SCRIPT_DIR/release-manifest.json"
OPENSSL_PUBKEY_FILE="${TELE_BRAIN_OPENSSL_PUBKEY_FILE:-$SCRIPT_DIR/keys/release-public.pem}"
UPDATE_LOCK_FILE="${TELE_BRAIN_UPDATE_LOCK_FILE:-$STATE_DIR/update.lock}"
OPERATION_LOCK_FILE="${TELE_BRAIN_LOCK_FILE:-$STATE_DIR/operation.lock}"
STATE_FILE="$STATE_DIR/update-state.json"
PENDING_FILE="$STATE_DIR/update-pending.json"
TIMER_WARNING_FILE="$STATE_DIR/timer-refresh-required.json"
MANIFEST_SOURCE_KEY="$(printf '%s' "$MANIFEST_URL" | sha256sum | awk '{print tolower($1)}')"
CACHED_MANIFEST="$CACHE_DIR/manifests/${MANIFEST_SOURCE_KEY:0:24}.json"
MAX_MANIFEST_SIZE="${TELE_BRAIN_MAX_MANIFEST_SIZE:-1048576}"
MAX_ARTIFACT_SIZE="${TELE_BRAIN_MAX_ARTIFACT_SIZE:-104857600}"
MAX_EXTRACTED_SIZE="${TELE_BRAIN_MAX_EXTRACTED_SIZE:-268435456}"
MAX_ARCHIVE_ENTRIES="${TELE_BRAIN_MAX_ARCHIVE_ENTRIES:-10000}"
MAX_ARCHIVE_LISTING_BYTES="${TELE_BRAIN_MAX_ARCHIVE_LISTING_BYTES:-16777216}"
LOCK_TIMEOUT="${TELE_BRAIN_UPDATE_LOCK_TIMEOUT:-30}"
NETWORK_TIMEOUT="${TELE_BRAIN_UPDATE_NETWORK_TIMEOUT:-120}"
AUTO_MODE=0
OFFLINE_MODE=0
ALLOW_DOWNGRADE=0
AUTO_APPLY_POLICY="${TELE_BRAIN_AUTO_APPLY:-off}"
UPDATE_FD=""
OPERATION_FD=""
TEMP_PATHS=()
LAST_MANIFEST_SIGNED=0
LAST_ARTIFACT_SIGNED=0
LAST_MANIFEST_SOURCE="$MANIFEST_URL"

log() {
	printf '%s: %s\n' "$PROGRAM" "$*" >&2
}

die() {
	log "$*"
	exit 1
}

cleanup() {
	local path
	for path in "${TEMP_PATHS[@]:-}"; do
		if [[ -n "$path" && ( -e "$path" || -L "$path" ) ]]; then
			rm -rf -- "$path"
		fi
	done
}

forget_temp_path() {
	local forgotten="$1" path
	local -a retained=()
	for path in "${TEMP_PATHS[@]:-}"; do
		[[ -n "$path" && "$path" == "$forgotten" ]] || retained+=("$path")
	done
	TEMP_PATHS=("${retained[@]:-}")
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
	cat <<'EOF'
Usage: update.sh check|apply|scheduled|status|rollback [options]

Commands:
  check, --check       Check the configured manifest for an update.
  apply, --apply       Download, verify, and activate the update.
  scheduled            Check, or apply a signed patch when explicitly enabled.
  status, --status     Show local updater state.
  rollback, --rollback Restore the previous installation.

Options:
  --auto               Non-interactive apply; requires a trusted signature.
  --offline            Use the last cached manifest and artifact.
  --allow-downgrade    Permit a manual downgrade to a signed/hashed artifact.
  -h, --help           Show this help.

Environment:
  TELE_BRAIN_MANIFEST_URL            HTTPS or file:// release manifest.
  TELE_BRAIN_STATE_DIR               External updater state directory.
  TELE_BRAIN_CACHE_DIR               External download cache directory.
  TELE_BRAIN_LOCK_FILE               Shared scan/update operation lock.
  TELE_BRAIN_MINISIGN_PUBKEY_FILE    Trusted Minisign public key.
  TELE_BRAIN_OPENSSL_PUBKEY_FILE     Override the bundled trusted PEM public key.
  TELE_BRAIN_MANIFEST_SIGNATURE_URL  Detached manifest signature URL.
  TELE_BRAIN_MANIFEST_SIGNATURE_FORMAT  Signature format: openssl or minisign.
  TELE_BRAIN_AUTO_APPLY              "off" (default), "check", or "patch".
EOF
}

require_commands() {
	local command_name
	for command_name in bash jq curl sha256sum stat tar flock realpath find awk grep sed \
		mktemp mv cp rm ln readlink chmod date sort dirname basename mkdir; do
		command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
	done
	[[ "$MAX_MANIFEST_SIZE" =~ ^[1-9][0-9]*$ ]] || die "TELE_BRAIN_MAX_MANIFEST_SIZE must be a positive integer"
	[[ "$MAX_ARTIFACT_SIZE" =~ ^[1-9][0-9]*$ ]] || die "TELE_BRAIN_MAX_ARTIFACT_SIZE must be a positive integer"
	[[ "$MAX_EXTRACTED_SIZE" =~ ^[1-9][0-9]*$ ]] || die "TELE_BRAIN_MAX_EXTRACTED_SIZE must be a positive integer"
	[[ "$MAX_ARCHIVE_ENTRIES" =~ ^[1-9][0-9]*$ ]] || die "TELE_BRAIN_MAX_ARCHIVE_ENTRIES must be a positive integer"
	[[ "$MAX_ARCHIVE_LISTING_BYTES" =~ ^[1-9][0-9]*$ ]] || die "TELE_BRAIN_MAX_ARCHIVE_LISTING_BYTES must be a positive integer"
	(( $(compare_decimal "$MAX_MANIFEST_SIZE" 16777216) <= 0 )) || die "TELE_BRAIN_MAX_MANIFEST_SIZE exceeds the 16 MiB hard limit"
	(( $(compare_decimal "$MAX_ARTIFACT_SIZE" 1073741824) <= 0 )) || die "TELE_BRAIN_MAX_ARTIFACT_SIZE exceeds the 1 GiB hard limit"
	(( $(compare_decimal "$MAX_EXTRACTED_SIZE" 4294967296) <= 0 )) || die "TELE_BRAIN_MAX_EXTRACTED_SIZE exceeds the 4 GiB hard limit"
	(( $(compare_decimal "$MAX_ARCHIVE_ENTRIES" 1000000) <= 0 )) || die "TELE_BRAIN_MAX_ARCHIVE_ENTRIES exceeds the hard limit"
	(( $(compare_decimal "$MAX_ARCHIVE_LISTING_BYTES" 67108864) <= 0 )) || die "TELE_BRAIN_MAX_ARCHIVE_LISTING_BYTES exceeds the 64 MiB hard limit"
	[[ "$LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || die "TELE_BRAIN_UPDATE_LOCK_TIMEOUT must be a non-negative integer"
	[[ "$NETWORK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "TELE_BRAIN_UPDATE_NETWORK_TIMEOUT must be a positive integer"
}

ensure_dirs() {
	mkdir -p -- "$STATE_DIR" "$CACHE_DIR" "$CACHE_DIR/manifests"
	chmod 700 -- "$STATE_DIR" "$CACHE_DIR" "$CACHE_DIR/manifests" 2>/dev/null || true
}

validate_url() {
	local url="$1"
	[[ "$url" =~ ^https://[^[:space:]]+$ || "$url" =~ ^file://[^[:space:]]+$ ]] ||
		die "only https:// and file:// URLs are allowed: $url"
}

download_file() {
	local url="$1" destination="$2" maximum_size="$3"
	validate_url "$url"
	if ! curl --fail --silent --show-error --location \
		--proto '=https,file' --proto-redir '=https' \
		--connect-timeout 15 --max-time "$NETWORK_TIMEOUT" \
		--max-filesize "$maximum_size" \
		--output "$destination" "$url"; then
		rm -f -- "$destination"
		return 1
	fi
	local actual_size
	actual_size="$(stat -c '%s' "$destination")"
	(( $(compare_decimal "$actual_size" "$maximum_size") <= 0 )) || die "download exceeds size limit: $actual_size > $maximum_size"
}

atomic_copy() {
	local source="$1" destination="$2" temporary
	temporary="$(mktemp "${destination}.tmp.XXXXXX")"
	cp -- "$source" "$temporary"
	mv -f -- "$temporary" "$destination"
}

write_json_atomic() {
	local destination="$1" content="$2" temporary
	temporary="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
	if ! printf '%s\n' "$content" >"$temporary"; then
		rm -f -- "$temporary"
		return 1
	fi
	if ! mv -f -- "$temporary" "$destination"; then
		rm -f -- "$temporary"
		return 1
	fi
}

acquire_update_lock() {
	[[ -n "$UPDATE_FD" ]] && return 0
	exec {UPDATE_FD}>"$UPDATE_LOCK_FILE"
	if (( AUTO_MODE )); then
		flock -n "$UPDATE_FD" || die "another update is already running"
	else
		flock -w "$LOCK_TIMEOUT" "$UPDATE_FD" || die "timed out waiting for update lock"
	fi
}

acquire_operation_lock() {
	[[ -n "$OPERATION_FD" ]] && return 0
	exec {OPERATION_FD}>"$OPERATION_LOCK_FILE"
	if (( AUTO_MODE )); then
		flock -n "$OPERATION_FD" || die "scan or activation is already running"
	else
		flock -w "$LOCK_TIMEOUT" "$OPERATION_FD" || die "timed out waiting for operation lock"
	fi
}

is_semver() {
	local version="$1"
	[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]
}

compare_decimal() {
	local left="$1" right="$2"
	if (( ${#left} > ${#right} )); then
		printf '1\n'
	elif (( ${#left} < ${#right} )); then
		printf '%s\n' '-1'
	elif [[ "$left" > "$right" ]]; then
		printf '1\n'
	elif [[ "$left" < "$right" ]]; then
		printf '%s\n' '-1'
	else
		printf '0\n'
	fi
}

semver_compare() {
	local left="${1%%+*}" right="${2%%+*}"
	local left_core="${left%%-*}" right_core="${right%%-*}"
	local left_pre="" right_pre="" index left_part right_part numeric_comparison
	local -a left_numbers right_numbers left_ids right_ids
	[[ "$left" == *-* ]] && left_pre="${left#*-}"
	[[ "$right" == *-* ]] && right_pre="${right#*-}"
	IFS=. read -r -a left_numbers <<<"$left_core"
	IFS=. read -r -a right_numbers <<<"$right_core"
	for index in 0 1 2; do
		numeric_comparison="$(compare_decimal "${left_numbers[$index]}" "${right_numbers[$index]}")"
		if (( numeric_comparison != 0 )); then
			printf '%s\n' "$numeric_comparison"
			return
		fi
	done
	if [[ -z "$left_pre" && -z "$right_pre" ]]; then
		printf '0\n'
		return
	elif [[ -z "$left_pre" ]]; then
		printf '1\n'
		return
	elif [[ -z "$right_pre" ]]; then
		printf '%s\n' '-1'
		return
	fi
	IFS=. read -r -a left_ids <<<"$left_pre"
	IFS=. read -r -a right_ids <<<"$right_pre"
	for (( index=0; index<${#left_ids[@]} || index<${#right_ids[@]}; index++ )); do
		if (( index >= ${#left_ids[@]} )); then
			printf '%s\n' '-1'
			return
		elif (( index >= ${#right_ids[@]} )); then
			printf '1\n'
			return
		fi
		left_part="${left_ids[$index]}"
		right_part="${right_ids[$index]}"
		if [[ "$left_part" =~ ^[0-9]+$ && "$right_part" =~ ^[0-9]+$ ]]; then
			numeric_comparison="$(compare_decimal "$left_part" "$right_part")"
			if (( numeric_comparison != 0 )); then printf '%s\n' "$numeric_comparison"; return; fi
		elif [[ "$left_part" =~ ^[0-9]+$ ]]; then
			printf '%s\n' '-1'
			return
		elif [[ "$right_part" =~ ^[0-9]+$ ]]; then
			printf '1\n'
			return
		elif [[ "$left_part" > "$right_part" ]]; then
			printf '1\n'
			return
		elif [[ "$left_part" < "$right_part" ]]; then
			printf '%s\n' '-1'
			return
		fi
	done
	printf '0\n'
}

is_same_series_patch_upgrade() {
	local installed="${1%%+*}" available="${2%%+*}"
	local installed_core="${installed%%-*}" available_core="${available%%-*}" patch_comparison
	local -a installed_parts available_parts
	[[ "$available" != *-* ]] || return 1
	IFS=. read -r -a installed_parts <<<"$installed_core"
	IFS=. read -r -a available_parts <<<"$available_core"
	[[ "${installed_parts[0]}" == "${available_parts[0]}" ]] || return 1
	[[ "${installed_parts[1]}" == "${available_parts[1]}" ]] || return 1
	patch_comparison="$(compare_decimal "${available_parts[2]}" "${installed_parts[2]}")"
	(( patch_comparison > 0 ))
}

current_version() {
	local version_file="$INSTALL_DIR/VERSION" version
	[[ -f "$version_file" ]] || die "VERSION is missing from $INSTALL_DIR"
	IFS= read -r version <"$version_file" || true
	version="${version//$'\r'/}"
	is_semver "$version" || die "installed VERSION is not valid SemVer: $version"
	printf '%s\n' "$version"
}

jq_string() {
	local expression="$1" file="$2"
	jq -er "$expression | select(type == \"string\" and length > 0)" "$file" 2>/dev/null || true
}

jq_number() {
	local expression="$1" file="$2"
	jq -er "$expression | select(type == \"number\" and floor == . and . >= 0)" "$file" 2>/dev/null || true
}

signature_format_for() {
	local expression="$1" manifest="$2"
	jq_string "($expression).format // empty" "$manifest"
}

signature_url_for() {
	local expression="$1" manifest="$2"
	jq_string "($expression).url // empty" "$manifest"
}

verify_signature() {
	local payload="$1" signature="$2" format="$3"
	case "$format" in
	minisign)
		command -v minisign >/dev/null 2>&1 || die "manifest requires minisign, but minisign is unavailable"
		[[ -n "${TELE_BRAIN_MINISIGN_PUBKEY_FILE:-}" && -f "${TELE_BRAIN_MINISIGN_PUBKEY_FILE:-}" ]] ||
			die "TELE_BRAIN_MINISIGN_PUBKEY_FILE must name a trusted key"
		minisign -Vm "$payload" -x "$signature" -p "$TELE_BRAIN_MINISIGN_PUBKEY_FILE" >/dev/null
		;;
	openssl)
		command -v openssl >/dev/null 2>&1 || die "manifest requires openssl, but openssl is unavailable"
		[[ -f "$OPENSSL_PUBKEY_FILE" ]] ||
			die "trusted OpenSSL public key is unavailable: $OPENSSL_PUBKEY_FILE"
		openssl dgst -sha256 -verify "$OPENSSL_PUBKEY_FILE" \
			-signature "$signature" "$payload" >/dev/null 2>&1
		;;
	*)
		die "unsupported signature format: ${format:-missing}"
		;;
	esac
}

verify_declared_signature() {
	local payload="$1" signature_url="$2" format="$3" label="$4" signature_file payload_sha downloaded
	[[ -n "$signature_url" && -n "$format" ]] || die "$label signature metadata is incomplete"
	payload_sha="$(sha256sum "$payload" | awk '{print tolower($1)}')"
	mkdir -p -- "$CACHE_DIR/signatures"
	signature_file="$CACHE_DIR/signatures/${label}-${payload_sha}.sig"
	if [[ -s "$signature_file" ]] && verify_signature "$payload" "$signature_file" "$format"; then
		return 0
	fi
	(( OFFLINE_MODE == 0 )) || die "$label signature is unavailable or invalid in the offline cache"
	downloaded="$(mktemp "$CACHE_DIR/signatures/${label}.download.XXXXXX")"
	TEMP_PATHS+=("$downloaded")
	download_file "$signature_url" "$downloaded" 1048576 || die "could not download $label signature"
	verify_signature "$payload" "$downloaded" "$format" || die "$label signature verification failed"
	mv -- "$downloaded" "$signature_file"
}

validate_manifest() {
	local manifest="$1" schema product channel version sequence artifact_url artifact_sha artifact_size configured
	jq -e 'type == "object"' "$manifest" >/dev/null || die "manifest is not a JSON object"
	schema="$(jq_number '.schema_version // empty' "$manifest")"
	[[ "$schema" == 1 ]] || die "manifest schema_version must be 1"
	product="$(jq_string '.product // empty' "$manifest")"
	[[ "$product" == "tele-brain" ]] || die "manifest product is not tele-brain"
	channel="$(jq_string '.channel // empty' "$manifest")"
	case "$channel" in stable | beta | nightly) ;; *) die "manifest channel is invalid" ;; esac
	version="$(jq_string '.version // empty' "$manifest")"
	[[ -n "$version" ]] || die "manifest version is missing"
	is_semver "$version" || die "manifest version is not valid SemVer: $version"
	configured="$(jq -r 'if has("configured") then .configured else true end' "$manifest")"
	[[ "$configured" == "true" || "$configured" == "false" ]] || die "manifest configured must be boolean"
	if [[ "$configured" == "true" ]]; then
		sequence="$(jq_number '.sequence // empty' "$manifest")"
		[[ -n "$sequence" && "$sequence" -gt 0 ]] || die "configured manifest sequence must be a positive integer"
		artifact_url="$(jq_string '.artifact.url // .artifact_url // empty' "$manifest")"
		artifact_sha="$(jq_string '.artifact.sha256 // .artifact_sha256 // empty' "$manifest")"
		artifact_size="$(jq_number '.artifact.size // .artifact_size // empty' "$manifest")"
		[[ -n "$artifact_url" ]] || die "configured manifest has no artifact URL"
		validate_url "$artifact_url"
		[[ "$artifact_sha" =~ ^[0-9A-Fa-f]{64}$ ]] || die "artifact SHA-256 is missing or malformed"
		[[ "$artifact_size" =~ ^[1-9][0-9]*$ ]] || die "artifact size is missing or malformed"
		(( $(compare_decimal "$artifact_size" "$MAX_ARTIFACT_SIZE") <= 0 )) ||
			die "artifact size is outside the allowed range"
	fi
}

enforce_trusted_sequence() {
	local manifest="$1" sequence source_key sequence_file highest=0 highest_hash="" manifest_hash content
	(( LAST_MANIFEST_SIGNED == 1 )) || return 0
	sequence="$(jq_number '.sequence // empty' "$manifest")"
	[[ -n "$sequence" ]] || die "signed manifest has no sequence"
	source_key="$MANIFEST_SOURCE_KEY"
	sequence_file="$STATE_DIR/trusted-sequence-${source_key:0:24}"
	if [[ -s "$sequence_file" ]]; then
		if jq -e 'type == "object"' "$sequence_file" >/dev/null 2>&1; then
			highest="$(jq_number '.sequence // empty' "$sequence_file")"
			highest_hash="$(jq_string '.manifest_sha256 // empty' "$sequence_file")"
		else
			IFS= read -r highest <"$sequence_file" || true
		fi
		[[ "$highest" =~ ^[0-9]+$ ]] || die "trusted sequence state is invalid"
	fi
	manifest_hash="$(sha256sum "$manifest" | awk '{print tolower($1)}')"
	(( sequence >= highest )) || die "signed manifest sequence rollback detected: $sequence < $highest"
	if (( sequence == highest )) && [[ -n "$highest_hash" && "$manifest_hash" != "$highest_hash" ]]; then
		die "signed manifest sequence equivocation detected at $sequence"
	fi
	if (( sequence > highest )) || [[ -z "$highest_hash" ]]; then
		content="$(jq -n --argjson sequence "$sequence" --arg manifest_sha256 "$manifest_hash" \
			'{sequence:$sequence, manifest_sha256:$manifest_sha256}')" || die "could not encode trusted sequence state"
		write_json_atomic "$sequence_file" "$content" || die "could not persist trusted manifest sequence"
	fi
}

fetch_manifest() {
	local destination="$1" fetched manifest_signature_url manifest_signature_format configured require_signature=0 cache_result=1
	LAST_MANIFEST_SIGNED=0
	LAST_MANIFEST_SOURCE="$MANIFEST_URL"
	if (( OFFLINE_MODE )); then
		[[ -s "$CACHED_MANIFEST" ]] || die "no cached manifest is available offline"
		cp -- "$CACHED_MANIFEST" "$destination"
		configured="$(jq -r 'if has("configured") then .configured else true end' "$destination")"
		if [[ "$MANIFEST_URL" == "$DEFAULT_MANIFEST_URL" && "$configured" == true ]]; then
			require_signature=1
		fi
		manifest_signature_url="${TELE_BRAIN_MANIFEST_SIGNATURE_URL:-}"
		manifest_signature_format="${TELE_BRAIN_MANIFEST_SIGNATURE_FORMAT:-}"
		if [[ -z "$manifest_signature_url" && "$require_signature" == 0 ]]; then
			manifest_signature_url="$(signature_url_for '.manifest_signature // {}' "$destination")"
		fi
		if [[ -z "$manifest_signature_format" && "$require_signature" == 0 ]]; then
			manifest_signature_format="$(signature_format_for '.manifest_signature // {}' "$destination")"
		fi
		if [[ "$require_signature" == 1 ]]; then
			manifest_signature_url="${manifest_signature_url:-$DEFAULT_MANIFEST_SIGNATURE_URL}"
			manifest_signature_format="${manifest_signature_format:-openssl}"
		fi
		if [[ -n "$manifest_signature_url" || -n "$manifest_signature_format" ]]; then
			verify_declared_signature "$destination" "$manifest_signature_url" "$manifest_signature_format" manifest
			LAST_MANIFEST_SIGNED=1
		fi
	else
		fetched="$(mktemp "$CACHE_DIR/manifest.download.XXXXXX")"
		TEMP_PATHS+=("$fetched")
		if ! download_file "$MANIFEST_URL" "$fetched" "$MAX_MANIFEST_SIZE"; then
			if (( MANIFEST_URL_EXPLICIT == 0 )) && [[ -s "$LOCAL_BOOTSTRAP_MANIFEST" ]]; then
				log "remote manifest is unavailable; using the local bootstrap manifest"
				cp -- "$LOCAL_BOOTSTRAP_MANIFEST" "$fetched"
				LAST_MANIFEST_SOURCE="file://$LOCAL_BOOTSTRAP_MANIFEST"
				cache_result=0
			else
				die "could not download release manifest: $MANIFEST_URL"
			fi
		else
			LAST_MANIFEST_SOURCE="$MANIFEST_URL"
		fi
		jq -e . "$fetched" >/dev/null || die "downloaded manifest is invalid JSON"
		configured="$(jq -r 'if has("configured") then .configured else true end' "$fetched")"
		if [[ "$MANIFEST_URL" == "$DEFAULT_MANIFEST_URL" && "$configured" == true ]]; then
			require_signature=1
		fi
		manifest_signature_url="${TELE_BRAIN_MANIFEST_SIGNATURE_URL:-}"
		manifest_signature_format="${TELE_BRAIN_MANIFEST_SIGNATURE_FORMAT:-}"
		if [[ -z "$manifest_signature_url" && "$require_signature" == 0 ]]; then
			manifest_signature_url="$(signature_url_for '.manifest_signature // {}' "$fetched")"
		fi
		if [[ -z "$manifest_signature_format" && "$require_signature" == 0 ]]; then
			manifest_signature_format="$(signature_format_for '.manifest_signature // {}' "$fetched")"
		fi
		if [[ "$require_signature" == 1 ]]; then
			manifest_signature_url="${manifest_signature_url:-$DEFAULT_MANIFEST_SIGNATURE_URL}"
			manifest_signature_format="${manifest_signature_format:-openssl}"
		fi
		if [[ -n "$manifest_signature_url" || -n "$manifest_signature_format" ]]; then
			verify_declared_signature "$fetched" "$manifest_signature_url" "$manifest_signature_format" manifest
			LAST_MANIFEST_SIGNED=1
		fi
		cp -- "$fetched" "$destination"
	fi
	validate_manifest "$destination"
	enforce_trusted_sequence "$destination"
	if (( OFFLINE_MODE == 0 && cache_result == 1 )); then
		atomic_copy "$destination" "$CACHED_MANIFEST"
	fi
}

record_check() {
	local manifest="$1" installed="$2" available="$3" comparison="$4" content
	content="$(jq -n \
		--arg checked_at "$(date -Iseconds)" \
		--arg manifest_url "$LAST_MANIFEST_SOURCE" \
		--arg installed_version "$installed" \
		--arg available_version "$available" \
		--argjson comparison "$comparison" \
		--argjson manifest_signed "$LAST_MANIFEST_SIGNED" \
		'{checked_at:$checked_at, manifest_url:$manifest_url, installed_version:$installed_version,
		  available_version:$available_version, comparison:$comparison, manifest_signed:($manifest_signed == 1)}')"
	write_json_atomic "$STATE_FILE.last-check" "$content"
}

load_manifest_for_command() {
	local destination="$1"
	fetch_manifest "$destination"
}

command_check() {
	local installed manifest available comparison configured
	installed="$(current_version)"
	manifest="$(mktemp "$CACHE_DIR/manifest.active.XXXXXX")"
	TEMP_PATHS+=("$manifest")
	load_manifest_for_command "$manifest"
	available="$(jq_string '.version' "$manifest")"
	configured="$(jq -r 'if has("configured") then .configured else true end' "$manifest")"
	comparison="$(semver_compare "$available" "$installed")"
	record_check "$manifest" "$installed" "$available" "$comparison"
	printf 'installed: %s\n' "$installed"
	printf 'available: %s\n' "$available"
	printf 'source: %s\n' "$LAST_MANIFEST_SOURCE"
	if [[ "$configured" != "true" ]]; then
		printf 'status: source_unconfigured\n'
	elif (( comparison > 0 )); then
		printf 'status: update_available\n'
	elif (( comparison == 0 )); then
		printf 'status: up_to_date\n'
	else
		printf 'status: local_version_newer\n'
	fi
}

command_scheduled() {
	local installed manifest available comparison configured channel
	case "$AUTO_APPLY_POLICY" in
	'' | off | check)
		command_check
		return
		;;
	patch) ;;
	*) die "TELE_BRAIN_AUTO_APPLY must be off, check, or patch" ;;
	esac

	installed="$(current_version)"
	manifest="$(mktemp "$CACHE_DIR/manifest.scheduled.XXXXXX")"
	TEMP_PATHS+=("$manifest")
	load_manifest_for_command "$manifest"
	available="$(jq_string '.version' "$manifest")"
	configured="$(jq -r 'if has("configured") then .configured else true end' "$manifest")"
	channel="$(jq_string '.channel' "$manifest")"
	comparison="$(semver_compare "$available" "$installed")"
	record_check "$manifest" "$installed" "$available" "$comparison"
	printf 'installed: %s\n' "$installed"
	printf 'available: %s\n' "$available"
	printf 'source: %s\n' "$LAST_MANIFEST_SOURCE"
	if [[ "$configured" != "true" ]]; then
		printf 'status: source_unconfigured\n'
		return
	elif (( comparison == 0 )); then
		printf 'status: up_to_date\n'
		return
	elif (( comparison < 0 )); then
		printf 'status: local_version_newer\n'
		return
	elif [[ "$channel" != stable ]] || ! is_same_series_patch_upgrade "$installed" "$available"; then
		printf 'status: manual_update_required\n'
		return
	fi

	printf 'status: applying_signed_patch\n'
	AUTO_MODE=1
	command_apply "$manifest"
}

validate_archive_member() {
	local member="$1" normalized component
	[[ "$member" != *$'\n'* && "$member" != *$'\r'* ]] || die "archive member contains a newline"
	[[ "$member" != /* ]] || die "archive contains an absolute path: $member"
	normalized="$member"
	while [[ "$normalized" == ./* ]]; do normalized="${normalized#./}"; done
	[[ -n "$normalized" && "$normalized" != "." ]] || return 0
	IFS=/ read -r -a components <<<"$normalized"
	for component in "${components[@]}"; do
		[[ "$component" != ".." ]] || die "archive contains parent traversal: $member"
	done
}

validate_archive() {
	local archive="$1" listing verbose_listing member mode entry_count=0 listing_marker marker_reason
	listing="$(mktemp "$CACHE_DIR/archive.list.XXXXXX")"
	verbose_listing="$(mktemp "$CACHE_DIR/archive.verbose.XXXXXX")"
	listing_marker="$(mktemp "$CACHE_DIR/archive.limit.XXXXXX")"
	TEMP_PATHS+=("$listing" "$verbose_listing")
	TEMP_PATHS+=("$listing_marker")
	if ! tar -tzf "$archive" 2>/dev/null |
		awk -v max_entries="$MAX_ARCHIVE_ENTRIES" -v max_bytes="$MAX_ARCHIVE_LISTING_BYTES" -v marker="$listing_marker" '
			{ bytes += length($0) + 1; if (NR > max_entries || bytes > max_bytes) { print "limit" > marker; exit 1 } print }
		' >"$listing"; then
		[[ -s "$listing_marker" ]] && die "archive contains too many entries or an oversized listing"
		die "artifact is not a supported gzip tar archive"
	fi
	if ! tar --numeric-owner -tvzf "$archive" 2>/dev/null |
		awk -v max_entries="$MAX_ARCHIVE_ENTRIES" -v max_bytes="$MAX_ARCHIVE_LISTING_BYTES" \
			-v max_extract="$MAX_EXTRACTED_SIZE" -v marker="$listing_marker" '
			{
			  bytes += length($0) + 1
			  if (NR > max_entries || bytes > max_bytes) { print "listing" > marker; exit 1 }
			  if ($3 !~ /^[0-9]+$/) { print "invalid-size" > marker; exit 1 }
			  size = $3 + 0
			  if (size > max_extract || expanded > max_extract - size) { print "expanded" > marker; exit 1 }
			  expanded += size
			  print
			}
		' >"$verbose_listing"; then
		marker_reason="$(head -1 "$listing_marker" 2>/dev/null || true)"
		[[ "$marker_reason" == expanded ]] && die "archive expands beyond the allowed size"
		[[ -n "$marker_reason" ]] && die "archive metadata listing exceeds limits"
		die "cannot inspect gzip archive metadata"
	fi
	while IFS= read -r member || [[ -n "$member" ]]; do
		validate_archive_member "$member"
		entry_count=$((entry_count + 1))
		(( entry_count <= MAX_ARCHIVE_ENTRIES )) || die "archive contains too many entries"
	done <"$listing"
	(( entry_count > 0 )) || die "artifact archive is empty"
	while IFS= read -r member || [[ -n "$member" ]]; do
		mode="${member:0:1}"
		case "$mode" in
		-|d) ;;
		l) die "archive symlinks are not allowed" ;;
		h|b|c|p|s) die "archive contains a hard link or special device" ;;
		*) die "archive contains an unsupported entry type: $mode" ;;
		esac
	done <"$verbose_listing"
}

extract_archive() {
	local archive="$1" destination="$2"
	tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$destination"
}

validate_extracted_links() {
	local root="$1" link target resolved
	while IFS= read -r -d '' link; do
		target="$(readlink -- "$link")"
		[[ "$target" != /* ]] || die "archive symlink has an absolute target: ${link#"$root"/}"
		resolved="$(realpath -m -- "$(dirname -- "$link")/$target")"
		case "$resolved" in
		"$root"|"$root"/*) ;;
		*) die "archive symlink escapes staging root: ${link#"$root"/}" ;;
		esac
	done < <(find "$root" -type l -print0)
}

find_payload_root() {
	local staging="$1" child count=0 candidate=""
	if [[ -f "$staging/SKILL.md" ]]; then
		printf '%s\n' "$staging"
		return
	fi
	while IFS= read -r -d '' child; do
		count=$((count + 1))
		candidate="$child"
	done < <(find "$staging" -mindepth 1 -maxdepth 1 -type d -print0)
	if (( count == 1 )) && [[ -f "$candidate/SKILL.md" ]]; then
		printf '%s\n' "$candidate"
		return
	fi
	die "artifact must contain tele-brain files at its root or in one top-level directory"
}

validate_skill_frontmatter() {
	local skill_file="$1"
	awk '
		NR == 1 { if ($0 != "---") exit 1; next }
		$0 == "---" { closed = 1; exit }
		END { if (!closed) exit 1 }
	' "$skill_file" || die "SKILL.md has invalid YAML frontmatter delimiters"
	sed -n '2,/^---$/p' "$skill_file" | grep -Eq '^name:[[:space:]]*tele-brain[[:space:]]*$' ||
		die "SKILL.md frontmatter must declare name: tele-brain"
	sed -n '2,/^---$/p' "$skill_file" | grep -Eq '^description:[[:space:]]*[^[:space:]].*$' ||
		die "SKILL.md frontmatter must declare a description"
}

preflight_payload() {
	local root="$1" expected_version="$2" allow_data="${3:-0}" packaged_version packaged_manifest_version
	local required
	for required in SKILL.md VERSION scan.sh update.sh release-manifest.json \
		bin/tele-brain install-timers.sh \
		keys/release-public.pem \
		systemd/tele-brain-refresh.service systemd/tele-brain-refresh.timer \
		systemd/tele-brain-update.service systemd/tele-brain-update.timer; do
		[[ -f "$root/$required" ]] || die "artifact is missing $required"
	done
	if (( allow_data == 0 )); then
		[[ ! -e "$root/data" && ! -L "$root/data" ]] || die "artifact must not contain the local data path"
	fi
	IFS= read -r packaged_version <"$root/VERSION" || true
	packaged_version="${packaged_version//$'\r'/}"
	is_semver "$packaged_version" || die "artifact VERSION is not valid SemVer"
	[[ "$packaged_version" == "$expected_version" ]] ||
		die "artifact VERSION $packaged_version does not match manifest $expected_version"
	jq -e 'type == "object" and (.product == "tele-brain")' "$root/release-manifest.json" >/dev/null ||
		die "artifact release-manifest.json is invalid"
	packaged_manifest_version="$(jq_string '.version // empty' "$root/release-manifest.json")"
	[[ "$packaged_manifest_version" == "$expected_version" ]] ||
		die "artifact release manifest version does not match $expected_version"
	validate_skill_frontmatter "$root/SKILL.md"
	bash -n "$root/scan.sh" || die "artifact scan.sh failed bash -n"
	bash -n "$root/update.sh" || die "artifact update.sh failed bash -n"
	bash -n "$root/bin/tele-brain" || die "artifact bin/tele-brain failed bash -n"
	bash -n "$root/install-timers.sh" || die "artifact install-timers.sh failed bash -n"
	chmod 755 -- "$root/scan.sh" "$root/update.sh" "$root/bin/tele-brain" "$root/install-timers.sh"
}

validate_rollback_data() {
	local previous_root="$1" current_data="$INSTALL_DIR/data" previous_data
	local current_target previous_target activated_target
	previous_data="$previous_root/data"
	if [[ -L "$current_data" || -L "$previous_data" ]]; then
		[[ -L "$current_data" && -L "$previous_data" ]] ||
			die "rollback data link does not match the active installation"
		current_target="$(readlink -- "$current_data")"
		previous_target="$(readlink -- "$previous_data")"
		[[ "$current_target" == "$previous_target" ]] || die "rollback data link target has changed"
		if [[ "$previous_target" == /* ]]; then
			activated_target="$(realpath -m -- "$previous_target")"
		else
			activated_target="$(realpath -m -- "$INSTALL_DIR/$previous_target")"
		fi
		case "$activated_target" in
		"$INSTALL_DIR"|"$INSTALL_DIR"/*) die "rollback data link must point outside the installation" ;;
		esac
	elif [[ -e "$current_data" || -e "$previous_data" ]]; then
		die "rollback data path must be an external symlink"
	fi
}

preserve_data_link() {
	local payload_root="$1" data_path="$INSTALL_DIR/data" target activated_target
	if [[ -L "$data_path" ]]; then
		target="$(readlink -- "$data_path")"
		if [[ "$target" == /* ]]; then
			activated_target="$(realpath -m -- "$target")"
		else
			activated_target="$(realpath -m -- "$INSTALL_DIR/$target")"
		fi
		case "$activated_target" in
		"$INSTALL_DIR"|"$INSTALL_DIR"/*) die "data link must point outside the installation" ;;
		esac
		ln -s -- "$target" "$payload_root/data"
	elif [[ -e "$data_path" ]]; then
		die "data is not an external symlink; refusing to replace it"
	fi
}

new_backup_path() {
	local install_parent install_name timestamp
	install_parent="$(dirname -- "$INSTALL_DIR")"
	install_name="$(basename -- "$INSTALL_DIR")"
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	printf '%s/.%s.backup.%s.%s\n' "$install_parent" "$install_name" "$timestamp" "$$"
}

prune_backups() {
	local active_backup="$1" install_parent install_name path kept=0
	install_parent="$(dirname -- "$INSTALL_DIR")"
	install_name="$(basename -- "$INSTALL_DIR")"
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		if [[ "$path" == "$active_backup" ]]; then
			continue
		fi
		if (( kept < 2 )); then
			kept=$((kept + 1))
		else
			rm -rf -- "$path"
		fi
	done < <(
		find "$install_parent" -mindepth 1 -maxdepth 1 -name ".${install_name}.backup.*" \
			-printf '%T@ %p\n' 2>/dev/null | sort -nr | sed 's/^[^ ]* //'
	)
}

refresh_installed_timer_units() {
	local unit_dir output content unit installed=0
	unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	for unit in tele-brain-refresh.service tele-brain-refresh.timer \
		tele-brain-update.service tele-brain-update.timer; do
		if [[ -e "$unit_dir/$unit" || -L "$unit_dir/$unit" ]]; then
			installed=1
			break
		fi
	done
	if (( installed == 0 )); then
		rm -f -- "$TIMER_WARNING_FILE"
		return 0
	fi

	if output="$("$INSTALL_DIR/install-timers.sh" install 2>&1)"; then
		rm -f -- "$TIMER_WARNING_FILE"
		log "refreshed installed user timer units"
		return 0
	fi
	content="$(jq -n \
		--arg created_at "$(date -Iseconds)" \
		--arg install_command "$INSTALL_DIR/install-timers.sh install" \
		--arg detail "$output" \
		'{created_at:$created_at, install_command:$install_command, detail:$detail}')" || true
	if [[ -n "$content" ]]; then
		write_json_atomic "$TIMER_WARNING_FILE" "$content" ||
			log "could not persist the timer refresh warning"
	fi
	log "update activated, but installed timer units could not be refreshed; run: $INSTALL_DIR/install-timers.sh install"
	return 0
}

recover_missing_install() {
	local install_parent install_name latest=""
	[[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]] && return 0
	acquire_operation_lock
	[[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]] && return 0
	install_parent="$(dirname -- "$INSTALL_DIR")"
	install_name="$(basename -- "$INSTALL_DIR")"
	latest="$(find "$install_parent" -maxdepth 1 -mindepth 1 -name ".${install_name}.backup.*" -printf '%T@ %p\n' 2>/dev/null |
		sort -nr | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print; exit }')"
	[[ -n "$latest" && ( -e "$latest" || -L "$latest" ) ]] || die "installation is missing and no backup can be recovered"
	log "recovering interrupted activation from $latest"
	mv -- "$latest" "$INSTALL_DIR"
}

write_activation_state() {
	local current_version_value="$1" previous_version_value="$2" previous_path="$3" artifact_sha="$4" content
	content="$(jq -n \
		--arg updated_at "$(date -Iseconds)" \
		--arg current_version "$current_version_value" \
		--arg previous_version "$previous_version_value" \
		--arg previous_path "$previous_path" \
		--arg artifact_sha256 "$artifact_sha" \
		'{updated_at:$updated_at, current_version:$current_version, previous_version:$previous_version,
		  previous_path:$previous_path, artifact_sha256:$artifact_sha256}')" || return 1
	write_json_atomic "$STATE_FILE" "$content"
}

write_rollback_state() {
	local current_version_value="$1" previous_version_value="$2" previous_path="$3" content
	content="$(jq -n \
		--arg updated_at "$(date -Iseconds)" \
		--arg current_version "$current_version_value" \
		--arg previous_version "$previous_version_value" \
		--arg previous_path "$previous_path" \
		'{updated_at:$updated_at, current_version:$current_version, previous_version:$previous_version,
		  previous_path:$previous_path, rollback:true}')" || return 1
	write_json_atomic "$STATE_FILE" "$content"
}

version_at_path() {
	local root="$1" version
	[[ -f "$root/VERSION" ]] || return 1
	IFS= read -r version <"$root/VERSION" || true
	version="${version//$'\r'/}"
	is_semver "$version" || return 1
	printf '%s\n' "$version"
}

validate_backup_path() {
	local path="$1" install_parent install_name
	install_parent="$(dirname -- "$INSTALL_DIR")"
	install_name="$(basename -- "$INSTALL_DIR")"
	case "$path" in
	"$install_parent"/."$install_name".backup.*) ;;
	*) return 1 ;;
	esac
}

write_pending_transaction() {
	local type="$1" from_version="$2" to_version="$3" exchange_path="$4" artifact_sha="${5:-}" content
	content="$(jq -n \
		--arg type "$type" \
		--arg from_version "$from_version" \
		--arg to_version "$to_version" \
		--arg exchange_path "$exchange_path" \
		--arg artifact_sha256 "$artifact_sha" \
		--arg created_at "$(date -Iseconds)" \
		'{type:$type, from_version:$from_version, to_version:$to_version,
		  exchange_path:$exchange_path, artifact_sha256:$artifact_sha256, created_at:$created_at}')" || return 1
	write_json_atomic "$PENDING_FILE" "$content"
}

recover_pending_transaction() {
	local type from_version to_version exchange_path artifact_sha install_version exchange_version
	[[ -s "$PENDING_FILE" ]] || return 0
	acquire_operation_lock
	jq -e 'type == "object"' "$PENDING_FILE" >/dev/null || die "pending update transaction is invalid"
	type="$(jq_string '.type // empty' "$PENDING_FILE")"
	from_version="$(jq_string '.from_version // empty' "$PENDING_FILE")"
	to_version="$(jq_string '.to_version // empty' "$PENDING_FILE")"
	exchange_path="$(jq_string '.exchange_path // empty' "$PENDING_FILE")"
	artifact_sha="$(jq_string '.artifact_sha256 // empty' "$PENDING_FILE")"
	[[ "$type" == "activate" || "$type" == "rollback" ]] || die "pending transaction type is invalid"
	is_semver "$from_version" && is_semver "$to_version" || die "pending transaction versions are invalid"
	validate_backup_path "$exchange_path" || die "pending transaction path is outside the backup namespace"
	install_version="$(version_at_path "$INSTALL_DIR")" || die "active installation is invalid during transaction recovery"

	if [[ ! -e "$exchange_path" && ! -L "$exchange_path" ]]; then
		[[ "$install_version" == "$from_version" ]] || die "pending transaction lost its exchange path after activation"
		rm -f -- "$PENDING_FILE"
		log "discarded an interrupted transaction before staging completed"
		return 0
	fi
	exchange_version="$(version_at_path "$exchange_path")" || die "pending transaction exchange path is invalid"

	if [[ "$install_version" == "$to_version" && "$exchange_version" == "$from_version" ]]; then
		if [[ "$type" == "activate" ]]; then
			write_activation_state "$to_version" "$from_version" "$exchange_path" "$artifact_sha" ||
				die "could not finalize recovered activation state"
		else
			write_rollback_state "$to_version" "$from_version" "$exchange_path" ||
				die "could not finalize recovered rollback state"
		fi
		rm -f -- "$PENDING_FILE"
		refresh_installed_timer_units
		log "finalized interrupted $type transaction"
	elif [[ "$install_version" == "$from_version" && "$exchange_version" == "$to_version" ]]; then
		if [[ "$type" == "activate" ]]; then
			rm -rf -- "$exchange_path"
		fi
		rm -f -- "$PENDING_FILE"
		log "discarded interrupted $type transaction before exchange"
	else
		die "pending transaction state does not match installed versions"
	fi
}

begin_critical_exchange() {
	trap '' HUP INT TERM
}

end_critical_exchange() {
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

supports_atomic_exchange() {
	mv --help 2>/dev/null | grep -q -- '--exchange' && mv --help 2>/dev/null | grep -q -- '--no-copy'
}

atomic_exchange() {
	mv -T --exchange --no-copy -- "$1" "$2"
}

activate_payload() {
	local payload_root="$1" new_version="$2" artifact_sha="$3" staging="$4"
	local old_version backup_path install_parent
	backup_path="$(new_backup_path)"
	install_parent="$(dirname -- "$INSTALL_DIR")"
	[[ "$payload_root" == "$install_parent"/* ]] || die "staging directory must share the installation filesystem"
	acquire_operation_lock
	recover_missing_install
	old_version="$(current_version)"
	preserve_data_link "$payload_root"
	[[ ! -e "$backup_path" && ! -L "$backup_path" ]] || die "backup path already exists: $backup_path"
	supports_atomic_exchange || die "GNU mv with --exchange and --no-copy is required for safe activation"
	write_pending_transaction activate "$old_version" "$new_version" "$backup_path" "$artifact_sha" ||
		die "could not record pending activation"
	if [[ "$payload_root" == "$staging" ]]; then
		forget_temp_path "$staging"
	fi
	begin_critical_exchange
	if ! mv -- "$payload_root" "$backup_path"; then
		rm -f -- "$PENDING_FILE"
		end_critical_exchange
		die "could not move staged payload into the exchange namespace"
	fi
	if ! atomic_exchange "$INSTALL_DIR" "$backup_path"; then
		rm -rf -- "$backup_path"
		rm -f -- "$PENDING_FILE"
		end_critical_exchange
		die "could not atomically activate staged update"
	fi
	if ! write_activation_state "$new_version" "$old_version" "$backup_path" "$artifact_sha"; then
		log "could not record activation state; restoring previous installation"
		atomic_exchange "$INSTALL_DIR" "$backup_path" ||
			die "activation state write and atomic restore both failed"
		rm -rf -- "$backup_path"
		rm -f -- "$PENDING_FILE"
		end_critical_exchange
		die "activation state could not be written; previous installation restored"
	fi
	rm -f -- "$PENDING_FILE"
	end_critical_exchange
	prune_backups "$backup_path"
	refresh_installed_timer_units
	if [[ "$staging" != "$backup_path" && ( -e "$staging" || -L "$staging" ) ]]; then
		rm -rf -- "$staging"
	fi
	printf 'updated: %s -> %s\n' "$old_version" "$new_version"
	printf 'rollback: %s\n' "$backup_path"
}

artifact_signature_metadata() {
	local manifest="$1" field="$2"
	case "$field" in
	url) jq_string '.artifact.signature.url // .artifact_signature.url // .signature.url // .signature_url // empty' "$manifest" ;;
	format) jq_string '.artifact.signature.format // .artifact_signature.format // .signature.format // .signature_format // empty' "$manifest" ;;
	esac
}

download_and_verify_artifact() {
	local manifest="$1" destination="$2"
	local artifact_url artifact_sha artifact_size actual_size actual_sha signature_url signature_format
	LAST_ARTIFACT_SIGNED=0
	artifact_url="$(jq_string '.artifact.url // .artifact_url // empty' "$manifest")"
	artifact_sha="$(jq_string '.artifact.sha256 // .artifact_sha256 // empty' "$manifest")"
	artifact_sha="${artifact_sha,,}"
	artifact_size="$(jq_number '.artifact.size // .artifact_size // empty' "$manifest")"
	if [[ -s "$destination" ]]; then
		actual_size="$(stat -c '%s' "$destination")"
		actual_sha="$(sha256sum "$destination" | awk '{print tolower($1)}')"
		if [[ "$actual_size" != "$artifact_size" || "$actual_sha" != "$artifact_sha" ]]; then
			rm -f -- "$destination"
		fi
	fi
	if [[ ! -s "$destination" ]]; then
		(( OFFLINE_MODE == 0 )) || die "verified artifact is not available in the offline cache"
		local downloaded
		downloaded="$(mktemp "$CACHE_DIR/artifact.download.XXXXXX")"
		TEMP_PATHS+=("$downloaded")
		download_file "$artifact_url" "$downloaded" "$MAX_ARTIFACT_SIZE" ||
			die "could not download release artifact"
		actual_size="$(stat -c '%s' "$downloaded")"
		[[ "$actual_size" == "$artifact_size" ]] || die "artifact size mismatch: expected $artifact_size, got $actual_size"
		actual_sha="$(sha256sum "$downloaded" | awk '{print tolower($1)}')"
		[[ "$actual_sha" == "$artifact_sha" ]] || die "artifact SHA-256 mismatch"
		mv -- "$downloaded" "$destination"
	fi
	actual_size="$(stat -c '%s' "$destination")"
	actual_sha="$(sha256sum "$destination" | awk '{print tolower($1)}')"
	[[ "$actual_size" == "$artifact_size" && "$actual_sha" == "$artifact_sha" ]] || die "cached artifact failed verification"
	signature_url="$(artifact_signature_metadata "$manifest" url)"
	signature_format="$(artifact_signature_metadata "$manifest" format)"
	if [[ -n "$signature_url" || -n "$signature_format" ]]; then
		verify_declared_signature "$destination" "$signature_url" "$signature_format" artifact
		LAST_ARTIFACT_SIGNED=1
	fi
	if (( AUTO_MODE )) && (( LAST_MANIFEST_SIGNED == 0 )); then
		die "automatic apply requires a valid trusted manifest signature"
	fi
}

command_apply() {
	local supplied_manifest="${1:-}" installed manifest available comparison configured channel artifact_sha artifact_cache staging payload_root
	installed="$(current_version)"
	if [[ -n "$supplied_manifest" ]]; then
		manifest="$supplied_manifest"
	else
		manifest="$(mktemp "$CACHE_DIR/manifest.apply.XXXXXX")"
		TEMP_PATHS+=("$manifest")
		load_manifest_for_command "$manifest"
	fi
	configured="$(jq -r 'if has("configured") then .configured else true end' "$manifest")"
	channel="$(jq_string '.channel' "$manifest")"
	[[ "$configured" == "true" ]] || die "update source is not configured"
	available="$(jq_string '.version' "$manifest")"
	comparison="$(semver_compare "$available" "$installed")"
	if (( comparison == 0 )); then
		printf 'already current: %s\n' "$installed"
		return
	elif (( comparison < 0 && ALLOW_DOWNGRADE == 0 )); then
		die "manifest version $available is older than installed $installed; use --allow-downgrade manually"
	fi
	(( AUTO_MODE == 0 || comparison > 0 )) || die "automatic apply cannot downgrade"
	if (( AUTO_MODE )) && [[ "$channel" != stable ]]; then
		die "automatic apply requires the stable release channel"
	fi
	if (( AUTO_MODE )) && ! is_same_series_patch_upgrade "$installed" "$available"; then
		die "automatic apply is limited to stable patch updates within the installed major/minor series"
	fi
	artifact_sha="$(jq_string '.artifact.sha256 // .artifact_sha256 // empty' "$manifest")"
	artifact_sha="${artifact_sha,,}"
	artifact_cache="$CACHE_DIR/tele-brain-${available}-${artifact_sha:0:16}.tar"
	download_and_verify_artifact "$manifest" "$artifact_cache"
	staging="$(mktemp -d "$(dirname -- "$INSTALL_DIR")/.tele-brain-stage.XXXXXX")"
	TEMP_PATHS+=("$staging")
	validate_archive "$artifact_cache"
	extract_archive "$artifact_cache" "$staging"
	validate_extracted_links "$staging"
	payload_root="$(find_payload_root "$staging")"
	preflight_payload "$payload_root" "$available"
	activate_payload "$payload_root" "$available" "$artifact_sha" "$staging"
}

command_status() {
	local installed="unknown" previous="none" previous_path="none" checked="never" available="unknown" pending="none" timer_sync="ok"
	if [[ -f "$INSTALL_DIR/VERSION" ]]; then
		IFS= read -r installed <"$INSTALL_DIR/VERSION" || true
	fi
	if [[ -s "$STATE_FILE" ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
		previous="$(jq -r '.previous_version // "none"' "$STATE_FILE")"
		previous_path="$(jq -r '.previous_path // "none"' "$STATE_FILE")"
	fi
	if [[ -s "$STATE_FILE.last-check" ]] && jq -e 'type == "object"' "$STATE_FILE.last-check" >/dev/null 2>&1; then
		checked="$(jq -r '.checked_at // "never"' "$STATE_FILE.last-check")"
		available="$(jq -r '.available_version // "unknown"' "$STATE_FILE.last-check")"
	fi
	printf 'installed: %s\n' "$installed"
	printf 'previous: %s\n' "$previous"
	printf 'previous_path: %s\n' "$previous_path"
	[[ -s "$PENDING_FILE" ]] && pending="yes"
	printf 'pending_transaction: %s\n' "$pending"
	[[ -s "$TIMER_WARNING_FILE" ]] && timer_sync="required"
	printf 'timer_sync: %s\n' "$timer_sync"
	if [[ "$timer_sync" == required ]]; then
		printf 'timer_sync_warning: %s\n' "$TIMER_WARNING_FILE"
	fi
	printf 'last_checked: %s\n' "$checked"
	printf 'last_available: %s\n' "$available"
	printf 'manifest: %s\n' "$MANIFEST_URL"
	printf 'state_dir: %s\n' "$STATE_DIR"
	printf 'cache_dir: %s\n' "$CACHE_DIR"
}

command_rollback() {
	local previous_path previous_version active_version
	[[ -s "$STATE_FILE" ]] || die "no rollback state is available"
	jq -e 'type == "object"' "$STATE_FILE" >/dev/null || die "rollback state is invalid"
	previous_path="$(jq_string '.previous_path // empty' "$STATE_FILE")"
	previous_version="$(jq_string '.previous_version // empty' "$STATE_FILE")"
	[[ -n "$previous_path" && ( -e "$previous_path" || -L "$previous_path" ) ]] || die "previous installation is unavailable"
	validate_backup_path "$previous_path" || die "rollback path is outside the managed backup namespace"
	acquire_operation_lock
	recover_missing_install
	preflight_payload "$previous_path" "$previous_version" 1
	validate_rollback_data "$previous_path"
	active_version="$(current_version)"
	supports_atomic_exchange || die "GNU mv with --exchange and --no-copy is required for safe rollback"
	write_pending_transaction rollback "$active_version" "$previous_version" "$previous_path" ||
		die "could not record pending rollback"
	begin_critical_exchange
	if ! atomic_exchange "$INSTALL_DIR" "$previous_path"; then
		rm -f -- "$PENDING_FILE"
		end_critical_exchange
		die "could not atomically activate the previous installation"
	fi
	if ! write_rollback_state "$previous_version" "$active_version" "$previous_path"; then
		log "could not record rollback state; restoring active installation"
		atomic_exchange "$INSTALL_DIR" "$previous_path" || die "rollback state write and atomic restore both failed"
		rm -f -- "$PENDING_FILE"
		end_critical_exchange
		die "rollback state could not be written; active installation restored"
	fi
	rm -f -- "$PENDING_FILE"
	end_critical_exchange
	refresh_installed_timer_units
	printf 'rolled back: %s -> %s\n' "$active_version" "$previous_version"
}

parse_args() {
	COMMAND=""
	while (( $# > 0 )); do
		case "$1" in
		check|--check) [[ -z "$COMMAND" ]] || die "multiple commands supplied"; COMMAND=check ;;
		apply|--apply) [[ -z "$COMMAND" ]] || die "multiple commands supplied"; COMMAND=apply ;;
		scheduled) [[ -z "$COMMAND" ]] || die "multiple commands supplied"; COMMAND=scheduled ;;
		status|--status) [[ -z "$COMMAND" ]] || die "multiple commands supplied"; COMMAND=status ;;
		rollback|--rollback) [[ -z "$COMMAND" ]] || die "multiple commands supplied"; COMMAND=rollback ;;
		--auto) AUTO_MODE=1 ;;
		--offline) OFFLINE_MODE=1 ;;
		--allow-downgrade) ALLOW_DOWNGRADE=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
		esac
		shift
	done
	[[ -n "$COMMAND" ]] || { usage >&2; exit 2; }
	if (( AUTO_MODE )) && [[ "$COMMAND" != "apply" ]]; then
		die "--auto is valid only with apply"
	fi
	(( ALLOW_DOWNGRADE == 0 || AUTO_MODE == 0 )) || die "automatic downgrade is not allowed"
}

main() {
	parse_args "$@"
	require_commands
	ensure_dirs
	case "$COMMAND" in
	check)
		acquire_update_lock
		recover_missing_install
		recover_pending_transaction
		command_check
		;;
	apply)
		acquire_update_lock
		recover_missing_install
		recover_pending_transaction
		command_apply
		;;
	scheduled)
		acquire_update_lock
		recover_missing_install
		recover_pending_transaction
		command_scheduled
		;;
	status)
		command_status
		;;
	rollback)
		acquire_update_lock
		recover_missing_install
		recover_pending_transaction
		command_rollback
		;;
	esac
}

main "$@"
