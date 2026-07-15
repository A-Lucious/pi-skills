#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_UPDATE="$SOURCE_DIR/update.sh"
TEST_ROOT="$(mktemp -d)"
INSTALL_DIR="$TEST_ROOT/install"
STATE_DIR="$TEST_ROOT/state"
CACHE_DIR="$TEST_ROOT/cache"
DATA_DIR="$TEST_ROOT/data"
MANIFEST="$TEST_ROOT/manifest.json"
OUTPUT="$TEST_ROOT/output.log"
TEST_HOME="$TEST_ROOT/home"

cleanup() {
	rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

pass() {
	printf 'ok - %s\n' "$*"
}

assert_file_equals() {
	local file="$1" expected="$2" actual
	IFS= read -r actual <"$file" || true
	[[ "$actual" == "$expected" ]] || fail "$file: expected $expected, got $actual"
}

assert_output_contains() {
	local expected="$1"
	grep -Fq -- "$expected" "$OUTPUT" || {
		sed -n '1,160p' "$OUTPUT" >&2
		fail "output did not contain: $expected"
	}
}

run_update_from() {
	local manifest_url="$1"
	shift
	env \
		HOME="$TEST_HOME" \
		XDG_CONFIG_HOME="$TEST_HOME/.config" \
		TELE_BRAIN_INSTALL_DIR="$INSTALL_DIR" \
		TELE_BRAIN_STATE_DIR="$STATE_DIR" \
		TELE_BRAIN_CACHE_DIR="$CACHE_DIR" \
		TELE_BRAIN_LOCK_FILE="$STATE_DIR/operation.lock" \
		TELE_BRAIN_MANIFEST_URL="$manifest_url" \
		"$SOURCE_UPDATE" "$@"
}

run_update() {
	run_update_from "file://$MANIFEST" "$@"
}

run_update_default_source() {
	env \
		HOME="$TEST_HOME" \
		XDG_CONFIG_HOME="$TEST_HOME/.config" \
		TELE_BRAIN_INSTALL_DIR="$INSTALL_DIR" \
		TELE_BRAIN_STATE_DIR="$STATE_DIR" \
		TELE_BRAIN_CACHE_DIR="$CACHE_DIR" \
		TELE_BRAIN_LOCK_FILE="$STATE_DIR/operation.lock" \
		TELE_BRAIN_DEFAULT_MANIFEST_URL="file://$MANIFEST" \
		TELE_BRAIN_MANIFEST_URL="file://$MANIFEST" \
		"$SOURCE_UPDATE" "$@"
}

write_manifest() {
	local version="$1" artifact="$2" sha="$3" size="$4"
	jq -n \
		--arg version "$version" \
		--arg url "file://$artifact" \
		--arg sha256 "$sha" \
		--argjson size "$size" \
		--argjson sequence 101 \
		'{schema_version:1, product:"tele-brain", channel:"stable", configured:true, version:$version,
		  sequence:$sequence,
		  artifact:{url:$url, sha256:$sha256, size:$size}}' >"$MANIFEST"
}

build_release() {
	local version="$1" artifact="$2" payload
	payload="$TEST_ROOT/payload-$version"
	mkdir -p -- "$payload/bin" "$payload/keys" "$payload/systemd"
	cp -- "$SOURCE_DIR/SKILL.md" "$payload/SKILL.md"
	cp -- "$SOURCE_DIR/scan.sh" "$payload/scan.sh"
	cp -- "$SOURCE_DIR/update.sh" "$payload/update.sh"
	cp -- "$SOURCE_DIR/bin/tele-brain" "$payload/bin/tele-brain"
	cp -- "$SOURCE_DIR/install-timers.sh" "$payload/install-timers.sh"
	cp -- "$SOURCE_DIR/keys/release-public.pem" "$payload/keys/release-public.pem"
	cp -- "$SOURCE_DIR/systemd/"* "$payload/systemd/"
	printf '%s\n' "$version" >"$payload/VERSION"
	jq -n --arg version "$version" \
		'{schema_version:1, product:"tele-brain", channel:"stable", configured:false, version:$version, sequence:0,
		  artifact:{url:null, sha256:null, size:null, signature:null}}' >"$payload/release-manifest.json"
	printf '%s\n' "$version" >"$payload/release-marker"
	chmod 755 -- "$payload/scan.sh" "$payload/update.sh" "$payload/bin/tele-brain" "$payload/install-timers.sh"
	tar -czf "$artifact" -C "$payload" .
}

