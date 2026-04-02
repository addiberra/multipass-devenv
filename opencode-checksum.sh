#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
BINARY="opencode-linux-amd64"
URL="https://github.com/anomalyco/opencode/releases/download/v${VERSION}/${BINARY}"

TMPFILE=$(mktemp)
trap 'rm -f "${TMPFILE}"' EXIT

curl -fSL --retry 3 -o "${TMPFILE}" "${URL}"
HASH=$(sha256sum "${TMPFILE}" 2>/dev/null || shasum -a 256 "${TMPFILE}")
HASH=$(echo "${HASH}" | awk '{print $1}')
SIZE=$(stat --format=%s "${TMPFILE}" 2>/dev/null || stat -f%z "${TMPFILE}" 2>/dev/null)

echo "Version:  ${VERSION}"
echo "File:     ${BINARY}"
echo "Size:     ${SIZE} bytes"
echo "SHA-256:  ${HASH}"
