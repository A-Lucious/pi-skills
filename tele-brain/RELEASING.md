# Releasing Tele Brain

Tele Brain clients check this manifest by default:

```text
https://raw.githubusercontent.com/A-Lucious/pi-skills/master/tele-brain/release-manifest.json
```

The checked-in bootstrap manifest remains `configured: false` until the first artifact is published.

## One-time signing setup

Generate and protect a release key outside the repository:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out ~/.config/tele-brain/release-private.pem
chmod 0600 ~/.config/tele-brain/release-private.pem
openssl pkey -in ~/.config/tele-brain/release-private.pem -pubout \
  -out ~/.config/tele-brain/release-public.pem
```

The public key is committed as `keys/release-public.pem` and bundled as the official bootstrap trust anchor. Its DER SHA-256 fingerprint for the current key is:

```text
1cb5183d892d99efae511408d46f688aee6ccffca2a6675315d379a959bfdc7b
```

Never commit the private key. `TELE_BRAIN_OPENSSL_PUBKEY_FILE` is only needed to override the bundled key for a custom source or a planned key rotation.

## Client bootstrap

After installing or updating the Skill, verify the bundled key fingerprint and run:

```bash
./bin/tele-brain update check
```

The default source requires the detached `release-manifest.json.sig`; an unsigned configured default manifest is rejected. To opt into unattended official patch updates:

```bash
mkdir -p -m 700 "${XDG_CONFIG_HOME:-$HOME/.config}/tele-brain"
printf '%s\n' 'TELE_BRAIN_AUTO_APPLY=patch' \
  > "${XDG_CONFIG_HOME:-$HOME/.config}/tele-brain/environment"
./install-timers.sh install
```

## Build

After updating `VERSION`, build an artifact with immutable release URLs:

```bash
./scripts/build-release.sh \
  --version 0.1.0 \
  --artifact-url https://github.com/A-Lucious/pi-skills/releases/download/tele-brain-v0.1.0/tele-brain-0.1.0.tar.gz \
  --manifest-url https://raw.githubusercontent.com/A-Lucious/pi-skills/master/tele-brain/release-manifest.json \
  --openssl-key ~/.config/tele-brain/release-private.pem
```

The command writes a reproducible archive, release manifest, SHA-256 metadata, and detached signatures under `dist/`.

## Publish

1. Replace `tele-brain/release-manifest.json` with the generated `dist/release-manifest.json` and add `dist/release-manifest.json.sig` in the same commit.
2. Commit and push the manifest and signature to `master`.
3. Create the immutable `tele-brain-v0.1.0` tag and GitHub release at that commit.
4. Upload `dist/tele-brain-0.1.0.tar.gz`, its `.sig`, and `keys/release-public.pem` as release assets.
5. Verify from a clean client with `./bin/tele-brain update check`.
6. Test explicit apply and rollback before enabling `TELE_BRAIN_AUTO_APPLY=patch`.

Do not move or replace an existing version tag. Publish a new patch version instead.
