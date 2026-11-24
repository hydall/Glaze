#!/usr/bin/env bash
# Writes the version computed by the metadata job (.github/scripts/calver.sh)
# into pubspec.yaml for this build only. Everything downstream reads it from
# there: `flutter build` (Android versionName, iOS CFBundleShortVersionString,
# Windows file version), scripts/build_linux_packages.sh and
# windows/installer/build_setup.ps1. The change is never committed.
set -euo pipefail
version="${1:?usage: stamp_version.sh <version>}"
sed -i.bak "s/^version:.*/version: $version/" pubspec.yaml
rm -f pubspec.yaml.bak
grep '^version:' pubspec.yaml
