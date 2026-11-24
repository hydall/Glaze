#!/usr/bin/env bash
# Glaze version numbers: YY.M.N — two-digit year, month without a leading zero,
# and the number of the release within that month, starting at 1. A hotfix is
# simply the next release: 26.11.1, then 26.11.2. Always three numbers, because
# iOS accepts no more than that.
#
# The version is never edited by hand. Release tags (v26.11.1, ...) are the
# only record, so the repository's tags must be fetched before calling this.
#
#   calver.sh next     version the release being built now gets
#   calver.sh current  newest released version (what branch builds show);
#                      falls back to pubspec.yaml before the first such release
set -euo pipefail

# Released versions of this scheme, one per line, without the leading "v".
# Older 0.x tags do not match (their first number is one digit).
released() {
  git tag --list 'v*' | sed -n 's/^v\([0-9]\{2\}\.[0-9]\{1,2\}\.[0-9]\{1,\}\)$/\1/p'
}

case "${1:-}" in
  next)
    month="$(date -u +%y).$(date -u +%-m)"
    last=$(released | awk -F. -v m="$month" '$1"."$2 == m { print $3 }' | sort -n | tail -1)
    echo "$month.$(( ${last:-0} + 1 ))"
    ;;
  current)
    latest=$(released | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    if [ -n "$latest" ]; then
      echo "$latest"
    else
      grep '^version:' pubspec.yaml | awk '{print $2}' | sed 's/+.*//' | tr -d '\r'
    fi
    ;;
  *)
    echo "usage: $0 next|current" >&2
    exit 2
    ;;
esac
