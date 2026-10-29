#!/usr/bin/env bash
# Pin every banking image in deploy/banking/workloads.yaml to the digest CI published for
# a commit. Commit and push the result; Argo CD rolls it out.
#
#   bash scripts/pin-images.sh <full-commit-sha>    # release that commit's images
#   bash scripts/pin-images.sh <older-commit-sha>   # roll back to a known-good release
#
# The commit must have passed CI on main (images are tagged sha-<commit>).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require curl python

commit=${1:-}
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "Usage: $0 <full 40-character commit SHA>"

OWNER=olawalelateef9
MANIFEST="$ROOT_DIR/deploy/banking/workloads.yaml"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

for service in frontend user-service transaction-service activity-service finance-agent; do
  repo="$OWNER/techbleat-$service"
  token=$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" |
    python -c "import json,sys; print(json.load(sys.stdin)['token'])")
  digest=$(curl -fsSI -H "Authorization: Bearer $token" -H "Accept: $ACCEPT" \
      "https://ghcr.io/v2/$repo/manifests/sha-$commit" |
    tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}') || true
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "No image ghcr.io/$repo:sha-$commit (did CI pass on main for this commit?)"

  python - "$MANIFEST" "$service" "$digest" "$commit" <<'EOF'
import re, sys
path, service, digest, commit = sys.argv[1:]
text = open(path, encoding="utf-8").read()
pattern = rf"(image: ghcr\.io/[^/]+/techbleat-{re.escape(service)})@sha256:[0-9a-f]{{64}} # source: [0-9a-f]{{40}}"
text, count = re.subn(pattern, rf"\1@{digest} # source: {commit}", text)
if count != 1:
    sys.exit(f"expected one image line for {service}, found {count}")
open(path, "w", encoding="utf-8", newline="").write(text)
EOF
  printf '  %-20s %s\n' "$service" "$digest"
done

log "Pinned deploy/banking/workloads.yaml to $commit. Review, commit and push to deploy."