mkdir -p -- "$INSTALL_DIR/bin" "$INSTALL_DIR/systemd" "$STATE_DIR" "$CACHE_DIR" "$DATA_DIR" "$TEST_HOME"
cp -- "$SOURCE_DIR/SKILL.md" "$INSTALL_DIR/SKILL.md"
cp -- "$SOURCE_DIR/scan.sh" "$INSTALL_DIR/scan.sh"
cp -- "$SOURCE_DIR/update.sh" "$INSTALL_DIR/update.sh"
cp -- "$SOURCE_DIR/bin/tele-brain" "$INSTALL_DIR/bin/tele-brain"
cp -- "$SOURCE_DIR/install-timers.sh" "$INSTALL_DIR/install-timers.sh"
mkdir -p -- "$INSTALL_DIR/keys"
cp -- "$SOURCE_DIR/keys/release-public.pem" "$INSTALL_DIR/keys/release-public.pem"
cp -- "$SOURCE_DIR/systemd/"* "$INSTALL_DIR/systemd/"
printf '%s\n' 0.1.0 >"$INSTALL_DIR/VERSION"
cp -- "$SOURCE_DIR/release-manifest.json" "$INSTALL_DIR/release-manifest.json"
ln -s -- "$DATA_DIR" "$INSTALL_DIR/data"
chmod 755 -- "$INSTALL_DIR/scan.sh" "$INSTALL_DIR/update.sh" "$INSTALL_DIR/bin/tele-brain" "$INSTALL_DIR/install-timers.sh"

ARTIFACT="$TEST_ROOT/tele-brain-0.1.1.tar.gz"
build_release 0.1.1 "$ARTIFACT"
SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
SIZE="$(stat -c '%s' "$ARTIFACT")"
write_manifest 0.1.1 "$ARTIFACT" "$SHA" "$SIZE"

if run_update_default_source check >"$OUTPUT" 2>&1; then
	fail 'default update source accepted a configured manifest without its detached signature'
fi
assert_output_contains 'could not download manifest signature'
pass 'default update source cannot downgrade manifest signature enforcement'

run_update check >"$OUTPUT" 2>&1
assert_output_contains 'status: update_available'
assert_output_contains 'available: 0.1.1'
pass 'file:// check reports an update'

if run_update_from "file://$TEST_ROOT/alternate-manifest.json" check --offline >"$OUTPUT" 2>&1; then
	fail 'offline mode reused a cached manifest from a different update source'
fi
assert_output_contains 'no cached manifest is available offline'
pass 'manifest caches are isolated by update source'

run_update scheduled >"$OUTPUT" 2>&1
assert_output_contains 'status: update_available'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'scheduled mode checks without applying by default'

if run_update apply --auto >"$OUTPUT" 2>&1; then
	fail 'unsigned automatic apply unexpectedly succeeded'
fi
assert_output_contains 'automatic apply requires a valid trusted manifest signature'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'automatic apply rejects an unsigned release'

run_update apply >"$OUTPUT" 2>&1
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.1
assert_file_equals "$INSTALL_DIR/release-marker" 0.1.1
[[ -L "$INSTALL_DIR/data" ]] || fail 'data link was not preserved'
[[ "$(readlink -- "$INSTALL_DIR/data")" == "$DATA_DIR" ]] || fail 'data link target changed'
pass 'file:// apply activates a verified artifact and preserves data'

run_update status >"$OUTPUT" 2>&1
assert_output_contains 'installed: 0.1.1'
assert_output_contains 'previous: 0.1.0'
pass 'status reports active and rollback versions'

if ! run_update rollback >"$OUTPUT" 2>&1; then
	sed -n '1,160p' "$OUTPUT" >&2
	fail 'rollback command failed'
fi
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
[[ -L "$INSTALL_DIR/data" ]] || fail 'rollback lost the data link'
[[ "$(readlink -- "$INSTALL_DIR/data")" == "$DATA_DIR" ]] || fail 'rollback changed the data link target'
pass 'rollback restores the previous installation'

