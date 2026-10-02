#!/bin/bash

# Cut a MacIDM release end to end (technical-spec §6.1).
#
# Usage:
#   scripts/release-app.sh <version> --notes <file> [--publish]
#
# Steps:
#   1. Verify the version is pinned in scripts/build-debug-app.sh (bump it
#      there first — the bump stays a deliberate, committed edit) and that
#      the main worktree is clean.
#   2. Build + package the app (scripts/package-update-release.sh: bundle,
#      EdDSA-signed zip, appcast), zip the Chrome extension, and write the
#      combined SHA256SUMS.txt.
#   3. Assemble the public snapshot in the dedicated public-snapshot
#      worktree: restore the main tree, drop the internal-only paths,
#      flip README.md to the English primary with README.zh-CN.md, and
#      commit "Prepare v<version> public snapshot".
#   4. With --publish: push the snapshot to origin (public-snapshot and
#      main) and create the GitHub Release with all assets. Without it,
#      print the exact commands so nothing leaves the machine uninvited.
#
# The EdDSA private key used by package-update-release.sh lives only in
# the release engineer's login Keychain; never copy it into the repository.

set -euo pipefail

usage() {
  echo "usage: $0 <version> --notes <file> [--publish]" >&2
  exit 2
}

version="${1:-}"
shift || true
notes_file=""
publish=false
while [ $# -gt 0 ]; do
  case "$1" in
    --notes)
      notes_file="${2:-}"
      shift 2
      ;;
    --publish)
      publish=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done
[ -n "$version" ] && [ -n "$notes_file" ] || usage
[ -f "$notes_file" ] || {
  echo "[release-app] notes file not found: $notes_file" >&2
  exit 1
}
case "$version" in
  v*) version_number="${version#v}" ;;
  *) version_number="$version" ;;
esac
case "$version_number" in
  *.*) ;;
  *) usage ;;
esac

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"
build_script="scripts/build-debug-app.sh"
snapshot_worktree="${MACIDM_SNAPSHOT_WORKTREE:-$(dirname "$repository_root")/MacIDM-public-snapshot}"
release_directory="$snapshot_worktree/.build/release"

# Internal-only content stripped from every public snapshot. Everything
# else on main ships; keep additions to this list deliberate.
exclusions=(
  .gitignore
  .trae
  .workbuddy
  AGENTS.md
  BrowserExtension/AGENTS.md
  README.en.md
  Sources/AGENTS.md
  Sources/IDMEngine/AGENTS.md
  Sources/MacIDMApp/AGENTS.md
  Sources/MacIDMBridge/AGENTS.md
  Sources/MacIDMHost/AGENTS.md
  Tests/AGENTS.md
  Tests/ReportTests
  Tests/Support/media-scope-fixture.html
  Tests/Support/table-selection-repro.swift
  docs/competitor-analysis.html
  docs/development
  docs/reports
  docs/specifications
  scripts/AGENTS.md
  scripts/diagnose-macidm.sh
  scripts/run-quiet-check.sh
  scripts/summarize-worktree.sh
)

# --- 1. Preconditions -------------------------------------------------------

grep -q "Add :CFBundleShortVersionString string $version_number" "$build_script" || {
  echo "[release-app] $build_script does not pin CFBundleShortVersionString to $version_number; bump it first and commit" >&2
  exit 1
}
[ -z "$(git status --porcelain)" ] || {
  echo "[release-app] main worktree is dirty; commit or stash first" >&2
  exit 1
}
[ -f "$snapshot_worktree/README.md" ] || {
  echo "[release-app] snapshot worktree missing at $snapshot_worktree (set MACIDM_SNAPSHOT_WORKTREE)" >&2
  exit 1
}
[ -z "$(git -C "$snapshot_worktree" status --porcelain --untracked-files=no)" ] || {
  echo "[release-app] snapshot worktree has tracked changes; clean it first" >&2
  exit 1
}
head_commit="$(git rev-parse HEAD)"

# --- 2. Public snapshot commit ---------------------------------------------

