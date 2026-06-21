# cogx-sol/ci

Shared GitHub Actions CI building blocks for our repos. One place to fix a
pipeline instead of editing every repo.

## What's here

| Path | Type | Purpose |
|---|---|---|
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | Reusable workflow | Tag + GitHub release, **semver or calver** (`version_scheme`); skips when nothing changed (`force` to override). Deploy-agnostic — exposes `should_release` / `version` outputs. |
| [`swa-deploy/`](swa-deploy) | Composite action | Build a static site and deploy it to Azure Static Web Apps. |

## Layout rules (why things live where)

- **Reusable workflows** must sit flat in `.github/workflows/` — referenced as
  `cogx-sol/ci/.github/workflows/<file>.yml@v1` at the **job** level.
- **Composite actions** each get their own top-level folder with an `action.yml`
  — referenced as `cogx-sol/ci/<name>@v1` at the **step** level.

Add future actions as new top-level folders; future reusable workflows as new
files under `.github/workflows/`.

## Versioning

`release.yml` supports two schemes. Pick per call with the `version_scheme`
input, or repo-wide by setting a `VERSION_SCHEME` repo/org variable (the input
wins; default is `semver`). A non-empty `version` input overrides either scheme.
The two schemes filter tags by shape, so their tags never interfere with each
other's "latest" lookup if a repo switches.

### semver (default — for this repo and other consumed libraries)

Releases are tagged `vMAJOR.MINOR.PATCH`; an empty `version` auto-bumps the patch
of the latest semver tag. Consumers pin a **major** tag (`@v1`), and the workflow
advances that moving `v1` tag to each new `v1.x.y` release, so `@v1` keeps getting
fixes. Breaking changes bump to `v2`. **Don't pin `@main`.**

### calver (for app / deploy repos)

Releases are tagged `vYYYYMMDD`, then `vYYYYMMDD.1`, `vYYYYMMDD.2`, … for further
releases the same (UTC) day. There's no moving major tag — date tags aren't
compatibility promises — so consumers pin the exact date tag (or just deploy
`main`). Enable it on a repo with:

```yaml
# in the consumer's release.yml job
with:
  version_scheme: calver        # or set the VERSION_SCHEME repo variable to "calver"
```

> This `cogx-sol/ci` repo itself uses **semver** — it's consumed via `@v1`.
> CalVer is meant for the application repos that consume these building blocks.

## Putting it together

A consumer's `release.yml` that tags **and** deploys to SWA on release:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      version: { description: 'Explicit version (optional)', type: string, required: false }
      force:   { description: 'Release with no new commits', type: boolean, default: false }

jobs:
  release:
    uses: cogx-sol/ci/.github/workflows/release.yml@v1
    with:
      version: ${{ inputs.version }}
      force: ${{ inputs.force }}

  deploy:
    needs: release
    if: needs.release.outputs.should_release == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: cogx-sol/ci/swa-deploy@v1
        with:
          api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          output_dir: out
          build_command: pnpm build
          package_manager: pnpm
        env:
          NEXT_PUBLIC_CONTACT_ENDPOINT: ${{ vars.NEXT_PUBLIC_CONTACT_ENDPOINT }}
```

See [`swa-deploy/README.md`](swa-deploy/README.md) for PR previews and other frameworks.

> Secrets and variables still live in each consuming repo — this repo centralizes
> *logic*, not configuration.