PREVIOUS_PATH="$(jq -r '.previous_path' "$STATE_DIR/update-state.json")"
PENDING_CANDIDATE="$(dirname -- "$INSTALL_DIR")/.install.backup.pending-before-exchange"
cp -a -- "$PREVIOUS_PATH" "$PENDING_CANDIDATE"
jq -n \
	--arg type activate --arg from_version 0.1.0 --arg to_version 0.1.1 \
	--arg exchange_path "$PENDING_CANDIDATE" --arg artifact_sha256 "$SHA" \
	'{type:$type, from_version:$from_version, to_version:$to_version,
	  exchange_path:$exchange_path, artifact_sha256:$artifact_sha256}' \
	>"$STATE_DIR/update-pending.json"
run_update check >"$OUTPUT" 2>&1
[[ ! -e "$PENDING_CANDIDATE" ]] || fail 'pre-exchange candidate was not discarded during recovery'
[[ ! -e "$STATE_DIR/update-pending.json" ]] || fail 'pre-exchange pending state was not cleared'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'interrupted activation before exchange is safely discarded'

mv -T --exchange --no-copy -- "$INSTALL_DIR" "$PREVIOUS_PATH"
jq -n \
	--arg type activate --arg from_version 0.1.0 --arg to_version 0.1.1 \
	--arg exchange_path "$PREVIOUS_PATH" --arg artifact_sha256 "$SHA" \
	'{type:$type, from_version:$from_version, to_version:$to_version,
	  exchange_path:$exchange_path, artifact_sha256:$artifact_sha256}' \
	>"$STATE_DIR/update-pending.json"
run_update check >"$OUTPUT" 2>&1
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.1
[[ ! -e "$STATE_DIR/update-pending.json" ]] || fail 'post-exchange pending state was not finalized'
[[ "$(jq -r '.current_version' "$STATE_DIR/update-state.json")" == '0.1.1' ]] ||
	fail 'recovered activation state has the wrong current version'
run_update rollback >"$OUTPUT" 2>&1
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'interrupted activation after exchange is finalized and remains rollback-safe'

BAD_SHA_ARTIFACT="$TEST_ROOT/tele-brain-0.1.2.tar.gz"
build_release 0.1.2 "$BAD_SHA_ARTIFACT"
BAD_SHA_SIZE="$(stat -c '%s' "$BAD_SHA_ARTIFACT")"
write_manifest 0.1.2 "$BAD_SHA_ARTIFACT" \
	'0000000000000000000000000000000000000000000000000000000000000000' "$BAD_SHA_SIZE"
if run_update apply >"$OUTPUT" 2>&1; then
	fail 'artifact with bad SHA-256 unexpectedly succeeded'
fi
assert_output_contains 'artifact SHA-256 mismatch'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'bad SHA-256 is rejected without changing the installation'

MALICIOUS_SOURCE="$TEST_ROOT/malicious-source"
MALICIOUS_ARTIFACT="$TEST_ROOT/tele-brain-malicious.tar.gz"
mkdir -p -- "$MALICIOUS_SOURCE"
printf 'escape\n' >"$MALICIOUS_SOURCE/escape"
tar -czf "$MALICIOUS_ARTIFACT" -C "$MALICIOUS_SOURCE" \
	--transform='s|^escape$|../escape|' escape
MALICIOUS_SHA="$(sha256sum "$MALICIOUS_ARTIFACT" | awk '{print $1}')"
MALICIOUS_SIZE="$(stat -c '%s' "$MALICIOUS_ARTIFACT")"
write_manifest 0.1.2 "$MALICIOUS_ARTIFACT" "$MALICIOUS_SHA" "$MALICIOUS_SIZE"
if run_update apply >"$OUTPUT" 2>&1; then
	fail 'path-traversal archive unexpectedly succeeded'
fi
assert_output_contains 'archive contains parent traversal'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
[[ ! -e "$TEST_ROOT/escape" ]] || fail 'path-traversal archive wrote outside staging'
pass 'path traversal is rejected before extraction'

PAX_SOURCE="$TEST_ROOT/pax-source"
PAX_ARTIFACT="$TEST_ROOT/tele-brain-pax.tar.gz"
mkdir -p -- "$PAX_SOURCE"
printf 'pax\n' >"$PAX_SOURCE/member"
printf -v LONG_MEMBER '%*s' 4096 ''
LONG_MEMBER="${LONG_MEMBER// /a}"
tar --format=pax -czf "$PAX_ARTIFACT" -C "$PAX_SOURCE" \
	--transform="s|^member$|$LONG_MEMBER|" member
