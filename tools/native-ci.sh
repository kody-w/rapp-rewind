#!/bin/bash
# Fixture-only verification. Never launch the GUI or call live capture/login actions.
set -euo pipefail

usage() {
  printf 'usage: %s [arm64|x86_64]\n' "$0"
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) usage >&2; exit 2 ;;
esac
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "$ARCH" ]; then
  printf 'Native CI requires a macOS process running the requested architecture: %s\n' "$ARCH" >&2
  exit 2
fi
for tool in swift xcodebuild xcodegen python3 lipo git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing CI build tool: %s\n' "$tool" >&2
    exit 2
  fi
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT/native"
SWIFT_BUILD=".build/ci-swift-$ARCH"
XCODE_BUILD=".build/ci-xcode-$ARCH"
PACKAGE_CACHE=".build/ci-package-cache"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_DIR=".build/ci-logs/$ARCH/$RUN_ID"
mkdir -p "$LOG_DIR" .build/ci-process-scratch

# SwiftPM's trusted generated bare caches otherwise fail on explicit-only Git hosts.
# These values affect this process tree only; no Git config file is written.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.bareRepository
export GIT_CONFIG_VALUE_0=all
export TMPDIR="$PWD/.build/ci-process-scratch/"
export REWIND_HOME="$PWD/$LOG_DIR/unused-history"

run_logged() {
  local name="$1"
  local filename="$2"
  shift 2
  printf 'Running %s\n' "$name"
  if "$@" > "$LOG_DIR/$filename" 2>&1; then
    printf 'PASS %s\n' "$name"
  else
    local status=$?
    printf 'FAIL %s (exit %s)\n' "$name" "$status" >&2
    tail -80 "$LOG_DIR/$filename" >&2
    return "$status"
  fi
}

run_logged "Swift fixture tests" swift-test.log \
  swift test --disable-swift-testing --arch "$ARCH" --scratch-path "$SWIFT_BUILD" --cache-path "$PACKAGE_CACHE" -j 2
run_logged "Swift release build" swift-release.log \
  swift build --arch "$ARCH" --scratch-path "$SWIFT_BUILD" --cache-path "$PACKAGE_CACHE" -c release -j 2
run_logged "XcodeGen app project" xcodegen.log \
  xcodegen generate --spec project.yml
run_logged "Xcode app build and core fixture tests" xcode-test.log \
  xcodebuild -project RAPPRewind.xcodeproj -scheme RAPPRewind \
    -configuration Release -destination "platform=macOS,arch=$ARCH" \
    -derivedDataPath "$XCODE_BUILD" \
    -clonedSourcePackagesDirPath "$XCODE_BUILD/SourcePackages" \
    -resultBundlePath "$LOG_DIR/xcode-tests.xcresult" \
    -jobs 2 -parallel-testing-enabled NO \
    ONLY_ACTIVE_ARCH=YES "ARCHS=$ARCH" CODE_SIGNING_ALLOWED=NO build test
run_logged "Compatibility CLI and native adapter fixtures" compatibility.log \
  "$ROOT/tools/dryrun.sh" --native-binary "$PWD/$SWIFT_BUILD/debug/RAPPRewind"

APP_EXEC="$XCODE_BUILD/Build/Products/Release/RAPPRewind.app/Contents/MacOS/RAPPRewind"
run_logged "App metadata and in-memory FTS5 self-check" app-self-test.json \
  "$PWD/$APP_EXEC" --self-test

python3 -B - "$ARCH" "$LOG_DIR" "$APP_EXEC" <<'PY'
from pathlib import Path
import json
import os
import subprocess
import sys

arch, log_directory, executable = sys.argv[1:]
logs = Path(log_directory)
expected_revision = "f0bc616c2aed34f2a88888806ed056ec7bafba61"
for filename in [
    "Package.resolved",
    "RAPPRewind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
]:
    pins = json.loads(Path(filename).read_text())["pins"]
    assert len(pins) == 1
    assert pins[0]["identity"] == "rapp-tools"
    assert pins[0]["location"] == "https://github.com/kody-w/rapp-tools.git"
    assert pins[0]["state"] == {"revision": expected_revision}

architectures = subprocess.check_output(["lipo", "-archs", executable], text=True).split()
assert architectures == [arch], architectures
self_check = json.loads((logs / "app-self-test.json").read_text())
assert self_check["product"] == "RAPPRewind"
assert self_check["bundleIdentifier"] == "io.rapp.rewind"
assert self_check["bundleMetadataVerified"] and self_check["resourcesPresent"] and self_check["fts5"]
assert self_check["captureStarted"] is False
assert self_check["permissionRequested"] is False
assert self_check["historyOpened"] is False
assert not Path(os.environ["REWIND_HOME"]).exists(), "a CI command unexpectedly opened history"

source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
expected_commit = os.environ.get("REWIND_CI_SOURCE_SHA")
if expected_commit:
    assert source_commit == expected_commit, "checkout does not match the workflow source SHA"
summary = {
    "source_commit": source_commit,
    "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
    "arch": arch,
    "support_revision": expected_revision,
    "app_self_check": self_check,
    "validation": "fixture tests and no-capture self-check only",
    "signing": "not performed; CODE_SIGNING_ALLOWED=NO",
    "release_evidence": False,
}
(logs / "ci-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print("PASS exact architecture, immutable pins, and no-history/no-permission app self-check")
print("Source commit:", summary["source_commit"])
PY

printf 'Native CI complete for %s. Logs: native/%s\n' "$ARCH" "$LOG_DIR"
