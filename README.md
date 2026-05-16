# setup-tales-action

A GitHub Action that installs the [Tales](https://github.com/tales-testing/tales) integration / E2E testing CLI from GitHub Releases.

The action **only installs Tales** — it does not run any tests. After installation, `tales` is on `PATH` and any subsequent `run:` step can invoke it.

```yaml
- uses: tales-testing/setup-tales-action@v1
  with:
    version: latest
- run: tales --version
```

## Quick start

```yaml
name: Tales E2E
on:
  pull_request:
  push:
    branches: [main]
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tales-testing/setup-tales-action@v1
        with:
          version: latest
      - run: tales --version
```

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | no | `latest` | Tales version to install. Use `latest` or a tag like `v0.1.0`. |
| `github-token` | no | `${{ github.token }}` | Token used to query the GitHub Releases API and (when needed) download assets. Increase your rate limit and allow private-repo access by setting this. |
| `repo` | no | `tales-testing/tales` | Repository to download Tales from. Useful for testing forks or private repos. |
| `install-dir` | no | `${{ runner.temp }}/tales/bin` | Directory where the Tales binary will be installed. Created if missing. |
| `verify-checksum` | no | `"true"` | Verify the downloaded archive against `checksums.txt`. Set to `"false"` to skip. |

## Outputs

| Name | Description |
| --- | --- |
| `version` | The installed Tales tag (e.g. `v0.1.0`). |
| `path` | Absolute path to the installed `tales` binary. |

Example:

```yaml
- id: tales
  uses: tales-testing/setup-tales-action@v1
- run: |
    echo "Installed ${{ steps.tales.outputs.version }}"
    echo "Binary at ${{ steps.tales.outputs.path }}"
```

## Examples

### Pinned version

```yaml
- uses: tales-testing/setup-tales-action@v1
  with:
    version: v0.1.0
```

### Full E2E job with reports artifact

```yaml
name: Tales E2E
on:
  pull_request:
  push:
    branches: [main]
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tales-testing/setup-tales-action@v1
        with:
          version: latest
      - run: |
          tales test ./e2e \
            --seed 1234 \
            --report-junit build/reports/tales.junit.xml \
            --report-jsonl build/reports/tales.jsonl
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: tales-reports
          path: build/reports
```

### macOS / iOS

```yaml
jobs:
  ios:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tales-testing/setup-tales-action@v1
        with:
          version: v0.1.0
      - name: Build app
        run: |
          xcodebuild \
            -scheme MyApp \
            -sdk iphonesimulator \
            -destination 'platform=iOS Simulator,name=iPhone 17' \
            -derivedDataPath build/ios \
            build
      - name: Run Tales iOS
        env:
          IOS_DEVICE_NAME: iPhone 17
          IOS_APP_PATH: build/ios/...
          IOS_BUNDLE_ID: com.example.MyApp
        run: |
          tales test ./e2e/ios \
            --report-html build/reports/tales-ios.html \
            --capture-screenshots actions
```

## Supported platforms

| OS | Architecture |
| --- | --- |
| Ubuntu / Linux | `x86_64` |
| Ubuntu / Linux | `arm64` (self-hosted or GitHub-hosted arm64 runners) |
| macOS | `x86_64` |
| macOS | `arm64` (Apple Silicon) |

**Windows is not supported yet.**

## Checksum verification

By default the action downloads `checksums.txt` from the same release, finds the line matching the archive being installed, and verifies the SHA-256 hash. `sha256sum` is used on Linux and `shasum -a 256` on macOS — no extra dependencies required.

Disable it if you have a reason to:

```yaml
- uses: tales-testing/setup-tales-action@v1
  with:
    verify-checksum: "false"
```

## Private repo / custom token

If `repo` points at a private repository, pass a token that can read it:

```yaml
- uses: tales-testing/setup-tales-action@v1
  with:
    repo: my-org/tales-fork
    github-token: ${{ secrets.TALES_PAT }}
```

The token is only sent to `api.github.com` and `github.com`; it is never attached to requests to other hosts.

## Troubleshooting

- **"unsupported OS / architecture"** — the runner is neither Linux nor macOS, or its arch is not `x86_64`/`arm64`. Switch runners (Windows is not supported).
- **HTTP 404 on the archive URL** — the release does not contain an asset for your OS/arch combo. Check the release page on GitHub.
- **HTTP 403 from the GitHub API** — you are likely rate-limited. Pass `github-token: ${{ secrets.GITHUB_TOKEN }}` (it's the default, but custom workflows sometimes drop it).
- **"checksum mismatch"** — the downloaded archive does not match `checksums.txt`. Re-run the job; if it persists, file an issue on `tales-testing/tales` — the release artifacts may have been republished.
- **"no checksum entry for ..."** — `checksums.txt` doesn't include your archive. Same advice as above.

## Publishing notes (maintainers)

1. Tag a release: `git tag v1.0.0 && git push --tags`.
2. Create a GitHub Release for `v1.0.0` and publish it to the Marketplace via the GitHub UI.
3. Maintain a floating `v1` tag pointing at the latest `v1.x.y`:
   ```bash
   git tag -f v1 v1.0.0
   git push -f origin v1
   ```
   Force-pushing the major-version tag is the standard pattern for GitHub Actions.

## Development

- All install logic lives in [`scripts/install.sh`](scripts/install.sh).
- Unit tests live in [`scripts/test-install.sh`](scripts/test-install.sh) and source `install.sh` in library mode (`TALES_INSTALL_LIB_ONLY=1`).
- CI runs `shellcheck` and the unit tests on every push/PR — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
- The end-to-end self-test in [`.github/workflows/integration.yml`](.github/workflows/integration.yml) is `workflow_dispatch` only; enable it once Tales has published its first release.

Run tests locally:

```bash
bash scripts/test-install.sh
shellcheck -x scripts/*.sh
```

## License

[MIT](LICENSE)
