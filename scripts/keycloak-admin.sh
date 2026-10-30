#!/usr/bin/env bash
# Open the Keycloak admin console for this session through an SSM port forward to the
# identity platform on ECS (the console is never routed publicly). Ctrl+C closes it.
#
#   bash scripts/keycloak-admin.sh
#
# The browser will warn about the certificate: it is issued by the identity platform's
# private CA for keycloak.identity.internal and localhost, which browsers do not trust.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require aws terraform curl python session-manager-plugin
load_bootstrap_outputs
init_cluster_backend

open_keycloak_tunnel
trap close_keycloak_tunnel EXIT

cat <<EOF

  Admin console: https://localhost:18443/admin   (realm: banking)
  Credentials:   aws secretsmanager get-secret-value --region $REGION --secret-id techbleat/identity/admin --query SecretString --output text

  Press Ctrl+C to close the tunnel.
EOF

while true; do sleep 3600; done
