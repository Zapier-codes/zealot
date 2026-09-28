# Tenant signing keys: lifecycle, rotation and pinning (Task 37b-ii-k1)

Design doc for `TenantSigningKey`, the per-tenant key the operator chose for the
multi-tenant Console (Task 37, D-store `6.b.i.zi`). **Spec only: nothing in this
file is built yet.** Slices k2 onward implement it; the slice cards are in
`handover.md` under "Task 37b-ii". This file is the contract D-store and Storeapp
mirror (like 37a's tenant-config schema), so change it together with `handover.md`
and tell both repos.

Provenance: the standards named here (TUF, Android APK Signature Scheme v3
proof-of-rotation, DNSSEC key rollover, NIST SP 800-57) are cited from memory, not
re-read source by source. Check a specific rule against the primary document before
relying on it.

## 1. What is being signed, and by which key

| Purpose (`purpose`) | Signs | Built |
|---|---|---|
| `catalog_index` | the tenant's `index.json` (same format as `docs/catalog_index_v2.md`) and its key manifest (section 4) | k2 onward |
| `tenant_config` | the signed tenant-config record served to Storeapp (Task 37c) | later, when 37c starts |

- One key serves **one purpose** (key-usage separation, NIST SP 800-57). The existing
  index format signs raw bytes with no context prefix, so it cannot be given domain
  separation without breaking readers; separate keys avoid needing it.
- The **default tenant is not in this scheme**: it stays on `CatalogIndexSigningKey`,
  which D-store already pins. Rotating that key can reuse this design later (Task 27 ❓3).
- Tenant **APK signing is out of scope**: apps stay signed by the org's `AndroidSigningKey`.
- Ed25519 (RFC 8032, no pre-hash), same primitives as `CatalogIndex::Ed25519`:
  private key PEM, encrypted at rest with Active Record Encryption; public key = base64 of
  the raw 32 bytes; `key_id` = first 16 hex chars of the SHA-256 of the raw public key
  (a label, not a security feature).

## 2. Key states

```
pending ──promote──► active ──(next promote)──► retiring ──retire──► retired
```

| State | Signs? | Trusted by readers? | Meaning |
|---|---|---|---|
| `pending` | no | **no** | Staged and published in the manifest so it can be baked into D-store and Storeapp pins **before** it is used. Never signs anything. |
| `active` | yes (primary) | yes | The key of record. Exactly one per (tenant, purpose). |
| `retiring` | yes (overlap only) | yes | The outgoing key, kept alive for the overlap window so clients pinned to it keep verifying. At most one. |
| `retired` | no | **no** | Finished. Never signs again. Its private key is destroyed once the operator has confirmed the retirement (k3). |

**Invariants (enforced in the model and by partial unique indexes, k2):**
1. At most one `active` and at most one `pending` per (tenant, purpose); at most one `retiring`.
2. After the first key is generated there is always exactly one `active`. A transition
   never leaves zero or two.
3. A key never returns to an earlier state.
4. `public_key` is unique across all tenants, so no two tenants can share a key.

**Transitions (each is one DB transaction, row locks taken in id order):**

| Transition | Effect |
|---|---|
| `generate` | First key for a (tenant, purpose): created directly as `active`. Refused if one exists. |
| `stage_next` | Creates the `pending` key. Refused if one is already pending. |
| `promote` | `pending` becomes `active`; the old `active` becomes `retiring`. The new key inherits the old key's `last_signed_at` (section 5). |
| `retire` | `retiring` becomes `retired`. Refused while the overlap window has not elapsed unless forced, and a forced retire is logged. |

Every transition bumps `sequence` (section 4) by one under the same lock.

## 3. Rotation timeline

| When | Step | Who verifies what |
|---|---|---|
| T0 | `stage_next`: the new key is `pending`; the manifest now lists it, signed by the `active` key. | Clients treat it as known but **not trusted**. |
| T0 to T1 (**pre-publish, ≥ 30 days, proposal**) | Ship at least one D-store deploy and one Storeapp release with **both** keys in their pin set. This is what rescues clients that skip the overlap. | |
| T1 | `promote`: the new key is `active`, the old one `retiring`. Manifest and index are **signed by both**. | A client pinned to the old key verifies the old signature, and adopts the new key because the manifest is signed by **both** (section 6). |
| T1 to T2 (**overlap, default 90 days, proposal**) | Both keys sign every index. Set the window to at least the slowest client's update lag; measure it from the D-store and Storeapp adoption of the T1 manifest, not from a guess. | Any client, old or new, verifies. |
| T2 | `retire`: manifest lists the old key as `retired`, signed by the new key only. Old key is destroyed after confirmation. | Clients drop trust in the retired key. A client that was offline for the whole overlap and only knows the old key **cannot verify the new manifest** and must be re-bootstrapped (an app or deploy update). This is the known cost of any pinned scheme. |

**Cadence (proposal, operator to confirm): rotate every 12 months**, plus an
out-of-band rotation on suspected compromise (section 7). NIST SP 800-57 allows much
longer cryptoperiods for signing keys; 12 months is chosen so the rotation path is
exercised regularly rather than discovered broken during an emergency.

## 4. What is published per tenant

Layout below is relative to a tenant's **publish root**. The default tenant's four
existing files are **unchanged** and stay at the Pages repo root. **Decided in
37b-iii-s1:** every other tenant's publish root is the directory `tenants/<tenant_id>/`
in the same Pages repo (`CatalogIndex::GithubPagesCommit.root_for`), and the publish
advisory lock is keyed by tenant (`CatalogIndex::Publish.lock_sql`), so one tenant's
publish never takes the default tenant's lock. A tenant's `catalog_index_base_url`
is where its readers fetch from, so a tenant can point a custom domain or CDN at its
directory without a separate repo.

**Built in 37b-iii-s4:** `CatalogIndex::Publish` for a non-default tenant writes `index.json`,
`index.json.sig`, `signing_key.pub` and `.nojekyll` under `tenants/<tenant_id>/`, signed with that
tenant's own `active` key and containing only that tenant's live apps (`App.for_tenant`). Its
index carries that tenant's own collections (37b-iii-s6a) and, until 37b-iii-s6b, no sponsored slots. Only the `active` key's
signature is written (the overlap `index.json.<key_id>.sig` files and the key manifest are k8), so
a rotation overlap is not yet visible to readers.

| Path (relative to the tenant publish root) | Content |
|---|---|
| `index.json` | The signed index, exact bytes, never re-serialised (unchanged rule). |
| `index.json.sig` | Base64 signature of the **`active`** key over those bytes. Same name and meaning as today, so an existing reader keeps working. |
| `index.json.<key_id>.sig` | Only during overlap: the `retiring` key's signature over the **same bytes**. A client looks up the file named after a key_id it has pinned. |
| `signing_key.pub` | The `active` public key, base64 raw. Informational only: **readers must never trust it, only their pins.** |
| `keys/<purpose>.json` | The key manifest (below). |
| `keys/<purpose>.json.<key_id>.sig` | One detached signature per signer. Steady state: the `active` key only. During a promotion: `active` (incoming) **and** `retiring` (outgoing). |

**Key manifest** (`keys/catalog_index.json`), serialised once, signed as exact bytes:

```jsonc
{
  "schema_version": 1,
  "type": "tenant_keys",
  "tenant_id": "acme",
  "purpose": "catalog_index",
  "sequence": 7,                       // integer, strictly increasing per (tenant, purpose)
  "generated_at": "2026-10-01T12:00:00Z",
  "keys": [
    { "key_id": "9f2c4a1b7d3e8a05", "public_key": "<base64 raw 32 bytes>", "status": "active",   "activated_at": "2026-10-01T12:00:00Z" },
    { "key_id": "1a7e5c0d99b3f2c4", "public_key": "<base64 raw 32 bytes>", "status": "retiring", "activated_at": "2025-10-01T12:00:00Z" }
  ]
}
```

- `sequence` is a **persisted integer**, not derived from the clock: every lifecycle
  transition sets it to (highest existing for that tenant and purpose) + 1 under the lock.
  Readers refuse a manifest whose `sequence` is not strictly greater than the last one
  they accepted (same rule as the index's `generated_at`). `generated_at` is display only.
- `tenant_id` and `purpose` are inside the signed bytes, so a manifest for one tenant or
  purpose cannot be replayed as another's.
- A `pending` key is listed with `"status": "pending"` and **no signature from it**.
- `retired` keys are listed for one manifest only (the T2 one), then dropped.

## 5. Anti-rollback across a rotation

Readers remember the newest index `generated_at` they accepted. The counter lives on the
key row (`last_signed_at`, advanced under `with_lock`, as `CatalogIndexSigningKey` does).
On `promote` the **new key inherits `last_signed_at`** from the old one, and during
overlap the signer uses the **maximum** across the signing keys and advances all of them,
so the index counter never goes backwards at the seam. Without this, a client that
remembers the old key's last value could refuse every index the new key issues.

**Signing during overlap (k5).** `CatalogIndex::Signer` signs the index with every key valid for
the tenant (`active`, plus `retiring` while a rotation overlaps), over the same bytes.
`Result#signature` is the `active` key's; `Result#signatures` lists every `{key_id, signature}`.
`generated_at` is the maximum of the keys' counters (plus one second if the clock has not passed
it) and every key is advanced to it, so no key's counter decreases. Key rows are locked in
ascending id order, the order `TenantKeys::Lifecycle` uses. Which key is chosen, and refusing to
fall back to the default tenant's key, is `CatalogIndex::KeyResolver` (k4). Publishing the extra
`index.json.<key_id>.sig` files is k8.

## 6. What a reader (D-store, Storeapp) must do

Pin **a set** of keys per (tenant, purpose), chosen by the tenant resolved from the host
(`6.b.ii.zi` / Storeapp `1.c.iii.zo`). A key valid for tenant A is **not** valid for
tenant B, even though both are genuine Zealot keys.

1. **Index.** Verify `index.json` against a signature file named for any pinned, trusted
   key (`index.json.sig` for the active one, `index.json.<key_id>.sig` otherwise). Any
   failure: discard and keep the last good index. Then apply the existing rules
   (`schema_version`, strictly increasing `generated_at`, `expires_at`).
2. **Manifest (rotation).** Fetch `keys/<purpose>.json`. Accept it only if **all** hold:
   a. it is signed by at least one key **already in the pin set** (continuity);
   b. every key it lists as `active` has also signed it (proof of possession); and
   c. `tenant_id` and `purpose` match, and `sequence` is strictly greater than the last accepted.
   On accept, replace the pin set with the manifest's `active` and `retiring` keys
   and persist it. Drop anything `retired` or absent. A manifest that fails any check
   is ignored; the client keeps the pins it has.
3. **Bootstrap.** The pins compiled into the app or deploy are the starting point, not the
   only path. A new build should carry the current `active` and any `pending` key.
4. **Never** trust `signing_key.pub` or a key merely because it appears in an unsigned
   or singly-signed manifest.

Ed25519 verification snippets are the same as `docs/catalog_index_v1.md` ("What a
reader must do", Node/WebCrypto).

## 7. Compromise: what this design can and cannot do

**Cannot.** Rule 2a means anyone holding a **pinned** key can produce a manifest the
client accepts, and rule 2b is satisfied by a key the attacker generates and signs with
themselves. Dual signing therefore proves continuity, not that the rotation is
legitimate. **If a pinned tenant key is stolen, the thief can rotate every client's trust
to a key of their choosing.** In-band revocation of a compromised pinned key is **not
possible** in this design.

**What to do anyway (runbook, in order):**
1. Stop publishing for the tenant (pause its publish job); do not sign anything new.
2. Generate a replacement `active` key; **no overlap** (a hard cut). The old key stays
   destroyed and is never promoted back.
3. Ship the new pin in a D-store deploy and a Storeapp release. Until a client has it, it
   keeps trusting the stolen key.
4. Publish a fresh index and manifest signed by the new key only.
5. Record the incident on the board: which tenant, which window, which clients may have
   been fed a forged index (compare the index's `generated_at` values against Zealot's publish log).

**The standard fix (deferred to Task 35a).** A long-lived, **offline root** that clients pin,
which signs the tenant's online keys (TUF's root/online split). Then an online-key
compromise is fixed by the root re-signing a replacement, with no client re-pin. It
changes what D-store and Storeapp pin, so it is designed separately and not built here.

## 8. Mapping to slices

| Slice | Implements |
|---|---|
| k2 | the model, states, invariants 1 to 4, `sequence` storage |
| k3 | the transitions in section 2 and the counter inheritance in section 5 |
| k4 | choosing the key for a tenant (default tenant stays on `CatalogIndexSigningKey`) |
| k5 | dual signing during overlap (section 3, T1 to T2; section 5 maximum rule) |
| k6, k7 | admin actions and panel for the transitions (no shell on the free plan) |
| k8 | publishing the manifest and signature files (section 4); needs 37b-iii for the publish root and lock |
| k9, k10 | D-store and Storeapp pin sets and manifest handling (section 6) |
| k11 | rotation drill and runbook (sections 3 and 7) |
