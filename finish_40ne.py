import os

os.chdir(os.path.expanduser('~/zealot'))

f = 'handover.md'
s = open(f).read()

# Mark 40n-e as built
s = s.replace("| 40n-e | **Storeapp tenant build produces an unsigned bundle.**", "| 40n-e ✅ | **Storeapp tenant build produces an unsigned bundle.**")

# Add result block for 40n-e
result_block = """
#### 40n-e result (built this session; written, NOT run)

**What it is.** The Storeapp tenant build workflow (`.github/workflows/build-tenant-apk.yml` in the Storeapp repo) was rewritten. It no longer signs the APK with a tenant keystore. Instead, it runs `:app:bundleTenantRelease` to produce an unsigned `.aab`, calculates its SHA-256, uploads it as an artifact, and sends a `repository_dispatch` to `Zapier-codes/zealot-storage` to trigger the `harvest-tenant-apk` workflow (40n-d).

**Files (1, in Storeapp repo).** `.github/workflows/build-tenant-apk.yml`.

**Operator setup.** Add a `ZEALOT_STORAGE_PAT` secret to the Storeapp repo (a fine-grained PAT with `Actions: Write` on `Zapier-codes/zealot-storage`). The old `TENANT_KEYSTORE_*` secrets in Storeapp can now be deleted.

**Not verified.** Nothing was run.
"""
s = s.replace("| 40n-f | **Delivery: the file behind the email button.**", result_block + "\n| 40n-f | **Delivery: the file behind the email button.**")

open(f, 'w').write(s)
print("Handover updated for 40n-e.")
