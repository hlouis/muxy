#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REF="HEAD"
while [[ $# -gt 0 ]]; do
  case $1 in
    --ref)
      REF="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

REPO="${REPO:-muxy-app/muxy}"
STABLE_APPCAST_URL="${STABLE_APPCAST_URL:-https://github.com/${REPO}/releases/latest/download/appcast-arm64.xml}"
BETA_APPCAST_URL="${BETA_APPCAST_URL:-https://github.com/${REPO}/releases/download/beta-channel/appcast-beta-arm64.xml}"

max_sparkle_version_in_url() {
  local url="$1"
  local body
  body=$(curl -fsSL "$url" 2>/dev/null || true)
  if [[ -z "$body" ]]; then
    echo 0
    return
  fi
  local versions
  versions=$(printf '%s' "$body" | grep -oE '<sparkle:version>[0-9]+</sparkle:version>' | grep -oE '[0-9]+' || true)
  if [[ -z "$versions" ]]; then
    echo 0
    return
  fi
  printf '%s\n' "$versions" | sort -n | tail -1
}

REV_COUNT=$(git -C "$PROJECT_ROOT" rev-list --count "$REF")
STABLE_MAX=$(max_sparkle_version_in_url "$STABLE_APPCAST_URL")
BETA_MAX=$(max_sparkle_version_in_url "$BETA_APPCAST_URL")

NEXT=$REV_COUNT
[[ $STABLE_MAX -ge $NEXT ]] && NEXT=$((STABLE_MAX + 1))
[[ $BETA_MAX -ge $NEXT ]] && NEXT=$((BETA_MAX + 1))

echo "$NEXT"
