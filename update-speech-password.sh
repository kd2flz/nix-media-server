#!/usr/bin/env bash
# Update speech-to-text basic auth password in sops without using an agent
set -euo pipefail

# Check if we're in the right environment
if [ -z "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" ]; then
  echo "Error: Not in nix develop shell or SOPS env not set"
  echo "Run: nix develop"
  exit 1
fi

# Get password
read -rsp "Enter new password for speech-to-text basic auth: " PASSWORD
echo
read -rsp "Confirm password: " PASSWORD_CONFIRM
echo

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
  echo "Error: Passwords don't match"
  exit 1
fi

# Generate bcrypt hash
# Try different tools in order of preference
if command -v htpasswd >/dev/null 2>&1; then
  HASH=$(htpasswd -nbB dummy "$PASSWORD" | cut -d: -f2)
elif command -v caddy >/dev/null 2>&1; then
  HASH=$(caddy hash-password --plaintext "$PASSWORD")
elif command -v python3 >/dev/null 2>&1 && python3 -c "import bcrypt" 2>/dev/null; then
  HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$PASSWORD', bcrypt.gensalt(rounds=10)).decode())")
elif command -v mkpasswd >/dev/null 2>&1; then
  HASH=$(mkpasswd -m bcrypt "$PASSWORD")
else
  echo "Error: No tool found to generate bcrypt hash"
  echo "Install one of: apache-tools (htpasswd), caddy, python3 with bcrypt, or whois (mkpasswd)"
  exit 1
fi

echo "Generated hash: $HASH"
echo ""

# Update sops secret
echo "Updating secrets/secrets.yaml..."
sops set secrets/secrets.yaml '["speech_basic_auth_hash"]' "\"$HASH\""

echo "Done! The secret has been updated."
echo ""
echo "Next steps:"
echo "1. Commit and push the changes to secrets/secrets.yaml"
echo "2. Deploy to apply - the host is configured with restartUnits so services will restart automatically"
echo "3. Or run: sudo nixos-rebuild switch --flake .#<hostname> on the host"