PAX_SHA="$(sha256sum "$PAX_ARTIFACT" | awk '{print $1}')"
PAX_SIZE="$(stat -c '%s' "$PAX_ARTIFACT")"
write_manifest 0.1.2 "$PAX_ARTIFACT" "$PAX_SHA" "$PAX_SIZE"
if TELE_BRAIN_MAX_ARCHIVE_LISTING_BYTES=1024 run_update apply >"$OUTPUT" 2>&1; then
	fail 'oversized PAX metadata listing unexpectedly succeeded'
fi
assert_output_contains 'archive contains too many entries or an oversized listing'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'oversized PAX metadata is rejected before extraction'

write_manifest 0.1.1 "$ARTIFACT" "$SHA" "$SIZE"
if TELE_BRAIN_MAX_ARCHIVE_ENTRIES=2 run_update apply >"$OUTPUT" 2>&1; then
	fail 'archive entry listing limit was not enforced'
fi
assert_output_contains 'archive contains too many entries or an oversized listing'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'archive listing limits stop oversized metadata streams'

LARGE_ARTIFACT="$TEST_ROOT/tele-brain-0.1.3.tar.gz"
build_release 0.1.3 "$LARGE_ARTIFACT"
truncate -s 4096 "$TEST_ROOT/payload-0.1.3/expanded-content"
tar -czf "$LARGE_ARTIFACT" -C "$TEST_ROOT/payload-0.1.3" .
LARGE_SHA="$(sha256sum "$LARGE_ARTIFACT" | awk '{print $1}')"
LARGE_SIZE="$(stat -c '%s' "$LARGE_ARTIFACT")"
write_manifest 0.1.3 "$LARGE_ARTIFACT" "$LARGE_SHA" "$LARGE_SIZE"
if TELE_BRAIN_MAX_EXTRACTED_SIZE=1024 run_update apply >"$OUTPUT" 2>&1; then
	fail 'archive exceeding the expansion limit unexpectedly succeeded'
fi
assert_output_contains 'archive expands beyond the allowed size'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'archive expansion limit is enforced before extraction'

OWNER_ARTIFACT="$TEST_ROOT/tele-brain-0.1.4.tar.gz"
build_release 0.1.4 "$OWNER_ARTIFACT"
truncate -s 4096 "$TEST_ROOT/payload-0.1.4/expanded-content"
tar --owner='foo bar:123' --group='baz qux:456' -czf "$OWNER_ARTIFACT" -C "$TEST_ROOT/payload-0.1.4" .
OWNER_SHA="$(sha256sum "$OWNER_ARTIFACT" | awk '{print $1}')"
OWNER_SIZE="$(stat -c '%s' "$OWNER_ARTIFACT")"
write_manifest 0.1.4 "$OWNER_ARTIFACT" "$OWNER_SHA" "$OWNER_SIZE"
if TELE_BRAIN_MAX_EXTRACTED_SIZE=1024 run_update apply >"$OUTPUT" 2>&1; then
	fail 'archive with spaced owner names bypassed the expansion limit'
fi
assert_output_contains 'archive expands beyond the allowed size'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'numeric-owner archive inspection prevents owner-field size bypasses'

MINOR_ARTIFACT="$TEST_ROOT/tele-brain-0.2.0.tar.gz"
build_release 0.2.0 "$MINOR_ARTIFACT"
MINOR_SHA="$(sha256sum "$MINOR_ARTIFACT" | awk '{print $1}')"
MINOR_SIZE="$(stat -c '%s' "$MINOR_ARTIFACT")"
write_manifest 0.2.0 "$MINOR_ARTIFACT" "$MINOR_SHA" "$MINOR_SIZE"
if run_update apply --auto >"$OUTPUT" 2>&1; then
	fail 'automatic minor update unexpectedly succeeded'
fi
assert_output_contains 'automatic apply is limited to stable patch updates'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'automatic apply rejects a cross-minor update'

TELE_BRAIN_AUTO_APPLY=patch run_update scheduled >"$OUTPUT" 2>&1
assert_output_contains 'status: manual_update_required'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
pass 'scheduled patch policy leaves cross-minor updates for manual review'

write_manifest 0.1.1 "$ARTIFACT" "$SHA" "$SIZE"
jq '.channel = "beta"' "$MANIFEST" >"$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
if run_update apply --auto >"$OUTPUT" 2>&1; then
	fail 'automatic apply accepted a beta-channel stable-looking patch'
