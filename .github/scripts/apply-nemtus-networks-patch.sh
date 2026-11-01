#!/usr/bin/env bash
#
# apply-nemtus-networks-patch.sh
#
# Idempotently turns an exact mirror of an upstream `symbol/networks` network branch
# (mainnet / sai) into the nemtus republish layer:
#   - shoestring.ini [images] client/rest -> ghcr.io/nemtus images at the versions
#     pinned in .github/network-config/versions.env (mongo is kept as-is: third-party).
#     [services] nodewatch is intentionally LEFT as upstream for now.
#   - a "mirror" notice is prepended to README.md (provenance; upstream ships no LICENSE,
#     so we assert none either — we only document provenance).
#   - socket.yml (Socket supply-chain config) is (re)written at the repo root.
#   - upstream-provided GitHub automation is stripped (we keep only the nemtus workflows).
#   - Dependabot is (re)written as a nemtus github-actions-only config (.github/dependabot.yml)
#     so the SHA-pinned actions stay current behind a reviewed PR.
#
# Running it repeatedly produces the same result (mirror-ci enforces no drift). The
# mirror-sync workflow runs it after every upstream merge, on each mapped branch:
#   upstream symbol/networks:mainnet -> nemtus/symbol-networks:main
#   upstream symbol/networks:sai     -> nemtus/symbol-networks:test-sai
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
shoestring_ini="${repo_root}/shoestring.ini"
readme="${repo_root}/README.md"
versions_env="${repo_root}/.github/network-config/versions.env"

# nemtus-owned GitHub workflows that must survive the strip below.
nemtus_workflows=('mirror-sync.yml' 'mirror-ci.yml')

# --- image version injection -----------------------------------------------------
# shellcheck disable=SC1090
. "${versions_env}"
: "${CATAPULT_IMAGE_VERSION:?versions.env must set CATAPULT_IMAGE_VERSION}"
: "${REST_IMAGE_VERSION:?versions.env must set REST_IMAGE_VERSION}"

catapult_image="ghcr.io/nemtus/catapult-server:${CATAPULT_IMAGE_VERSION}"
rest_image="ghcr.io/nemtus/symbol-rest:${REST_IMAGE_VERSION}"

echo "==> patching ${shoestring_ini} [images]"
# Anchored replacements that match the KNOWN image names only — either the upstream
# symbolplatform value (fresh mirror of an upstream branch) or our own ghcr.io/nemtus
# value (already-patched branch, i.e. every committed shoestring.ini here). Both
# alternatives must be accepted so that bumping a version in versions.env alone is
# enough to repoint an already-patched branch; anchoring on upstream only would make
# such a bump a silent no-op and trip the grep verification below.
#
# Still anchored (not a blanket `^client = .*`): an unrecognised image name is left
# untouched and then fails the verification, so upstream format drift cannot ship
# silently. The tag part is intentionally open (`:.*`) — that is what we converge.
# Idempotent: a second run rewrites the same line to the same value (no diff ->
# mirror-ci no-drift stays green). `client`/`rest` keys appear only under [images].
#
# `#` is the s/// delimiter here because the alternation needs a literal `|`.
sed -i -E "s#^client = (symbolplatform/symbol-server|ghcr\.io/nemtus/catapult-server):.*\$#client = ${catapult_image}#" "${shoestring_ini}"
sed -i -E "s#^rest = (symbolplatform/symbol-rest|ghcr\.io/nemtus/symbol-rest):.*\$#rest = ${rest_image}#" "${shoestring_ini}"

# Fail loudly if the upstream format ever drifts so a silent non-rewrite can't ship.
if ! grep -qxF "client = ${catapult_image}" "${shoestring_ini}"; then
	echo "::error::shoestring.ini [images] client was not set to ${catapult_image} (upstream format drift?)" >&2
	exit 1
fi
if ! grep -qxF "rest = ${rest_image}" "${shoestring_ini}"; then
	echo "::error::shoestring.ini [images] rest was not set to ${rest_image} (upstream format drift?)" >&2
	exit 1
fi

# --- README mirror notice (provenance) -------------------------------------------
echo "==> ensuring mirror notice in ${readme}"
notice_marker='<!-- nemtus-mirror-notice -->'
if [ -f "${readme}" ] && ! grep -qF "${notice_marker}" "${readme}"; then
	tmp="$(mktemp)"
	cat > "${tmp}" <<'EOF'
