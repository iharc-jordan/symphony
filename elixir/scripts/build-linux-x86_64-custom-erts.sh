#!/usr/bin/env bash
set -euo pipefail

# Build the Ubuntu noble/x86_64 release with the reviewed custom ERTS.
# The ERTS archive is intentionally supplied by the caller so its provenance
# and digest remain explicit at release time.
if [[ -z "${SYMPHONY_CUSTOM_ERTS:-}" ]]; then
  echo "SYMPHONY_CUSTOM_ERTS must point to the reviewed OTP 28.5 .tar.gz" >&2
  exit 2
fi
if [[ ! -f "$SYMPHONY_CUSTOM_ERTS" ]]; then
  echo "custom ERTS archive not found: $SYMPHONY_CUSTOM_ERTS" >&2
  exit 2
fi
if [[ -z "${SYMPHONY_CUSTOM_ERTS_SHA256:-}" ]]; then
  echo "SYMPHONY_CUSTOM_ERTS_SHA256 must contain the reviewed archive digest" >&2
  exit 2
fi
actual_sha256="$(sha256sum "$SYMPHONY_CUSTOM_ERTS" | awk '{print $1}')"
if [[ "$actual_sha256" != "$SYMPHONY_CUSTOM_ERTS_SHA256" ]]; then
  echo "custom ERTS digest mismatch: expected $SYMPHONY_CUSTOM_ERTS_SHA256, got $actual_sha256" >&2
  exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export BURRITO_TARGET=linux_x86_64
export MIX_ENV=prod

# Reusing a release directory preserves older application versions, which Burrito
# would embed alongside the current payload. Stage this build in an empty path.
release_path="$(mktemp -d "${TMPDIR:-/tmp}/symphony-release.XXXXXX")"
trap 'rm -rf -- "$release_path"' EXIT
mise exec zig@0.15.2 -- mix release symphony --path "$release_path"
