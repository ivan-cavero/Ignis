#!/bin/bash

set -e

echo "🔒 Setting file and folder permissions for Ignis..."

# Base path (adjust if run from another directory)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. Ensure acme.json exists and has correct permissions
ACME_FILE="$BASE_DIR/proxy/acme.json"
if [ ! -f "$ACME_FILE" ]; then
  echo "🧾 Creating acme.json..."
  touch "$ACME_FILE"
fi
echo "🔐 Setting permissions 600 on acme.json"
chmod 600 "$ACME_FILE"

# 2. Ensure proxy config files are read-only
echo "🔐 Ensuring traefik.yml and dynamic.yml are read-only"
chmod 644 "$BASE_DIR/proxy/traefik.yml"
chmod 644 "$BASE_DIR/proxy/dynamic/dynamic.yml"

# 3. Optional: secure script files
echo "🔐 Ensuring scripts are executable and not writable by others"
chmod -R 750 "$BASE_DIR/scripts"

# 4. Optional: secure deployments folder
echo "🔐 Locking down deployment configurations"
chmod -R 750 "$BASE_DIR/deployments"

# 5. Ownership (optional: uncomment to force root ownership)
# chown root:root "$ACME_FILE" "$BASE_DIR/proxy/traefik.yml"

echo "✅ Permissions have been set successfully."
