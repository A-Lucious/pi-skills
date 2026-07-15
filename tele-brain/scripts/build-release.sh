#!/usr/bin/env bash
set -euo pipefail

umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_DIR="$SKILL_ROOT/dist"
VERSION=""
ARTIFACT_URL=""
MANIFEST_URL=""
OPENSSL_PRIVATE_KEY=""
SEQUENCE=""
SKIP_TESTS=0
STAGING=""
OUTPUT_STAGING=""

usage() {
	cat <<'EOF'
Usage: scripts/build-release.sh [options]

Options:
  --version VERSION          Release SemVer; defaults to VERSION file.
  --output-dir DIRECTORY     Output directory; defaults to ./dist.
  --artifact-url URL         Published artifact URL. Defaults to local file:// URL.
  --manifest-url URL         Published manifest URL, used for its signature URL.
  --sequence NUMBER          Monotonic release sequence. Defaults to UTC epoch seconds.
  --openssl-key FILE         Sign artifact and manifest with an RSA/EC private key.
  --skip-tests               Skip the default release regression suite.
  -h, --help                 Show this help.

The release archive never includes data/, dist/, caches, or update state.
EOF
}

die() {
	printf 'build-release: %s\n' "$*" >&2
	exit 1
}

is_semver() {
	[[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]
}

url_ok() {
	[[ "$1" =~ ^https://[^[:space:]]+$ || "$1" =~ ^file://[^[:space:]]+$ ]]
}

file_url() {
	local encoded
	encoded="$(jq -nr --arg path "$1" '$path | @uri | gsub("%2F"; "/")')" ||
		die "could not encode local artifact URL"
	printf 'file://%s' "$encoded"
}

while (($# > 0)); do
	case "$1" in
	--version)
		(($# >= 2)) || die "--version requires a value"
		VERSION="$2"
		shift 2
		;;
	--output-dir)
		(($# >= 2)) || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--artifact-url)
		(($# >= 2)) || die "--artifact-url requires a value"
		ARTIFACT_URL="$2"
		shift 2
		;;
	--manifest-url)
		(($# >= 2)) || die "--manifest-url requires a value"
		MANIFEST_URL="$2"
		shift 2
		;;
	--sequence)
		(($# >= 2)) || die "--sequence requires a value"
		SEQUENCE="$2"
		shift 2
		;;
	--openssl-key)
		(($# >= 2)) || die "--openssl-key requires a value"
		OPENSSL_PRIVATE_KEY="$2"
		shift 2
		;;
	--skip-tests)
		SKIP_TESTS=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

for command_name in bash jq tar sha256sum stat realpath mktemp cp find chmod date awk mv rm; do
	command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

[[ -r "$SKILL_ROOT/VERSION" ]] || die "VERSION file is missing"
IFS= read -r SOURCE_VERSION <"$SKILL_ROOT/VERSION" || true
is_semver "$SOURCE_VERSION" || die "VERSION file does not contain valid SemVer: $SOURCE_VERSION"
if [[ -z "$VERSION" ]]; then
	VERSION="$SOURCE_VERSION"
elif [[ "$VERSION" != "$SOURCE_VERSION" ]]; then
	die "--version $VERSION does not match VERSION file $SOURCE_VERSION"
fi
is_semver "$VERSION" || die "invalid SemVer: $VERSION"
if [[ -n "$SEQUENCE" ]]; then
	[[ "$SEQUENCE" =~ ^[1-9][0-9]*$ ]] || die "sequence must be a positive integer"
else
	SEQUENCE="$(date -u +%s)"
fi

if [[ -n "$OPENSSL_PRIVATE_KEY" ]]; then
	command -v openssl >/dev/null 2>&1 || die "openssl is required for signing"
	[[ -r "$OPENSSL_PRIVATE_KEY" ]] || die "private key is not readable: $OPENSSL_PRIVATE_KEY"
fi

if (( SKIP_TESTS == 0 )); then
	for script in "$SKILL_ROOT/scan.sh" "$SKILL_ROOT/update.sh" "$SKILL_ROOT/install-timers.sh" \
		"$SKILL_ROOT/bin/tele-brain" "$SKILL_ROOT/tests/test_scan.sh" \
		"$SKILL_ROOT/tests/test_timers.sh" "$SKILL_ROOT/tests/test_update.sh" \
		"$SKILL_ROOT/tests/test_release.sh"; do
		bash -n "$script" || die "bash syntax check failed: $script"
	done
	"$SKILL_ROOT/tests/test_scan.sh"
	"$SKILL_ROOT/tests/test_timers.sh"
	"$SKILL_ROOT/tests/test_update.sh"
	"$SKILL_ROOT/tests/test_release.sh"
fi

mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(realpath -- "$OUTPUT_DIR")"
STAGING="$(mktemp -d)"
OUTPUT_STAGING="$(mktemp -d "$OUTPUT_DIR/.release.XXXXXX")"
cleanup() {
	[[ -z "$STAGING" ]] || rm -rf -- "$STAGING"
	[[ -z "$OUTPUT_STAGING" ]] || rm -rf -- "$OUTPUT_STAGING"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
PAYLOAD="$STAGING/tele-brain"
mkdir -p -- "$PAYLOAD/bin" "$PAYLOAD/config" "$PAYLOAD/scripts" "$PAYLOAD/keys" "$PAYLOAD/systemd" "$PAYLOAD/tests"

FILES=(.gitignore RELEASING.md SKILL.md VERSION scan.sh update.sh install-timers.sh release-manifest.json)
for relative in "${FILES[@]}"; do
	[[ -f "$SKILL_ROOT/$relative" ]] || die "required release file is missing: $relative"
	cp -p -- "$SKILL_ROOT/$relative" "$PAYLOAD/$relative"
done

for relative in bin/tele-brain config/environment.example keys/release-public.pem scripts/build-release.sh systemd/tele-brain-refresh.service \
	systemd/tele-brain-refresh.timer systemd/tele-brain-update.service \
	systemd/tele-brain-update.timer tests/test_scan.sh tests/test_timers.sh tests/test_update.sh \
	tests/test_release.sh; do
	[[ -f "$SKILL_ROOT/$relative" ]] || die "required release file is missing: $relative"
	cp -p -- "$SKILL_ROOT/$relative" "$PAYLOAD/$relative"
done

printf '%s\n' "$VERSION" >"$PAYLOAD/VERSION"
jq -n --arg version "$VERSION" \
	'{schema_version:1, product:"tele-brain", channel:"stable", configured:false,
	  version:$version, sequence:0, artifact:{url:null, sha256:null, size:null, signature:null}}' \
	>"$PAYLOAD/release-manifest.json"
chmod 0755 "$PAYLOAD/scan.sh" "$PAYLOAD/update.sh" "$PAYLOAD/install-timers.sh" \
	"$PAYLOAD/bin/tele-brain" "$PAYLOAD/scripts/build-release.sh" \
	"$PAYLOAD/tests/test_scan.sh" "$PAYLOAD/tests/test_timers.sh" "$PAYLOAD/tests/test_update.sh" \
	"$PAYLOAD/tests/test_release.sh"
find "$PAYLOAD" -type f ! -perm /111 -exec chmod 0644 {} +

ARTIFACT_NAME="tele-brain-${VERSION}.tar.gz"
FINAL_ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"
FINAL_MANIFEST_PATH="$OUTPUT_DIR/release-manifest.json"
ARTIFACT_PATH="$OUTPUT_STAGING/$ARTIFACT_NAME"
MANIFEST_PATH="$OUTPUT_STAGING/release-manifest.json"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
	-czf "$ARTIFACT_PATH" -C "$STAGING" tele-brain
chmod 0644 "$ARTIFACT_PATH"

ARTIFACT_SHA256="$(sha256sum "$ARTIFACT_PATH" | awk '{print tolower($1)}')"
ARTIFACT_SIZE="$(stat -c '%s' "$ARTIFACT_PATH")"
[[ -n "$ARTIFACT_URL" ]] || ARTIFACT_URL="$(file_url "$FINAL_ARTIFACT_PATH")"
url_ok "$ARTIFACT_URL" || die "artifact URL must use https:// or file://"

ARTIFACT_SIGNATURE_URL=""
MANIFEST_SIGNATURE_URL=""
if [[ -n "$OPENSSL_PRIVATE_KEY" ]]; then
	ARTIFACT_SIGNATURE_URL="${ARTIFACT_URL}.sig"
	if [[ -n "$MANIFEST_URL" ]]; then
		url_ok "$MANIFEST_URL" || die "manifest URL must use https:// or file://"
		MANIFEST_SIGNATURE_URL="${MANIFEST_URL}.sig"
	elif [[ "$ARTIFACT_URL" == https://* ]]; then
		die "--manifest-url is required when signing a remotely published artifact"
	else
		MANIFEST_SIGNATURE_URL="$(file_url "${FINAL_MANIFEST_PATH}.sig")"
	fi
fi

jq -n \
	--arg product tele-brain \
	--arg channel stable \
	--arg version "$VERSION" \
	--arg issued_at "$(date -u -Iseconds)" \
	--arg artifact_url "$ARTIFACT_URL" \
	--arg artifact_sha256 "$ARTIFACT_SHA256" \
	--arg artifact_signature_url "$ARTIFACT_SIGNATURE_URL" \
	--arg manifest_signature_url "$MANIFEST_SIGNATURE_URL" \
	--argjson artifact_size "$ARTIFACT_SIZE" \
	--argjson sequence "$SEQUENCE" \
	'{schema_version:1, product:$product, channel:$channel, configured:true,
	  version:$version, sequence:$sequence, issued_at:$issued_at,
	  artifact:{url:$artifact_url, sha256:$artifact_sha256, size:$artifact_size,
	    signature:(if $artifact_signature_url == "" then null else
	      {format:"openssl", url:$artifact_signature_url} end)},
	  manifest_signature:(if $manifest_signature_url == "" then null else
	    {format:"openssl", url:$manifest_signature_url} end)}' >"$MANIFEST_PATH"
chmod 0644 "$MANIFEST_PATH"

if [[ -n "$OPENSSL_PRIVATE_KEY" ]]; then
	openssl dgst -sha256 -sign "$OPENSSL_PRIVATE_KEY" -out "${ARTIFACT_PATH}.sig" "$ARTIFACT_PATH"
	openssl dgst -sha256 -sign "$OPENSSL_PRIVATE_KEY" -out "${MANIFEST_PATH}.sig" "$MANIFEST_PATH"
	chmod 0644 "${ARTIFACT_PATH}.sig" "${MANIFEST_PATH}.sig"
fi

mv -f -- "$ARTIFACT_PATH" "$FINAL_ARTIFACT_PATH"
if [[ -n "$OPENSSL_PRIVATE_KEY" ]]; then
	mv -f -- "${ARTIFACT_PATH}.sig" "${FINAL_ARTIFACT_PATH}.sig"
	mv -f -- "${MANIFEST_PATH}.sig" "${FINAL_MANIFEST_PATH}.sig"
else
	rm -f -- "${FINAL_ARTIFACT_PATH}.sig" "${FINAL_MANIFEST_PATH}.sig"
fi
mv -f -- "$MANIFEST_PATH" "$FINAL_MANIFEST_PATH"

printf 'artifact: %s\n' "$FINAL_ARTIFACT_PATH"
printf 'sha256: %s\n' "$ARTIFACT_SHA256"
printf 'size: %s\n' "$ARTIFACT_SIZE"
printf 'manifest: %s\n' "$FINAL_MANIFEST_PATH"
if [[ -n "$OPENSSL_PRIVATE_KEY" ]]; then
	printf 'artifact_signature: %s.sig\n' "$FINAL_ARTIFACT_PATH"
	printf 'manifest_signature: %s.sig\n' "$FINAL_MANIFEST_PATH"
fi
