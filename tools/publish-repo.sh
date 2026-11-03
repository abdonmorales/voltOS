#!/bin/bash
#
# Publish a package repository made by build-packages.sh as the files of a
# GitHub release, which is where installed systems' pacman downloads VoltOS
# updates from:
#
#   [voltos]
#   Server = https://github.com/abdonmorales/voltOS/releases/download/repo-$arch
#
#   tools/publish-repo.sh all     DIR TAG    # every step below, in order
#   tools/publish-repo.sh list    DIR TAG    # needs gh (GH_TOKEN, GH_REPO)
#   tools/publish-repo.sh prepare DIR TAG    # needs repo-add, gpg, curl and
#                                            # VOLTOS_REPO_KEY_FILE
#   tools/publish-repo.sh upload  DIR TAG    # needs gh
#
# The steps are separate so that "prepare" can run where repo-add is (the
# Arch Linux ARM build root) and the others where gh is.
#
# A package file that is already published is never replaced: prepare
# downloads the published file and its signature in place of the fresh
# build of the same version, and the database is rebuilt over those.  So
# files keep their checksums, pacman caches stay valid, and nothing is ever
# out of step with the database.  New packages are uploaded first, the
# signed database last, and then packages the database no longer lists are
# deleted.
#
set -euo pipefail

[ "$#" -eq 3 ] || { echo "usage: $0 all|list|prepare|upload DIR TAG" >&2; exit 2; }
cmd=$1 dir=${2%/} tag=$3
top=$(cd "$(dirname "$0")/.." && pwd)
gh_repo=${GH_REPO:-abdonmorales/voltOS}
base=https://github.com/$gh_repo/releases/download/$tag
assets=$dir/.published-assets

die() { echo "publish-repo.sh: $*" >&2; exit 1; }

packages()
{
	local f
	for f in "$dir"/*.pkg.tar.zst; do
		[ -e "$f" ] && echo "${f##*/}"
	done
}

published() { grep -qxF "$1" "$assets"; }

do_list()
{
	if ! gh release view "$tag" --repo "$gh_repo" >/dev/null 2>&1; then
		echo "==> Creating release $tag"
		gh release create "$tag" --repo "$gh_repo" --prerelease --latest=false \
		    --title "VoltOS packages (${tag#repo-})" \
		    --notes "The VoltOS package repository for ${tag#repo-}, published by CI. pacman reads it through the [voltos] section of /etc/pacman.conf; the files here are not meant to be downloaded by hand."
	fi
	gh release view "$tag" --repo "$gh_repo" --json assets -q '.assets[].name' >"$assets"
	echo "==> $tag has $(wc -l <"$assets") files"
}

do_prepare()
{
	local n
	[ -f "$assets" ] || die "run 'list' first"
	# shellcheck source=tools/repo-key.sh
	. "$top/tools/repo-key.sh"
	repo_key_import
	trap repo_key_cleanup EXIT
	[ -n "$REPO_KEY" ] || die "prepare needs VOLTOS_REPO_KEY_FILE (the signing key)"

	for n in $(packages); do
		# GitHub renames assets with other characters, and pacman would
		# then not find them.
		[[ $n =~ ^[A-Za-z0-9._-]+$ ]] || die "$n: name GitHub would change"
		if published "$n" && published "$n.sig"; then
			echo "==> $n: already published, keeping that file"
			curl -fsSL --retry 3 -o "$dir/$n" "$base/$n"
			curl -fsSL --retry 3 -o "$dir/$n.sig" "$base/$n.sig"
		elif [ ! -f "$dir/$n.sig" ]; then
			repo_sign "$dir/$n"
		fi
	done

	rm -f "$dir"/voltos.db* "$dir"/voltos.files*
	repo-add -q -n --sign --key "$REPO_KEY" "$dir/voltos.db.tar.gz" "$dir"/*.pkg.tar.zst
	# pacman asks for voltos.db and voltos.files, which repo-add makes as
	# symbolic links; release files have to be real ones.
	for n in db files; do
		rm -f "$dir/voltos.$n" "$dir/voltos.$n.sig"
		cp "$dir/voltos.$n.tar.gz" "$dir/voltos.$n"
		cp "$dir/voltos.$n.tar.gz.sig" "$dir/voltos.$n.sig"
	done
	# The public key, for adding the repository to a system by hand.
	gpg --batch --armor --export "$REPO_KEY" >"$dir/voltos-repo.asc"
}

do_upload()
{
	local n new=() keep a
	[ -f "$assets" ] || die "run 'list' first"
	[ -f "$dir/voltos.db.sig" ] || die "run 'prepare' first"
	for n in $(packages); do
		published "$n" || new+=("$dir/$n" "$dir/$n.sig")
	done
	if [ "${#new[@]}" -gt 0 ]; then
		echo "==> Uploading $((${#new[@]} / 2)) new packages"
		gh release upload "$tag" --repo "$gh_repo" "${new[@]}"
	else
		echo "==> No new packages"
	fi
	gh release upload "$tag" --repo "$gh_repo" --clobber "$dir/voltos-repo.asc" \
	    "$dir/voltos.db" "$dir/voltos.db.sig" "$dir/voltos.files" "$dir/voltos.files.sig"

	keep=$(packages; packages | sed 's/$/.sig/'
	    printf '%s\n' voltos.db voltos.db.sig voltos.files voltos.files.sig voltos-repo.asc)
	while IFS= read -r a; do
		[ -n "$a" ] || continue
		grep -qxF "$a" <<<"$keep" && continue
		echo "==> Removing $a (no longer in the database)"
		gh release delete-asset "$tag" "$a" --repo "$gh_repo" --yes
	done <"$assets"
	echo "==> Published $(packages | wc -l) packages to $base"
}

case $cmd in
list) do_list ;;
prepare) do_prepare ;;
upload) do_upload ;;
all) do_list; do_prepare; do_upload ;;
*) die "unknown step $cmd" ;;
esac
