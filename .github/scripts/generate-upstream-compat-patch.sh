#!/usr/bin/env bash
set -euo pipefail

# Generate a portable kernel-only diff against the upstream SukiSU Ultra
# builtin baseline. Keep this separate from workflow patching so future
# upstream updates can be reviewed and rebased without losing compatibility.
upstream_ref=${UPSTREAM_REF:-6c284e957feaa9a388a9f1c37dc4ec80d95e434b}
output=${UPSTREAM_PATCH_OUTPUT:-artifacts/sukisu-ultra-builtin-non-gki-compat.patch}
mkdir -p "$(dirname "$output")"
git rev-parse --verify "$upstream_ref^{commit}" >/dev/null 2>&1 || {
  echo "[ERROR] upstream baseline is not present locally: $upstream_ref" >&2
  exit 1
}
UPSTREAM_MANAGER_REF=${UPSTREAM_MANAGER_REF:-upstream/main} \
  bash .github/scripts/check-manager-uapi-sync.sh
git diff --binary "$upstream_ref"..HEAD -- kernel > "$output"
[[ -s "$output" ]] || { echo '[ERROR] generated compatibility patch is empty' >&2; exit 1; }
echo "[+] Generated $output against SukiSU Ultra builtin $upstream_ref"
