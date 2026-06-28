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
client = ghcr.io/nemtus/catapult-server:v1.0.3.9
rest   = ghcr.io/nemtus/symbol-rest:v2.5.1
mongo  = mongo:7.0.23
```

- `mongo` is third-party and left as upstream.
- These versions are pinned in `.github/network-config/versions.env` and injected by
  `.github/scripts/apply-nemtus-networks-patch.sh` on every sync.
- `[services] nodewatch` is **currently left as upstream** (`nodewatch.symbol.tools`).
  Pointing it at a NEMTUS host is a follow-up for strict full-independence.

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