fi
assert_output_contains 'automatic apply requires the stable release channel'
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
TELE_BRAIN_AUTO_APPLY=patch run_update scheduled >"$OUTPUT" 2>&1
assert_output_contains 'status: manual_update_required'
pass 'beta-channel releases always require manual review'

if command -v openssl >/dev/null 2>&1; then
	PRIVATE_KEY="$TEST_ROOT/release-private.pem"
	PUBLIC_KEY="$TEST_ROOT/release-public.pem"
	SIGNATURE="$TEST_ROOT/tele-brain-0.1.1.sig"
	MANIFEST_SIGNATURE="$TEST_ROOT/release-manifest.sig"
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" >/dev/null 2>&1
	openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
	openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$SIGNATURE" "$ARTIFACT"
	jq -n \
		--arg version 0.1.1 \
		--arg url "file://$ARTIFACT" \
		--arg sha256 "$SHA" \
		--argjson size "$SIZE" \
		--argjson sequence 101 \
		--arg signature_url "file://$SIGNATURE" \
		--arg manifest_signature_url "file://$MANIFEST_SIGNATURE" \
		'{schema_version:1, product:"tele-brain", channel:"stable", configured:true, version:$version,
		  sequence:$sequence,
		  artifact:{url:$url, sha256:$sha256, size:$size,
		    signature:{format:"openssl", url:$signature_url}},
		  manifest_signature:{format:"openssl", url:$manifest_signature_url}}' >"$MANIFEST"
	openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$MANIFEST_SIGNATURE" "$MANIFEST"
	if ! TELE_BRAIN_AUTO_APPLY=patch TELE_BRAIN_OPENSSL_PUBKEY_FILE="$PUBLIC_KEY" \
		run_update scheduled >"$OUTPUT" 2>&1; then
		sed -n '1,160p' "$OUTPUT" >&2
		fail 'signed scheduled patch apply failed'
	fi
	assert_output_contains 'status: applying_signed_patch'
	assert_file_equals "$INSTALL_DIR/VERSION" 0.1.1
	pass 'trusted OpenSSL signature permits a scheduled patch update'

	run_update rollback >"$OUTPUT" 2>&1
	assert_file_equals "$INSTALL_DIR/VERSION" 0.1.0
	if ! TELE_BRAIN_OPENSSL_PUBKEY_FILE="$PUBLIC_KEY" \
		run_update apply --auto --offline >"$OUTPUT" 2>&1; then
		sed -n '1,160p' "$OUTPUT" >&2
		fail 'offline apply from a fully verified cache failed'
	fi
	assert_file_equals "$INSTALL_DIR/VERSION" 0.1.1
	pass 'verified manifest, artifact, and signature caches support offline apply'

	for sequence in 202 201; do
		jq -n \
			--arg version 0.1.1 \
			--arg url "file://$ARTIFACT" \
			--arg sha256 "$SHA" \
			--argjson size "$SIZE" \
			--argjson sequence "$sequence" \
			--arg artifact_signature_url "file://$SIGNATURE" \
			--arg manifest_signature_url "file://$MANIFEST_SIGNATURE" \
			'{schema_version:1, product:"tele-brain", channel:"stable", configured:true,
			  version:$version, sequence:$sequence,
			  artifact:{url:$url, sha256:$sha256, size:$size,
			    signature:{format:"openssl", url:$artifact_signature_url}},
			  manifest_signature:{format:"openssl", url:$manifest_signature_url}}' >"$MANIFEST"
		openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$MANIFEST_SIGNATURE" "$MANIFEST"
		if [[ "$sequence" == 202 ]]; then
			TELE_BRAIN_OPENSSL_PUBKEY_FILE="$PUBLIC_KEY" run_update check >"$OUTPUT" 2>&1
			assert_output_contains 'status: up_to_date'
		else
			if TELE_BRAIN_OPENSSL_PUBKEY_FILE="$PUBLIC_KEY" run_update check >"$OUTPUT" 2>&1; then
				fail 'older signed manifest sequence was accepted'
			fi
			assert_output_contains 'signed manifest sequence rollback detected'
		fi
	done
	jq '.sequence = 202 | .notes = "equivocation"' "$MANIFEST" >"$MANIFEST.tmp"
	mv "$MANIFEST.tmp" "$MANIFEST"
	openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$MANIFEST_SIGNATURE" "$MANIFEST"
	if TELE_BRAIN_OPENSSL_PUBKEY_FILE="$PUBLIC_KEY" run_update check >"$OUTPUT" 2>&1; then
		fail 'same-sequence signed manifest equivocation was accepted'
	fi
	assert_output_contains 'signed manifest sequence equivocation detected'
	pass 'signed manifest sequence rollback and equivocation are rejected'
