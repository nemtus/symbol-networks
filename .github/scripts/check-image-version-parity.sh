#!/usr/bin/env bash
#
# check-image-version-parity.sh
#
# Guards against shipping upstream network configuration with NEMTUS images built for an
# OLDER upstream release. apply-nemtus-networks-patch.sh rewrites shoestring.ini [images]
# client/rest to whatever versions.env pins, so when upstream bumps its images together with
# config that needs the new binaries (e.g. a new fork height in config-network.properties,
# or a changed rest.json schema), the sync PR silently keeps the old images. This script
# makes that mismatch a CI failure instead.
#
# Checks, for the upstream commit contained in HEAD:
#   (1) versions.env CATAPULT_IMAGE_VERSION is v<X>-<YYYYMMDD> where upstream pins
#       symbolplatform/symbol-server:gcc-<X>;
#   (2) versions.env REST_IMAGE_VERSION is v<Y>-<YYYYMMDD> where upstream pins
#       symbolplatform/symbol-rest:<Y>;
#   (3) shoestring.ini [images] mongo equals upstream's mongo (third-party, kept as-is);
#   (4) the pinned ghcr.io/nemtus tags actually exist (anonymous registry query), unless
#       SKIP_REGISTRY_CHECK=1.
#
# Usage:
#   check-image-version-parity.sh <upstream-ref>
#     <upstream-ref>  a fetched ref of the mapped upstream branch, e.g. upstream/mainnet.
#                     The check uses the newest commit of that branch that is an ancestor of
#                     HEAD (the upstream commit this tree was synced from), so a newer upstream
#                     commit that has not been synced yet does not fail the check.
set -euo pipefail

upstream_ref="${1:?usage: check-image-version-parity.sh <upstream-ref>}"
repo_root="$(git rev-parse --show-toplevel)"
versions_env="${repo_root}/.github/network-config/versions.env"
shoestring_ini="${repo_root}/shoestring.ini"

# shellcheck disable=SC1090
. "${versions_env}"
: "${CATAPULT_IMAGE_VERSION:?versions.env must set CATAPULT_IMAGE_VERSION}"
: "${REST_IMAGE_VERSION:?versions.env must set REST_IMAGE_VERSION}"

synced_upstream="$(git merge-base HEAD "${upstream_ref}")"
echo "==> upstream commit contained in HEAD: $(git rev-parse --short "${synced_upstream}") (${upstream_ref})"

# Value of `<key> = ...` from a shoestring.ini on stdin ([images] is the only section with
# client/rest/mongo keys).
ini_value() {
	sed -n -E "s/^${1} = (.*)\$/\\1/p" | head -n 1
}

upstream_ini="$(git show "${synced_upstream}:shoestring.ini")"
upstream_client="$(ini_value client <<<"${upstream_ini}")"
upstream_rest="$(ini_value rest <<<"${upstream_ini}")"
upstream_mongo="$(ini_value mongo <<<"${upstream_ini}")"
echo "    upstream [images]: client=${upstream_client} rest=${upstream_rest} mongo=${upstream_mongo}"

status=0
fail() {
	echo "::error::$*" >&2
	status=1
}

case "${upstream_client}" in
symbolplatform/symbol-server:gcc-*)
	expected="v${upstream_client#symbolplatform/symbol-server:gcc-}"
	[[ "${CATAPULT_IMAGE_VERSION}" =~ ^${expected//./\\.}-[0-9]{8}$ ]] ||
		fail "CATAPULT_IMAGE_VERSION=${CATAPULT_IMAGE_VERSION} does not match upstream ${upstream_client}; publish ghcr.io/nemtus/catapult-server:${expected}-<YYYYMMDD> and bump versions.env"
	;;
*) fail "unrecognised upstream [images] client '${upstream_client}' (upstream format drift?)" ;;
esac

case "${upstream_rest}" in
symbolplatform/symbol-rest:*)
	expected="v${upstream_rest#symbolplatform/symbol-rest:}"
	[[ "${REST_IMAGE_VERSION}" =~ ^${expected//./\\.}-[0-9]{8}$ ]] ||
		fail "REST_IMAGE_VERSION=${REST_IMAGE_VERSION} does not match upstream ${upstream_rest}; publish ghcr.io/nemtus/symbol-rest:${expected}-<YYYYMMDD> and bump versions.env"
	;;
*) fail "unrecognised upstream [images] rest '${upstream_rest}' (upstream format drift?)" ;;
esac

local_mongo="$(ini_value mongo <"${shoestring_ini}")"
[ "${local_mongo}" = "${upstream_mongo}" ] ||
	fail "shoestring.ini [images] mongo=${local_mongo} differs from upstream ${upstream_mongo}"

# (4) Pinned tags must exist on ghcr.io — a missing tag makes `docker compose pull` fail on nodes.
if [ "${SKIP_REGISTRY_CHECK:-0}" != 1 ]; then
	for image in "catapult-server:${CATAPULT_IMAGE_VERSION}" "symbol-rest:${REST_IMAGE_VERSION}"; do
		repo="nemtus/${image%%:*}"
		tag="${image#*:}"
		token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" |
			sed -n -E 's/.*"token":"([^"]+)".*/\1/p')"
		code="$(curl -sS -o /dev/null -w '%{http_code}' -I \
			-H "Authorization: Bearer ${token}" \
			-H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
			"https://ghcr.io/v2/${repo}/manifests/${tag}")"
		if [ "${code}" = 200 ]; then
			echo "    ghcr.io/${repo}:${tag} exists"
		else
			fail "ghcr.io/${repo}:${tag} not found (HTTP ${code}); publish it before pinning it in versions.env"
		fi
	done
fi

[ "${status}" = 0 ] && echo "==> image versions match upstream"
exit "${status}"
