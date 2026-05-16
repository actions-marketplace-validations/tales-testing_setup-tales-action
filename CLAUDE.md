# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A standalone, Marketplace-publishable **composite GitHub Action** that downloads and installs the `tales` CLI from GitHub Releases of `tales-testing/tales` (GoReleaser-built artifacts).

**Hard constraints — do not violate without explicit instruction:**

- **Composite only.** No JavaScript action, no `node_modules`, no `package.json`, no build step, no TypeScript. All logic stays in Bash.
- **Install only.** The action must never run Tales tests, upload reports, or do anything beyond placing `tales` on `PATH` and exposing outputs.
- **No Windows support.** OS detection must reject anything that isn't Linux or macOS.
- **No `jq` dependency.** Parse the GitHub Releases API with `grep`/`sed`.
- **No extra sha256 dependencies.** Use `sha256sum` on Linux and `shasum -a 256` on macOS.

## Commands

```bash
# Run unit tests (no network, ~instant)
bash scripts/test-install.sh

# Lint (-x so it follows the sourced install.sh from test-install.sh)
shellcheck -x scripts/*.sh

# Local end-to-end smoke (requires real Tales releases to exist):
INPUT_VERSION=latest \
INPUT_REPO=tales-testing/tales \
INPUT_INSTALL_DIR=/tmp/tales/bin \
INPUT_VERIFY_CHECKSUM=true \
bash scripts/install.sh
```

CI runs `shellcheck -x scripts/*.sh` then `bash scripts/test-install.sh` on every push/PR — see [.github/workflows/ci.yml](.github/workflows/ci.yml).

The integration workflow ([.github/workflows/integration.yml](.github/workflows/integration.yml)) is `workflow_dispatch`-only and intentionally does **not** run on push. Keep it that way until `tales-testing/tales` has published releases.

## Architecture

Three files carry the entire implementation:

### [action.yml](action.yml)
A composite action with one step. It exports each input as an `INPUT_*` env var and execs `bash "${{ github.action_path }}/scripts/install.sh"`. Outputs are wired from `steps.install.outputs.*`, which the script writes via `$GITHUB_OUTPUT`.

### [scripts/install.sh](scripts/install.sh)
All install logic. Organized as small helpers (`detect_os`, `detect_arch`, `normalize_version`, `archive_name`, `parse_tag_name`, `resolve_latest_version`, `download`, `verify_checksum`, `extract_archive`) plus a `main` that orchestrates them.

**Library mode is the key testability trick:** the script ends with

```bash
if [[ "${TALES_INSTALL_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
```

Set `TALES_INSTALL_LIB_ONLY=1` to source the script and get its functions without running `main`. The test script relies on this.

**Token handling rules** (already implemented — preserve them):
- Build curl args in a bash array. Only add `Authorization: Bearer …` when `INPUT_GITHUB_TOKEN` is non-empty (avoids the "empty header" trap on public repos).
- In `download()`, only attach the token when the URL host is `github.com` or `api.github.com`. Never leak the token to other hosts.

### [scripts/test-install.sh](scripts/test-install.sh)
Plain Bash unit tests, no `bats`. Sources `install.sh` in library mode. Uses `assert_eq` and `assert_fails` helpers.

**Subshell pitfall:** `fail()` in `install.sh` calls `exit 1`. If a test calls a function that triggers `fail()` directly in the test shell, it kills the test runner. `assert_fails` wraps the call in `( ... )` so the exit only kills the subshell — keep that wrapping. Tests that stub `uname` go through `with_uname` (also a subshell) for the same reason.

## When changing things

- Adding a new helper to `install.sh`: add a unit test in `test-install.sh` that exercises it via the library-mode source. Tests must run on both Linux and macOS (the test script auto-picks `sha256sum` vs `shasum`).
- Adding a new input: declare it in `action.yml`, forward it via `env:` as `INPUT_<NAME>`, and read it in `main()` with a default (`${INPUT_FOO:-default}`). Update the README inputs table.
- Adding a new output: write it to `$GITHUB_OUTPUT` from inside `main()`, then add it under `outputs:` in `action.yml` with `value: ${{ steps.install.outputs.<name> }}`.
- Renaming or removing a helper: grep `scripts/test-install.sh` first — tests source the script and call helpers by name.

## Release process

Marketplace consumers pin against the floating `v1` tag, so every release MUST update it. The full flow:

### 1. Pick the version (semver)

- **patch** (`v1.0.x` → `v1.0.x+1`): bug fixes, shellcheck/CI cleanup, internal docs. No change to `action.yml` inputs/outputs or runtime behavior.
- **minor** (`v1.x.0` → `v1.x+1.0`): new inputs or outputs (additive), new supported platform, new optional feature. Existing usages keep working unchanged.
- **major** (`v1.x.y` → `v2.0.0`): rename/remove an input or output, change a default in a non-backward-compatible way, drop a platform, change the artifact naming contract. Floating `v1` is NOT moved past a major bump — consumers must opt in to `v2`.

### 2. Pre-flight

```bash
git status                         # working tree must be clean (or only contain the release-bound commit)
bash scripts/test-install.sh       # all unit tests pass
shellcheck -x scripts/*.sh         # clean
git pull --ff-only origin main     # up to date with remote
```

If there's a pending feature/fix, commit it on `main` first. CI on `main` must be green before tagging.

### 3. Tag + push

Replace `X.Y.Z` with the chosen version.

```bash
VERSION=vX.Y.Z

# Create the immutable release tag from current HEAD on main
git tag -a "$VERSION" -m "$VERSION"
git push origin "$VERSION"

# Move the floating major-version tag (skip this step on a major bump)
MAJOR="$(echo "$VERSION" | sed -E 's/^(v[0-9]+).*/\1/')"   # e.g. v1
git tag -f "$MAJOR" "$VERSION"
git push -f origin "$MAJOR"
```

Force-pushing the major-version tag is the standard GitHub Actions pattern; users that pin `@v1` are consenting to this.

### 4. GitHub Release

```bash
gh release create "$VERSION" \
  --title "$VERSION" \
  --notes "$(cat <<'EOF'
## Changes
- <bullet 1>
- <bullet 2>

## Compatibility
- Inputs/outputs: unchanged (or: list breaking changes)
- Supported platforms: linux/x86_64, linux/arm64, darwin/x86_64, darwin/arm64
EOF
)"
```

### 5. Marketplace (first release only, then on demand)

`gh release create` does NOT toggle Marketplace listing — that's a UI-only step:
1. Open the release on github.com.
2. Click "Edit".
3. Check **"Publish this Action to the GitHub Marketplace"**.
4. Pick the primary category (`Utilities` is appropriate) + optional secondary.
5. Save.

Subsequent releases automatically appear on the Marketplace listing once it's enabled; no UI step needed per release.

### 6. Post-release sanity check

```bash
gh release list
git ls-remote --tags origin | grep -E "refs/tags/(v[0-9]|$MAJOR)$"
```

Optionally trigger the integration workflow ([.github/workflows/integration.yml](.github/workflows/integration.yml)) once `tales-testing/tales` has releases:

```bash
gh workflow run integration.yml -f version=latest
```