fi

FAKE_SYSTEMCTL="$TEST_ROOT/systemctl"
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
printf '%s\n' '#!/usr/bin/env bash' \
	'printf "%s\n" "$*" >>"${TELE_BRAIN_SYSTEMCTL_LOG:?}"' \
	'[[ "${TELE_BRAIN_FAKE_SYSTEMCTL_FAIL:-0}" != 1 ]]' >"$FAKE_SYSTEMCTL"
chmod 0755 "$FAKE_SYSTEMCTL"
export TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL"
export TELE_BRAIN_SYSTEMCTL_LOG="$SYSTEMCTL_LOG"
mkdir -p "$TEST_HOME/.config/systemd/user"
printf 'stale unit\n' >"$TEST_HOME/.config/systemd/user/tele-brain-update.service"

for version in 0.1.5 0.1.6 0.1.7 0.1.8; do
	RETENTION_ARTIFACT="$TEST_ROOT/tele-brain-$version.tar.gz"
	build_release "$version" "$RETENTION_ARTIFACT"
	RETENTION_SHA="$(sha256sum "$RETENTION_ARTIFACT" | awk '{print $1}')"
	RETENTION_SIZE="$(stat -c '%s' "$RETENTION_ARTIFACT")"
	write_manifest "$version" "$RETENTION_ARTIFACT" "$RETENTION_SHA" "$RETENTION_SIZE"
	run_update apply >"$OUTPUT" 2>&1
done
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.8
assert_output_contains 'updated:'
grep -Fq -- "$INSTALL_DIR/bin/tele-brain" "$TEST_HOME/.config/systemd/user/tele-brain-update.service" ||
	fail 'activation did not rerender installed user units'
grep -Fq -- 'daemon-reload' "$SYSTEMCTL_LOG" || fail 'activation did not reload systemd user units'
BACKUP_COUNT="$(find "$(dirname -- "$INSTALL_DIR")" -mindepth 1 -maxdepth 1 \
	-name '.install.backup.*' -print | wc -l)"
[[ "$BACKUP_COUNT" == 3 ]] || fail "backup retention expected 3 installations, got $BACKUP_COUNT"
ROLLBACK_PATH="$(jq -r '.previous_path' "$STATE_DIR/update-state.json")"
[[ -d "$ROLLBACK_PATH" ]] || fail 'the current rollback target was pruned'
pass 'activation refreshes timer units and retains one rollback plus two older backups'

FAIL_ARTIFACT="$TEST_ROOT/tele-brain-0.1.9.tar.gz"
build_release 0.1.9 "$FAIL_ARTIFACT"
FAIL_SHA="$(sha256sum "$FAIL_ARTIFACT" | awk '{print $1}')"
FAIL_SIZE="$(stat -c '%s' "$FAIL_ARTIFACT")"
write_manifest 0.1.9 "$FAIL_ARTIFACT" "$FAIL_SHA" "$FAIL_SIZE"
export TELE_BRAIN_FAKE_SYSTEMCTL_FAIL=1
run_update apply >"$OUTPUT" 2>&1
assert_file_equals "$INSTALL_DIR/VERSION" 0.1.9
[[ -s "$STATE_DIR/timer-refresh-required.json" ]] || fail 'timer refresh failure was not persisted'
run_update status >"$OUTPUT" 2>&1
assert_output_contains 'timer_sync: required'
unset TELE_BRAIN_FAKE_SYSTEMCTL_FAIL
HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_HOME/.config" TELE_BRAIN_STATE_DIR="$STATE_DIR" \
	TELE_BRAIN_SYSTEMCTL="$FAKE_SYSTEMCTL" "$INSTALL_DIR/install-timers.sh" install >"$OUTPUT" 2>&1
[[ ! -e "$STATE_DIR/timer-refresh-required.json" ]] || fail 'manual timer repair did not clear the warning'
run_update status >"$OUTPUT" 2>&1
assert_output_contains 'timer_sync: ok'
pass 'timer refresh failures remain visible until repaired'

printf 'all updater tests passed\n'
