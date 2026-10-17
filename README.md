# IP Vault release: GitHub Action

Seals your app's models, data and content on the runner and registers them with IP Vault, so
only licensed installs can open them. The plaintext never leaves the runner: the service receives
each asset's key wrapped to your tenant's ingestion key, and the sealed file's hash and size.

```yaml
on:
  push:
    tags: ["v*"]                      # publish from trusted refs only

jobs:
  release:
    runs-on: ubuntu-24.04
    environment: release              # optional: required reviewers, and a binding can require it
    permissions:
      contents: read
      id-token: write                 # the job's OIDC identity: no stored secret
    steps:
      - uses: actions/checkout@<sha>
      - id: ipvault
        uses: rev3rse-dev/ipvault-release-action@<commit-sha>   # pin by commit: it pins the binary too
      - run: ./gradlew assembleRelease # packages the sealed outputs the manifest wrote
      - uses: rev3rse-dev/ipvault-release-action@<commit-sha>
        with:
          verify: app/build/outputs/apk/release/app-release.apk
          receipt: ${{ steps.ipvault.outputs.receipt }}
```

The manifest, `ipvault.toml` at the repository root by default, declares each asset:

```toml
version = 1

[app]
platform = "android"
id = "com.acme.vitals"

[[asset]]
id = "model:vitals"                      # what the app opens
version = 3
source = "private/vitals.onnx"           # plaintext: never inside a packaged directory
output = "app/src/main/assets/vitals.ipva"
entitlements = ["premium"]               # licences of these entitlements can open it
```

`ipvault release plan` shows the release a manifest makes, without a credential or network.

## Credentials

**OIDC (recommended).** With `id-token: write`, the runner gives the job a short-lived token,
signed by GitHub, naming its repository, ref, environment and workflow. IP Vault admits it only
through a **binding** your operator makes once per app and repository: the repository and its
owner by numeric id (names change on rename and can be registered again by someone else), the
refs that may publish (exact, or a prefix such as `refs/tags/v*`), and optionally an environment
and the workflow (`job_workflow_ref`). There is no secret to store, rotate or leak.

**A CI token**, for runners without OIDC: set `token: ${{ secrets.IPVAULT_TOKEN }}`. It takes
precedence when set.

## What publishing does

1. **Begin.** The service reserves a new key version for each asset (it allocates versions; a
   reserved version is never reused) and returns your tenant's ingestion public key.
2. **Seal, here.** Each asset gets a fresh key, is sealed to its output path, and the key is
   wrapped to the ingestion key. The raw key never touches disk.
3. **Register.** The wrapped keys and the sealed files' hashes are committed in one transaction,
   with grants added to the named entitlements. Grants are only added: licences for builds you
   already shipped keep working.

Every call is idempotent. A repeated step resumes the same release with the same sealed files;
a re-run of the job is a new attempt with fresh keys. A changed input under the same attempt is
refused rather than silently re-reserved.

| Input | Default | |
|---|---|---|
| `token` | | The app's CI token, from a secret. Not needed with OIDC |
| `manifest` | `ipvault.toml` | The release manifest |
| `verify` | | Instead of publishing, check this built package |
| `receipt` | | With `verify`: the publishing step's `receipt` output |
| `server` | `https://vault.rev3rse.dev` | The key service |
| `audience` | the server URL | With OIDC: the audience the job's token is requested for |
| `operation-id` | from the run | Names the attempt; a re-run is a new attempt |
| `max-bytes` | `4GiB` | With `verify`: total bytes read out of archives |
| `version` | pinned | The `ipvault` CLI version; must be pinned in `checksums.txt` |
| `ipvault-path` | | Use your own `ipvault` binary instead of downloading one |
| `download-repo` | | Download the pinned archive from your private mirror's release |

Outputs: `release-id`, `receipt`, `passed` (verify), `exit-code` (0 success, 1 the package check
failed, 2 error or refusal), `report`, `junit`.

## Where a credential may and may not be

- **Publishing is refused, by name, from a pull request opened from a fork** (forks receive
  neither secrets nor an OIDC token) **and from `pull_request_target`**, which runs with your
  secrets and identity next to code from the pull request. The service refuses an OIDC token
  from a `pull_request` or `pull_request_target` job whatever the binding says. Verify and scan
  need no credential and run anywhere.
- A token or binding is app-scoped: it can publish new key versions for one app into the
  entitlements it was created for. It cannot read a key, replace a registered version, remove a
  grant or touch another app. Both expire, and revoking one takes effect on its next request.
- A credential reaches the CLI only as an environment variable, never as an argument, and the
  CLI hands it to `curl` on standard input. An OIDC token is requested for each call and never
  written down. Receipts and the audit log name the job (repository, ref, run, commit).

## What `verify` checks

Every sealed output in the manifest is in the package, byte for byte (against the receipt), and
no plaintext input is, as a whole file or as a fragment: it samples one window per 4 KiB of each
input, so any shipped fragment of 8 KiB or more of an input up to 16 MiB is found, and larger
inputs are sampled more sparsely. Nested archives are opened. Names inside the package are
untrusted, so its report is printed with workflow commands suspended.

---

This repository is generated from `actions/release` in the IP Vault source by `ci/mirror.py`, which also
checks a published copy byte for byte against the source at the same tag. Changes go to the
source, not here. Pin this action by commit SHA: the commit pins the `ipvault` binary through
`checksums.txt`.
