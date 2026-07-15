---
name: tele-brain
description: Use when querying or refreshing the local index of installed software, CLI help, GUI apps, browser plugins, IDE plugins, or managing tele-brain updates.
---

# Tele Brain

Tele Brain indexes installed local software into `~/.local/share/tele-brain/` and answers from that local index. Generated data is independent from the skill code and survives upgrades or rollbacks.

## Commands

Run commands from this skill directory:

- Refresh inventory: `./bin/tele-brain refresh`
- Refresh only when stale: `TELE_BRAIN_CAPTURE_HELP=0 ./bin/tele-brain refresh --if-stale 24h`
- Show health and freshness: `./bin/tele-brain status` or `./bin/tele-brain doctor`
- Check for a code update: `./bin/tele-brain update check`
- Apply an update explicitly: `./bin/tele-brain update apply`
- Roll back the previous update: `./bin/tele-brain update rollback`
- Manage automatic jobs: `./install-timers.sh install|uninstall|status`

## How To Answer Queries

1. Load `~/.local/share/tele-brain/index.yaml`.
2. If `last_scan` is older than 24 hours, start `tele-brain-refresh.service` without blocking when available. Otherwise run `TELE_BRAIN_CAPTURE_HELP=0 ./bin/tele-brain refresh --if-stale 24h` only when a current answer is required.
3. Match the requested software against `name`, `id`, `source`, and `type`.
4. If a matching entry has `reference`, inspect `reference_stale` before reading `~/.local/share/tele-brain/<reference>`.
5. Answer from a non-stale reference first. If `reference_stale: true`, treat its usage text as historical, prefer current index metadata, and explicitly say the cached help may be outdated. If no reference exists, say no local reference was captured.
6. For natural-language requests, keyword-search references before answering.

Do not wait for a background refresh when the existing index can answer the query. Do not apply skill code updates implicitly while answering an unrelated query.

## Refresh Workflow

Automatic refreshes inventory installed software without executing newly discovered CLI programs. Manual refresh may capture bounded `--help` output when `TELE_BRAIN_CAPTURE_HELP=1`.

The scanner writes:

- `index.yaml` - software metadata with schema and generator versions
- `references/` - generated local references
- `raw_help/` - bounded CLI help output
- `scan.log` - scan summaries and failures

Each refresh builds an isolated data generation and atomically switches the single `current` link. A failed scan leaves the previous index, references, and raw help active as one consistent generation.

## Update Workflow

The updater reads a configured release manifest, validates SemVer, archive size, SHA-256, archive paths, required files, and shell syntax before activation. It keeps the previous release for rollback and never includes generated data in a code package.

Official releases use the bundled `keys/release-public.pem` bootstrap key and a detached manifest signature. A custom `TELE_BRAIN_OPENSSL_PUBKEY_FILE` may override it. An explicit manual apply may accept a checksum-verified unsigned custom release; unattended official updates require the trusted signature. Network or validation failures leave the active version unchanged.

Skill instructions already loaded by a running agent do not change mid-turn. A code update takes effect on the next skill load or agent session.

## Scheduling

The user-level timers use these defaults:

- Inventory refresh: daily, persistent, with randomized delay
- Code update: weekly check; signed same-series patch apply only when explicitly enabled

Use `./install-timers.sh status` to inspect them.

Scheduled jobs optionally read `${XDG_CONFIG_HOME:-~/.config}/tele-brain/environment`. See `config/environment.example` for update-source, trusted-key, size-limit, and freshness settings. The refresh service always forces `TELE_BRAIN_CAPTURE_HELP=0` after loading that file.

Set `TELE_BRAIN_AUTO_APPLY=patch` to opt into unattended official stable patch updates; the bundled key verifies them. Minor, major, prerelease, unsigned, and invalid updates remain unapplied.

Repository maintainers should follow `RELEASING.md` to build and publish authenticated release artifacts.

## Data Link

`data/` should point to `~/.local/share/tele-brain/`. Release archives must not contain this machine-specific link.
