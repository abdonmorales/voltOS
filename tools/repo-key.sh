# shellcheck shell=bash
#
# Sourced by build-packages.sh and publish-repo.sh.
#
# repo_key_import: when VOLTOS_REPO_KEY_FILE names the package signing key
# (the VOLTOS_REPO_KEY secret, see tools/make-repo-key.sh), import it into a
# private GnuPG home and set REPO_KEY to its fingerprint.  Without it,
# REPO_KEY stays empty and nothing is signed.
REPO_KEY=
repo_key_import()
{
	[ -n "${VOLTOS_REPO_KEY_FILE:-}" ] || return 0
	[ -s "$VOLTOS_REPO_KEY_FILE" ] || {
		echo "repo-key: $VOLTOS_REPO_KEY_FILE is empty or missing" >&2
		return 1
	}
	GNUPGHOME=$(mktemp -d)
	export GNUPGHOME
	gpg --batch --quiet --import "$VOLTOS_REPO_KEY_FILE"
	REPO_KEY=$(gpg --batch --with-colons --list-secret-keys |
	    awk -F: '/^fpr/ {print $10; exit}')
	[ -n "$REPO_KEY" ] || { echo "repo-key: no secret key in $VOLTOS_REPO_KEY_FILE" >&2; return 1; }
	export GPGKEY=$REPO_KEY
	echo "==> Signing with key $REPO_KEY"
}

# repo_sign FILE...: detached binary signatures (FILE.sig), as pacman expects.
repo_sign()
{
	local f
	for f in "$@"; do
		gpg --batch --yes --detach-sign --no-armor --local-user "$REPO_KEY" \
		    --output "$f.sig" "$f"
	done
}

repo_key_cleanup()
{
	[ -n "${GNUPGHOME:-}" ] || return 0
	gpgconf --kill gpg-agent 2>/dev/null || :
	rm -rf "$GNUPGHOME"
}