(
  cd "$snapshot_worktree"
  # Purge untracked leftovers (previous .build runs, stray files): the
  # public snapshot ships no .gitignore, so untracked build output would
  # otherwise be visible to and committed by the -A adds below. -ff handles
  # the nested Sparkle checkout git-repo; read-only object files need +w.
  chmod -R u+w .build 2>/dev/null || true
  git clean -ffdxq
  # Main's tree, including files main deleted since the previous snapshot.
  git restore --source="$head_commit" --staged --worktree :/
  RELEASE_HEAD_COMMIT="$head_commit" python3 - <<'PY'
import os
import pathlib
import subprocess

head = os.environ["RELEASE_HEAD_COMMIT"]
snap = set(subprocess.run(["git", "ls-tree", "-r", "--name-only", "public-snapshot"],
                          capture_output=True, text=True, check=True).stdout.split("\n"))
main = set(subprocess.run(["git", "ls-tree", "-r", "--name-only", head],
                          capture_output=True, text=True, check=True).stdout.split("\n"))
for f in sorted(f for f in (snap - main) if f):
    pathlib.Path(f).unlink(missing_ok=True)
PY
  git add -A
  git rm -r -q -f --ignore-unmatch "${exclusions[@]}"
  RELEASE_HEAD_COMMIT="$head_commit" python3 - <<'PY'
import os
import pathlib
import subprocess

head = os.environ["RELEASE_HEAD_COMMIT"]
en = subprocess.run(["git", "show", f"{head}:README.en.md"],
                    capture_output=True, text=True, check=True).stdout
zh = pathlib.Path("README.md").read_text()
pathlib.Path("README.md").write_text(en.replace('href="README.md"', 'href="README.zh-CN.md"'))
pathlib.Path("README.zh-CN.md").write_text(zh.replace('href="README.en.md"', 'href="README.md"'))
pathlib.Path("README.en.md").unlink(missing_ok=True)
PY
  git add -A
  # A re-run over an unchanged tree has nothing to commit; only proceed when
  # the snapshot worktree is clean (otherwise the re-run drifted).
  git commit -q -m "Prepare v${version_number} public snapshot" || [ -z "$(git status --porcelain)" ]
)
snapshot_sha="$(git -C "$snapshot_worktree" rev-parse HEAD)"

# --- 3. Package app + extension (inside the snapshot worktree, so the
# bundle's MacIDMBuildCommit names the public snapshot commit, not a
# private main-history sha) ----------------------------------------------

(
  cd "$snapshot_worktree"
  # The snapshot worktree carries its own .build; Sparkle's signing tools
  # must be resolved there once before packaging.
  swift package resolve >&2
  bash scripts/package-update-release.sh >&2
  ( cd BrowserExtension && ditto -c -k --sequesterRsrc --keepParent chrome \
      "$release_directory/MacIDM-v${version_number}-chrome-extension.zip" )
)
extension_zip="$release_directory/MacIDM-v${version_number}-chrome-extension.zip"
(
  cd "$release_directory"
  shasum -a 256 \
    "MacIDM-v${version_number}-macos-development.app.zip" \
    "MacIDM-v${version_number}-chrome-extension.zip" \
    appcast.xml > SHA256SUMS.txt
)

# --- 4. Publish -------------------------------------------------------------

if $publish; then
  git push origin public-snapshot
  git push origin "${snapshot_sha}:refs/heads/main"
  gh release create "v${version_number}" --repo Raters0/MacIDM --target public-snapshot \
    --title "MacIDM v${version_number}" --notes-file "$notes_file" \
    "$release_directory/MacIDM-v${version_number}-macos-development.app.zip" \
    "$extension_zip" \
    "$release_directory/appcast.xml" \
    "$release_directory/SHA256SUMS.txt"
else
  cat <<EOF
[release-app] dry run complete (snapshot commit $snapshot_sha). To publish:
  git push origin public-snapshot
  git push origin ${snapshot_sha}:refs/heads/main
  gh release create v${version_number} --repo Raters0/MacIDM --target public-snapshot \\
    --title "MacIDM v${version_number}" --notes-file "$notes_file" \\
    "$release_directory/MacIDM-v${version_number}-macos-development.app.zip" \\
    "$extension_zip" \\
    "$release_directory/appcast.xml" \\
    "$release_directory/SHA256SUMS.txt"
EOF
fi
echo "[release-app] done: snapshot commit $snapshot_sha"
