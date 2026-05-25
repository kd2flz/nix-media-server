# Comment for upstream issue kd2flz/nanitor-agent#9

## Root Cause Identified

I've identified the root cause of the enrollment failure. The issue is in the `preStart` script in `modules/services/nanitor-agent.nix` around lines 285-308.

### The Problem

When the enrollment key contains the ` + ` separator (format: `JWT + SIGNATURE`), the upstream module's `readKeyFileScript` incorrectly splits it into:

```
-----BEGIN ORGANIZATION SIGNUP KEY-----
JWT
SIGNATURE
-----END ORGANIZATION SIGNUP KEY-----
```

But the nanitor-agent v7 binary expects:

```
-----BEGIN ORGANIZATION SIGNUP KEY-----
JWT
+
SIGNATURE
-----END ORGANIZATION SIGNUP KEY-----
```

Note that the `+` must be on its own line between the JWT and signature.

### The Bug

In the current code (commit c091900):

```nix
if echo "$_BODY" | grep -qF ' + '; then
  # Key body uses ' + ' separator; split into JWT and signature on separate lines.
  _JWT=$(echo "$_BODY" | sed 's/ + .*//')
  _SIG=$(echo "$_BODY" | sed 's/.* + //')
  echo "[nanitor-agent unit] Key body has ' + ' separator; writing split-line PEM"
  printf '%s\n%s\n%s\n%s\n' \
    "-----BEGIN ''${_LABEL}-----" \
    "$_JWT" \
    "$_SIG" \
    "-----END ''${_LABEL}-----" > "$NANITOR_KEY_TMPFILE"
```

This creates a 4-line file (BEGIN, JWT, SIG, END) but the agent expects a 5-line file (BEGIN, JWT, +, SIG, END).

### Error Message

```
2026/05/19 14:20:45 ▶ E 0x1 Unable to decode signup key: Invalid input, signature separator
```

### The Fix

Change the printf to include the `+` separator:

```nix
if echo "$_BODY" | grep -qF ' + '; then
  _JWT=$(echo "$_BODY" | sed 's/ + .*//')
  _SIG=$(echo "$_BODY" | sed 's/.* + //')
  echo "[nanitor-agent unit] Key body has ' + ' separator; writing split-line PEM"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "-----BEGIN ''${_LABEL}-----" \
    "$_JWT" \
    "+" \
    "$_SIG" \
    "-----END ''${_LABEL}-----" > "$NANITOR_KEY_TMPFILE"
```

### Tested and Confirmed

This fix has been tested and confirmed working on NixOS 25.11 with:
- nanitor-agent v7.0.0.14708
- Enrollment key from sops-nix secret
- Successful enrollment with UUID: 4cf27a8b-5610-4dd9-5755-57a9432504db

### Workaround

For anyone affected by this issue, a temporary workaround is to create an override module. I can provide the code if needed.

### References

- Upstream module: https://github.com/kd2flz/nanitor-agent/blob/c0919007e30aff941fc420053511d299c9a7577c/modules/services/nanitor-agent.nix#L285-L308
- Working format confirmed by manual enrollment testing
