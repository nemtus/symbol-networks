<!-- nemtus-mirror-notice -->
# Interface contract: nemtus/symbol-networks → shoestring (PackageResolver)

This document is the **interface contract** produced by `nemtus/symbol-networks` and
consumed by the NEMTUS shoestring mirror (`nemtus/symbol-product`,
`tools/shoestring/shoestring/internal/PackageResolver.py`, work item **A-3**).

It lets shoestring fetch network configuration packages **without touching upstream**
(`symbol/symbol`, `symbol/networks`, `symbol.tools`) at runtime.

## Distribution model

Network configuration is served as **branch archives** of this repository (same model
upstream uses for testnet). Each branch is a self-contained config package: nemesis
`seed/`, `resources/`, `mongo/`, `rest/`, and `shoestring.ini`.

| network | branch | archive URL (no auth required) |
|---|---|---|
| mainnet | `main` (default) | `https://github.com/nemtus/symbol-networks/archive/refs/heads/main.zip` |
| testnet (sai) | `test-sai` | `https://github.com/nemtus/symbol-networks/archive/refs/heads/test-sai.zip` |

Branch mapping from upstream `symbol/networks`: `mainnet → main`, `sai → test-sai`.

### Archive layout

A GitHub branch archive extracts into a **single top-level directory** (e.g.
`symbol-networks-main/`) containing `seed/`, `resources/`, `shoestring.ini`, … This is
compatible with `PackageResolver._move_to_parent` (which accepts either `seed/` at the
root or under a single subdirectory). Do not double-nest.

## `shoestring.ini [images]` (the values that actually get used)

Each branch's `shoestring.ini [images]` is repointed to the NEMTUS images:

```
[images]
client = ghcr.io/nemtus/catapult-server:v1.0.3.9-20261101
rest   = ghcr.io/nemtus/symbol-rest:v2.5.1-20261101
mongo  = mongo:7.0.23
```

(Example values; the authoritative pins are in `.github/network-config/versions.env`.)

- `mongo` is third-party and left as upstream.
- These versions are pinned in `.github/network-config/versions.env` and injected by
  `.github/scripts/apply-nemtus-networks-patch.sh` on every sync.
- The `-<YYYYMMDD>` suffix identifies one **immutable** nemtus build of that upstream
  version. The unsuffixed `v<X>` tags also exist and point at the same digest, but they
  are mutable and must not be pinned here — see below.
- The pinned versions must be built from the **same upstream release** that the synced
  upstream `shoestring.ini` pins (`symbolplatform/symbol-server:gcc-<X>` ->
  `v<X>-<YYYYMMDD>`, `symbolplatform/symbol-rest:<Y>` -> `v<Y>-<YYYYMMDD>`), because
  upstream ships config that needs the new binaries (fork heights, `rest.json` schema) in
  the same commit as the image bump. `mirror-ci.yml`'s `image-version-parity` job
  (`.github/scripts/check-image-version-parity.sh`) fails a sync PR until the matching
  NEMTUS images are published and `versions.env` is bumped on that sync branch.
- `[services] nodewatch` is **currently left as upstream** (`nodewatch.symbol.tools`).
  Pointing it at a NEMTUS host is a follow-up for strict full-independence.

### Why date-suffixed tags, and what operators have to do

NEMTUS rebuilds these images at an **unchanged** upstream version to pick up base-image
security patches. That moves the mutable `v<X>` tag to a new digest, which is invisible to
nodes that already run it: shoestring generates a `docker-compose.yaml` without
`pull_policy`, and Compose defaults to `missing`, so a cached tag is never re-pulled — not
by `docker compose up -d`, not after `shoestring upgrade`. A moved mutable tag therefore
reaches new setups only. Bumping the pinned reference string here is what makes a rebuild
reach existing nodes, because shoestring re-downloads this repo's branch archive on every
setup/upgrade and reads `[images]` from the `shoestring.ini` inside it.

**Operational rule: whenever an image is rebuilt — including a same-version security
rebuild — publish a new date-suffixed tag and bump `versions.env`, otherwise existing
nodes keep running the old build indefinitely.**

For node operators, once the pins above change:

```sh
# Preferred: re-run upgrade. It re-downloads this branch archive and regenerates
# docker-compose.yaml with the new image references, which Compose then pulls.
python3 -m shoestring upgrade --config <node-dir>/shoestring.ini --directory <node-dir>
cd <node-dir> && docker compose up -d
```

```sh
# Immediate workaround, no compose regeneration — and the only way to adopt a rebuild
# that was published under an unchanged tag.
cd <node-dir> && docker compose pull && docker compose up -d
```

## Integrity

Branch archives are **not** byte-reproducible, so there is **no SHA512 pin** (this
matches how upstream serves testnet today). Accordingly, A-3 should drop the mainnet
`OFFICIAL_HASHES` pin and the `client/catapult*` Release-API/`_find_asset` path, and
resolve **both** mainnet and testnet via the branch-archive URLs above.

## Required A-3 changes (in nemtus/symbol-product)

In `PackageResolver.py`:
- `mainnet` → `https://github.com/nemtus/symbol-networks/archive/refs/heads/main.zip`
- `sai` / testnet → `https://github.com/nemtus/symbol-networks/archive/refs/heads/test-sai.zip`
- remove `SYMBOL_GITHUB_URI`, `_get_releases`, `_find_asset`, `OFFICIAL_HASHES`
  (no longer needed once mainnet is a branch archive).
<!-- /nemtus-mirror-notice -->
