#!/usr/bin/env bash
# Unit tests for scripts/install.sh helpers.
#
# Sources install.sh with TALES_INSTALL_LIB_ONLY=1 so main() is not run.
# Pure helpers (OS/arch detection, version normalization, archive naming,
# tag parsing, checksum verification) are exercised directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install.sh
TALES_INSTALL_LIB_ONLY=1 source "${SCRIPT_DIR}/install.sh"

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    want: %q\n    got:  %q\n' "$name" "$want" "$got"
  fi
}

assert_fails() {
  local name="$1"; shift
  # Run in a subshell so fail()'s `exit 1` only kills the subshell.
  if ( "$@" ) >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf '  FAIL %s (expected non-zero exit)\n' "$name"
  else
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "$name"
  fi
}

# Run a function in a subshell with a stubbed `uname` so we can drive
# detect_os / detect_arch without touching the real host.
with_uname() {
  local s_out="$1" m_out="$2"
  shift 2
  (
    # shellcheck disable=SC2317,SC2329  # called indirectly via detect_os/detect_arch
    uname() {
      case "${1:-}" in
        -s) printf '%s' "$s_out" ;;
        -m) printf '%s' "$m_out" ;;
        *)  printf '%s' "$s_out" ;;
      esac
    }
    "$@"
  )
}

# ---- detect_os ----
printf '## detect_os\n'
assert_eq "$(with_uname Linux x86_64 detect_os)"  "linux"  "detect_os: Linux"
assert_eq "$(with_uname Darwin arm64 detect_os)"  "darwin" "detect_os: Darwin"
assert_fails "detect_os: rejects Windows_NT" with_uname Windows_NT x86_64 detect_os

# ---- detect_arch ----
printf '## detect_arch\n'
assert_eq "$(with_uname Linux x86_64  detect_arch)" "x86_64" "detect_arch: x86_64"
assert_eq "$(with_uname Linux amd64   detect_arch)" "x86_64" "detect_arch: amd64 -> x86_64"
assert_eq "$(with_uname Linux arm64   detect_arch)" "arm64"  "detect_arch: arm64"
assert_eq "$(with_uname Linux aarch64 detect_arch)" "arm64"  "detect_arch: aarch64 -> arm64"
assert_fails "detect_arch: rejects i386" with_uname Linux i386 detect_arch

# ---- normalize_version ----
printf '## normalize_version\n'
assert_eq "$(normalize_version v0.1.0)" "0.1.0" "normalize_version: strips leading v"
assert_eq "$(normalize_version 0.1.0)"  "0.1.0" "normalize_version: no-op when missing v"
assert_eq "$(normalize_version v1.2.3-rc.1)" "1.2.3-rc.1" "normalize_version: keeps pre-release suffix"

# ---- archive_name ----
printf '## archive_name\n'
assert_eq "$(archive_name 0.1.0 linux  x86_64)" "tales_0.1.0_linux_x86_64.tar.gz"  "archive_name: linux/x86_64"
assert_eq "$(archive_name 0.1.0 darwin arm64)"  "tales_0.1.0_darwin_arm64.tar.gz"  "archive_name: darwin/arm64"

# ---- parse_tag_name ----
printf '## parse_tag_name\n'
SAMPLE_JSON='{
  "url": "https://api.github.com/repos/tales-testing/tales/releases/123",
  "tag_name": "v1.2.3",
  "name": "v1.2.3"
}'
assert_eq "$(parse_tag_name "$SAMPLE_JSON")" "v1.2.3" "parse_tag_name: extracts tag"
SAMPLE_LIST='[
  {"tag_name": "v0.1.0-rc.1", "name": "v0.1.0-rc.1"},
  {"tag_name": "v0.1.0-rc.0", "name": "v0.1.0-rc.0"}
]'
assert_eq "$(parse_tag_name "$SAMPLE_LIST")" "v0.1.0-rc.1" "parse_tag_name: picks first tag from list (pre-release fallback)"
assert_fails "parse_tag_name: fails without tag_name" parse_tag_name '{"name":"nope"}'

# ---- verify_checksum ----
printf '## verify_checksum\n'
TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$TMP_DIR'" EXIT

ARCHIVE="fake.tar.gz"
ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE}"
printf 'hello tales\n' > "$ARCHIVE_PATH"
if command -v sha256sum >/dev/null 2>&1; then
  EXPECTED="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
else
  EXPECTED="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
fi

CHECKSUMS_OK="${TMP_DIR}/checksums.ok.txt"
printf '%s  %s\n' "$EXPECTED" "$ARCHIVE" > "$CHECKSUMS_OK"
if verify_checksum "$ARCHIVE_PATH" "$CHECKSUMS_OK" "$ARCHIVE" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); printf '  ok  verify_checksum: matching hash succeeds\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL verify_checksum: matching hash should succeed\n'
fi

CHECKSUMS_BAD="${TMP_DIR}/checksums.bad.txt"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$ARCHIVE" > "$CHECKSUMS_BAD"
assert_fails "verify_checksum: mismatched hash fails" \
  verify_checksum "$ARCHIVE_PATH" "$CHECKSUMS_BAD" "$ARCHIVE"

CHECKSUMS_EMPTY="${TMP_DIR}/checksums.empty.txt"
: > "$CHECKSUMS_EMPTY"
assert_fails "verify_checksum: missing entry fails" \
  verify_checksum "$ARCHIVE_PATH" "$CHECKSUMS_EMPTY" "$ARCHIVE"

# ---- summary ----
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
