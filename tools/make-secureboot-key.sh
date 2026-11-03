#!/bin/bash
#
# Create the VoltOS Secure Boot signing key (run once, on your own machine).
#
#   tools/make-secureboot-key.sh [outdir]
#
# Produces in outdir (default ./secureboot-key):
#   voltos-sb.key   private key   -> GitHub secret VOLTOS_SB_KEY (keep offline)
#   voltos-sb.crt   certificate   -> GitHub secret VOLTOS_SB_CERT, and commit
#                                    it as keys/voltos-secureboot.crt
#   voltos-sb.cer   DER copy of the certificate (what MokManager enrolls)
#
# Then:
#   gh secret set VOLTOS_SB_KEY  --repo abdonmorales/voltOS < secureboot-key/voltos-sb.key
#   gh secret set VOLTOS_SB_CERT --repo abdonmorales/voltOS < secureboot-key/voltos-sb.crt
#
set -euo pipefail
out=${1:-secureboot-key}
mkdir -p "$out"
umask 077
openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=VoltOS Secure Boot Signing Key $(date +%Y)/O=VoltOS/" \
    -keyout "$out/voltos-sb.key" -out "$out/voltos-sb.crt"
openssl x509 -in "$out/voltos-sb.crt" -outform DER -out "$out/voltos-sb.cer"
chmod 644 "$out/voltos-sb.crt" "$out/voltos-sb.cer"
echo "Created $out/voltos-sb.{key,crt,cer}.  Store the .key somewhere safe;"
echo "anyone holding it can sign software your enrolled machines will boot."