<!-- nemtus-mirror-notice -->
> **Note (nemtus mirror):** This branch is a content mirror of a network branch of
> [`symbol/networks`](https://github.com/symbol/networks). The only change from
> upstream is `shoestring.ini`'s `[images]` `client`/`rest`, repointed to the NEMTUS
> images on `ghcr.io/nemtus` (the catapult server and REST mirrors); all other
> configuration, the nemesis `seed/`, and `resources/` are unmodified. nemtus asserts
> no copyright over this content. For the canonical project, see
> [symbol/networks](https://github.com/symbol/networks).
>
> Branch mapping: `symbol/networks:mainnet` -> `nemtus/symbol-networks:main`,
> `symbol/networks:sai` -> `nemtus/symbol-networks:test-sai`.
<!-- /nemtus-mirror-notice -->

EOF
	cat "${readme}" >> "${tmp}"
	mv "${tmp}" "${readme}"
	echo "    notice inserted"
else
	echo "    notice already present or no README"
fi

# --- Socket supply-chain config --------------------------------------------------
# Owned by this layer and rewritten verbatim each run (survives sync; mirror-ci no-drift).
# This repo currently ships no dependency manifests, so triggerPaths rarely fire; the
# config is kept for posture parity and to cover any manifest a future sync introduces.
socket_yml="${repo_root}/socket.yml"
echo "==> writing ${socket_yml}"
cat > "${socket_yml}" <<'EOF'
# socket.yml — Socket (https://socket.dev) configuration for the nemtus/symbol-networks mirror.
#
# Managed by the nemtus republish layer: .github/scripts/apply-nemtus-networks-patch.sh
# rewrites this file verbatim on every upstream sync, so edit it THERE, not here —
# otherwise the next mirror-sync reverts your change and mirror-ci.yml's no-drift check fails.
version: 2

triggerPaths:
  - '**/package.json'
  - '**/package-lock.json'
  - '**/pyproject.toml'
  - '**/*requirements*.txt'
  - '**/Cargo.toml'
  - '**/Cargo.lock'

issueRules:
  malware: true
  installScripts: true
  didYouMean: true     # typosquats
  gitDependency: true
  telemetry: false

githubApp:
  enabled: true
  pullRequestAlertsEnabled: true
  ignoreUsers: []
EOF

# --- strip upstream GitHub automation (keep only nemtus workflows) ----------------
echo "==> stripping upstream GitHub automation (keeping only nemtus workflows)"
workflows_dir="${repo_root}/.github/workflows"
if [ -d "${workflows_dir}" ]; then
	keep_args=()
	for wf in "${nemtus_workflows[@]}"; do
		keep_args+=(! -name "${wf}")
	done
	find "${workflows_dir}" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
		"${keep_args[@]}" -print -delete
fi

# --- Dependabot (github-actions only) --------------------------------------------
rm -f "${repo_root}/.github/dependabot.yaml"
dependabot_yml="${repo_root}/.github/dependabot.yml"
echo "==> writing ${dependabot_yml}"
cat > "${dependabot_yml}" <<'EOF'
# Dependabot — nemtus mirror layer. Owned by .github/scripts/apply-nemtus-networks-patch.sh,
# which rewrites this file verbatim on every upstream sync (mirror-ci.yml enforces no drift).
# Edit it THERE, not here.
#
# Scoped to github-actions ONLY: keeps our SHA-pinned actions current behind a reviewed PR.
# This is a content mirror of network configuration data, so there are no package deps to update.
# Dependabot reads this config from the default branch (main) only, so test-sai needs its own
# target-branch entry to keep that branch's workflow action pins current too.
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    target-branch: main
    schedule:
      interval: weekly
      day: sunday
    labels: [dependencies]
    commit-message:
      prefix: '[dependency]'
    cooldown:
      semver-major-days: 14
      semver-minor-days: 7
      semver-patch-days: 3
    groups:
      github-actions:
        patterns:
          - '*'
  - package-ecosystem: github-actions
    directory: /
    target-branch: test-sai
    schedule:
      interval: weekly
      day: sunday
    labels: [dependencies]
    commit-message:
      prefix: '[dependency]'
    cooldown:
      semver-major-days: 14
      semver-minor-days: 7
      semver-patch-days: 3
    groups:
      github-actions:
        patterns:
          - '*'
EOF

echo "==> done"
