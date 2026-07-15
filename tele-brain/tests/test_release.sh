#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

if [[ "${TELE_BRAIN_RELEASE_TEST_NESTED:-0}" == 1 ]]; then
	printf 'ok - nested release contract test skipped\n'
	exit 0
fi

SKILL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_RELEASE="$SKILL_ROOT/scripts/build-release.sh"
TEST_ROOT="$(mktemp -d)"
OUTPUT="$TEST_ROOT/output.log"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

assert_output_contains() {
	local expected="$1"
	grep -Fq -- "$expected" "$OUTPUT" || {
		sed -n '1,160p' "$OUTPUT" >&2
		fail "output did not contain: $expected"
	}
}

CURRENT_VERSION="$(<"$SKILL_ROOT/VERSION")"
FIRST_OUT="$TEST_ROOT/first"
SECOND_OUT="$TEST_ROOT/second"
mkdir -p "$FIRST_OUT" "$SECOND_OUT"

if "$BUILD_RELEASE" --skip-tests --output-dir "$FIRST_OUT" --sequence 0 >"$OUTPUT" 2>&1; then
	fail 'release sequence 0 was accepted'
fi
assert_output_contains 'sequence must be a positive integer'
[[ -z "$(find "$FIRST_OUT" -mindepth 1 -print -quit)" ]] || fail 'invalid sequence left release output'
printf 'ok - release sequence must be positive\n'

if "$BUILD_RELEASE" --skip-tests --version 999.0.0 --output-dir "$FIRST_OUT" \
	--sequence 101 >"$OUTPUT" 2>&1; then
	fail 'a release version different from VERSION was accepted'
fi
assert_output_contains 'does not match VERSION file'
[[ -z "$(find "$FIRST_OUT" -mindepth 1 -print -quit)" ]] || fail 'version mismatch left release output'
printf 'ok - release version must match the source VERSION file\n'

"$BUILD_RELEASE" --skip-tests --output-dir "$FIRST_OUT" --sequence 101 >"$OUTPUT" 2>&1
"$BUILD_RELEASE" --skip-tests --output-dir "$SECOND_OUT" --sequence 101 >"$OUTPUT" 2>&1
FIRST_ARTIFACT="$FIRST_OUT/tele-brain-$CURRENT_VERSION.tar.gz"
SECOND_ARTIFACT="$SECOND_OUT/tele-brain-$CURRENT_VERSION.tar.gz"
[[ -s "$FIRST_ARTIFACT" && -s "$SECOND_ARTIFACT" ]] || fail 'release artifact was not created'
[[ "$(sha256sum "$FIRST_ARTIFACT" | awk '{print $1}')" == \
	"$(sha256sum "$SECOND_ARTIFACT" | awk '{print $1}')" ]] || fail 'release archive is not reproducible'
jq -e --arg version "$CURRENT_VERSION" \
	'.version == $version and .sequence == 101 and .configured == true' \
	"$FIRST_OUT/release-manifest.json" >/dev/null || fail 'published manifest metadata is incorrect'
tar -tzf "$FIRST_ARTIFACT" >"$TEST_ROOT/listing"
grep -Fxq 'tele-brain/tests/test_release.sh' "$TEST_ROOT/listing" || fail 'release contract test is missing from artifact'
grep -Fxq 'tele-brain/keys/release-public.pem' "$TEST_ROOT/listing" || fail 'bootstrap public key is missing from artifact'
if grep -Eq '^tele-brain/(data|dist)(/|$)' "$TEST_ROOT/listing"; then
	fail 'release archive contains local data or build output'
fi
printf 'ok - release artifacts are reproducible and exclude runtime data\n'

LATE_OUT="$TEST_ROOT/late-failure"
mkdir -p "$LATE_OUT"
if "$BUILD_RELEASE" --skip-tests --output-dir "$LATE_OUT" --sequence 102 \
	--artifact-url http://example.invalid/tele-brain.tar.gz >"$OUTPUT" 2>&1; then
	fail 'invalid artifact URL unexpectedly produced a release'
fi
assert_output_contains 'artifact URL must use https:// or file://'
[[ -z "$(find "$LATE_OUT" -mindepth 1 -print -quit)" ]] || fail 'late build failure left partial output'
printf 'ok - failed release builds clean staging and publish no manifest\n'

SPACE_OUT="$TEST_ROOT/release output"
"$BUILD_RELEASE" --skip-tests --output-dir "$SPACE_OUT" --sequence 105 >"$OUTPUT" 2>&1
SPACE_URL="$(jq -r '.artifact.url' "$SPACE_OUT/release-manifest.json")"
[[ "$SPACE_URL" == *'%20'* ]] || fail 'local artifact URL did not encode output-directory spaces'
curl --fail --silent --show-error --output "$TEST_ROOT/space-artifact" "$SPACE_URL" ||
	fail 'encoded local artifact URL could not be downloaded'
cmp -s "$TEST_ROOT/space-artifact" "$SPACE_OUT/tele-brain-$CURRENT_VERSION.tar.gz" ||
	fail 'encoded local artifact URL resolved to the wrong content'
printf 'ok - local release URLs support output directories containing spaces\n'

if command -v openssl >/dev/null 2>&1; then
	PRIVATE_KEY="$TEST_ROOT/private.pem"
	PUBLIC_KEY="$TEST_ROOT/public.pem"
	SIGNED_OUT="$TEST_ROOT/signed"
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
		-out "$PRIVATE_KEY" >/dev/null 2>&1
	openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
	"$BUILD_RELEASE" --skip-tests --output-dir "$SIGNED_OUT" --sequence 103 \
		--openssl-key "$PRIVATE_KEY" >"$OUTPUT" 2>&1
	SIGNED_ARTIFACT="$SIGNED_OUT/tele-brain-$CURRENT_VERSION.tar.gz"
	openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$SIGNED_ARTIFACT.sig" \
		"$SIGNED_ARTIFACT" >/dev/null 2>&1 || fail 'artifact signature did not verify'
	openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$SIGNED_OUT/release-manifest.json.sig" \
		"$SIGNED_OUT/release-manifest.json" >/dev/null 2>&1 || fail 'manifest signature did not verify'
	printf 'ok - release builder emits verifiable artifact and manifest signatures\n'
fi

BUMPED_ROOT="$TEST_ROOT/bumped/tele-brain"
mkdir -p "$BUMPED_ROOT"
cp -a -- "$SKILL_ROOT/." "$BUMPED_ROOT/"
rm -rf -- "$BUMPED_ROOT/dist"
printf '%s\n' 0.1.1 >"$BUMPED_ROOT/VERSION"
TELE_BRAIN_RELEASE_TEST_NESTED=1 "$BUMPED_ROOT/scripts/build-release.sh" \
	--output-dir "$TEST_ROOT/bumped-output" --sequence 104 >"$OUTPUT" 2>&1 || {
	sed -n '1,200p' "$OUTPUT" >&2
	fail 'default release checks failed after bumping VERSION'
}
[[ -s "$TEST_ROOT/bumped-output/tele-brain-0.1.1.tar.gz" ]] ||
	fail 'bumped release artifact was not created'
printf 'ok - default release checks work after VERSION is bumped\n'

printf 'all release tests passed\n'
