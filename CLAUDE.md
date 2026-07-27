# CLAUDE.md

Maintainer notes for the release pipeline and Homebrew distribution. User-facing install docs live in README.md.

## Releasing

1. Bump the version in **both** `Sources/Version.swift` (`NIBBLE_VERSION`) and `Resources/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`).
2. `git tag vX.Y.Z && git push --tags` — that's it. `.github/workflows/release.yml` builds a universal app (`make universal && make app`), uploads `Nibble-X.Y.Z.zip` to the GitHub Release, bumps the tap (formula url/sha256 + cask version/sha256), and syncs the formula copy back to `main`.
3. `Formula/` in this repo is a synced **copy** — the tap (`ben0128/homebrew-nibble`) is authoritative. Edit casks/formulas there.
4. The tap bump needs the `TAP_PUSH_TOKEN` Actions secret: a fine-grained PAT with Contents read/write on `homebrew-nibble` only (verified working 2026-07; mind the PAT expiry). Without it the release still ships, the tap bump is skipped, and the zip sha256 is printed in the job log for a manual bump.
5. The landing page (`ben0128/nibble-site` → nibble-45j.pages.dev) stamps its version/download-size numbers from the latest release at deploy time — after shipping, run `./deploy.sh` in that repo to refresh the site.

## Homebrew 6 quarantine constraints (why the cask looks like this)

- Homebrew 6 **removed** `--no-quarantine` — the CLI flag is gone and `HOMEBREW_CASK_OPTS` quarantine parsing is dead code; installs always quarantine the download.
- A quarantined ad-hoc-signed app is hard-blocked by Gatekeeper ("damaged"), so the cask strips quarantine itself in `postflight` via `xattr -dr`.
- Timing matters: once Gatekeeper evaluates the app (stamping `com.apple.provenance`), the quarantine xattr becomes EPERM-protected and can no longer be removed. Postflight runs at install time, inside that window.
- Cask `conflicts_with` accepts only `cask:` in Homebrew 6 — `formula:` fails at load time and `brew style` does not catch it.

## Signing status

The app is ad-hoc signed (no Developer ID, no notarization). Consequences: every upgrade changes the CDHash, so Input Monitoring / Accessibility grants are invalidated and must be re-approved. The fix is an Apple Developer ID + notarization, which would also make the postflight quarantine strip unnecessary.

## Install matrix

- Cask (recommended): app + CLI — the `binary` stanza links the executable inside the bundle.
- Formula: CLI only, built from source.
- Installing both clashes on the `/opt/homebrew/bin/nibble` link.
