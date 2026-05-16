#!/usr/bin/env bash
# setup-tales-action: download and install the Tales CLI from GitHub Releases.
#
# When sourced with TALES_INSTALL_LIB_ONLY=1, only helper functions are
# defined; main() is not invoked. This is used by scripts/test-install.sh.
set -euo pipefail

log() {
  printf '[setup-tales] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

detect_os() {
  local raw
  raw="$(uname -s)"
  case "$raw" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    *) fail "unsupported OS: ${raw} (only Linux and macOS are supported)" ;;
  esac
}

detect_arch() {
  local raw
  raw="$(uname -m)"
  case "$raw" in
    x86_64|amd64) printf 'x86_64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *) fail "unsupported architecture: ${raw} (only x86_64 and arm64 are supported)" ;;
  esac
}

normalize_version() {
  local tag="$1"
  printf '%s' "${tag#v}"
}

archive_name() {
  local ver_no_v="$1" os="$2" arch="$3"
  printf 'tales_%s_%s_%s.tar.gz' "$ver_no_v" "$os" "$arch"
}

# Parse "tag_name" out of a GitHub Releases API JSON response without jq.
parse_tag_name() {
  local json="$1"
  local tag
  tag="$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  if [[ -z "$tag" ]]; then
    fail "could not parse tag_name from GitHub API response"
  fi
  printf '%s' "$tag"
}

# Build curl auth args. Only adds Authorization header when token is non-empty,
# which avoids the "empty Authorization" trap on public repos.
_auth_args() {
  if [[ -n "${INPUT_GITHUB_TOKEN:-}" ]]; then
    printf -- '-H\nAuthorization: Bearer %s\n' "$INPUT_GITHUB_TOKEN"
  fi
}

resolve_latest_version() {
  local repo="$1"
  local url="https://api.github.com/repos/${repo}/releases/latest"
  local json
  local -a curl_args=(
    -fsSL
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  if [[ -n "${INPUT_GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}")
  fi
  if ! json="$(curl "${curl_args[@]}" "$url")"; then
    fail "failed to query GitHub Releases API: ${url}"
  fi
  parse_tag_name "$json"
}

download() {
  local url="$1" dest="$2"
  local -a curl_args=(-fsSL)
  # Authenticated download is only useful (and safe) against github.com /
  # api.github.com hosts. Other hosts must not receive the token.
  if [[ -n "${INPUT_GITHUB_TOKEN:-}" ]] && [[ "$url" == https://github.com/* || "$url" == https://api.github.com/* ]]; then
    curl_args+=(-H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}")
  fi
  if ! curl "${curl_args[@]}" -o "$dest" "$url"; then
    fail "failed to download: ${url}"
  fi
}

# verify_checksum <archive_path> <checksums_file> <archive_basename>
verify_checksum() {
  local archive_path="$1" checksums_file="$2" archive="$3"
  local expected actual
  expected="$(grep "  ${archive}\$" "$checksums_file" | awk '{print $1}' | head -n1)"
  if [[ -z "$expected" ]]; then
    fail "no checksum entry for ${archive} in checksums.txt"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive_path" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  else
    fail "neither sha256sum nor shasum is available"
  fi
  if [[ "$actual" != "$expected" ]]; then
    fail "checksum mismatch for ${archive}: expected ${expected}, got ${actual}"
  fi
  log "checksum OK for ${archive}"
}

extract_archive() {
  local archive_path="$1" install_dir="$2"
  mkdir -p "$install_dir"
  tar -xzf "$archive_path" -C "$install_dir"
}

main() {
  local version="${INPUT_VERSION:-latest}"
  local repo="${INPUT_REPO:-tales-testing/tales}"
  local install_dir="${INPUT_INSTALL_DIR:-}"
  local verify="${INPUT_VERIFY_CHECKSUM:-true}"

  if [[ -z "$install_dir" ]]; then
    fail "install-dir is required"
  fi

  local os arch tag ver_no_v archive url checksums_url
  os="$(detect_os)"
  arch="$(detect_arch)"

  if [[ "$version" == "latest" ]]; then
    log "resolving latest release from ${repo}..."
    tag="$(resolve_latest_version "$repo")"
  else
    tag="$version"
  fi
  ver_no_v="$(normalize_version "$tag")"
  archive="$(archive_name "$ver_no_v" "$os" "$arch")"
  url="https://github.com/${repo}/releases/download/${tag}/${archive}"
  checksums_url="https://github.com/${repo}/releases/download/${tag}/checksums.txt"

  log "installing Tales ${tag} (${os}/${arch}) from ${repo}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" EXIT

  local archive_path="${tmp_dir}/${archive}"
  log "downloading ${url}"
  download "$url" "$archive_path"

  if [[ "$verify" == "true" ]]; then
    local checksums_path="${tmp_dir}/checksums.txt"
    log "downloading ${checksums_url}"
    download "$checksums_url" "$checksums_path"
    verify_checksum "$archive_path" "$checksums_path" "$archive"
  else
    log "skipping checksum verification (verify-checksum=false)"
  fi

  mkdir -p "$install_dir"
  extract_archive "$archive_path" "$install_dir"
  chmod +x "${install_dir}/tales"

  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'version=%s\n' "$tag"
      printf 'path=%s/tales\n' "$install_dir"
    } >> "$GITHUB_OUTPUT"
  fi

  log "installed: ${install_dir}/tales"
  "${install_dir}/tales" --version
}

if [[ "${TALES_INSTALL_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
