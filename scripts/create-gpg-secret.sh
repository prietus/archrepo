#!/usr/bin/env bash
#
# Generates a passphrase-less Ed25519 signing key, creates the `archrepo-gpg`
# Secret in the cluster, and exports the PUBLIC key so clients can trust the repo.
#
# Usage:
#   NAME="Carlos Arch Repo" EMAIL="repo@carlos.dev" ./scripts/create-gpg-secret.sh
set -euo pipefail

NS="${NS:-archrepo}"
NAME="${NAME:-Arch Repo Builder}"
EMAIL="${EMAIL:-archrepo@example.com}"
OUT_PUB="${OUT_PUB:-archrepo-signing-key.pub}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GNUPGHOME="$WORK"
chmod 700 "$WORK"

cat > "$WORK/keyspec" <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: ecdh
Subkey-Curve: cv25519
Name-Real: ${NAME}
Name-Email: ${EMAIL}
Expire-Date: 0
%commit
EOF

echo "==> Generating signing key for ${NAME} <${EMAIL}>"
gpg --batch --gen-key "$WORK/keyspec"

KEYID="$(gpg --with-colons --list-secret-keys | awk -F: '/^sec:/{print $5; exit}')"
gpg --armor --export-secret-keys "$KEYID" > "$WORK/private.asc"
gpg --armor --export "$KEYID" > "$OUT_PUB"

echo "==> Ensuring namespace ${NS}"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating/updating Secret archrepo-gpg"
kubectl -n "$NS" create secret generic archrepo-gpg \
  --from-file=gpg-private-key="$WORK/private.asc" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF

Done.
  Key ID         : ${KEYID}
  Public key file: ${OUT_PUB}

Distribute ${OUT_PUB} to every client and trust it:
  sudo pacman-key --add ${OUT_PUB}
  sudo pacman-key --lsign-key ${KEYID}
EOF
