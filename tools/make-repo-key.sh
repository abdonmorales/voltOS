#!/bin/bash
#
# Create the VoltOS package signing key (run once, on your own machine).
#
#   tools/make-repo-key.sh [outdir]
#
# Produces in outdir (default ./repo-key):
#   voltos-repo.key   private key (armored, no passphrase)
#                     -> GitHub secret VOLTOS_REPO_KEY (keep a copy offline)
#   voltos-repo.asc   public key, for reference; CI derives the
#                     voltos-keyring package from the secret
#
# Then:
#   gh secret set VOLTOS_REPO_KEY --repo abdonmorales/voltOS < repo-key/voltos-repo.key
#
# With the secret set, CI signs every package and the repository database,
# builds voltos-keyring, and publishes the repository for installed systems
# (tools/publish-repo.sh).  If the key is ever replaced, bump voltos-keyring's
# pkgver so installed systems pick up the new key.
#
set -euo pipefail
out=${1:-repo-key}
mkdir -p "$out"
umask 077
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'gpgconf --kill gpg-agent 2>/dev/null || :; rm -rf "$GNUPGHOME"' EXIT
uid="VoltOS Package Signing Key $(date +%Y)"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$uid" ed25519 sign never
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr/ {print $10; exit}')
gpg --batch --armor --pinentry-mode loopback --passphrase '' \
    --export-secret-keys "$fpr" >"$out/voltos-repo.key"
gpg --batch --armor --export "$fpr" >"$out/voltos-repo.asc"
chmod 644 "$out/voltos-repo.asc"
echo "Created $out/voltos-repo.key and $out/voltos-repo.asc"
echo "Fingerprint: $fpr"
echo "Store the .key somewhere safe: anyone holding it can publish packages"
echo "that every VoltOS system will install."
