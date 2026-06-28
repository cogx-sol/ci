# `swa-deploy`

Composite action: install deps → build a static site → deploy to Azure Static Web Apps.
Framework-agnostic (Next export, Astro, Vite, …) via inputs.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `api_token` | yes | — | SWA deployment token (store as a repo secret). |
| `output_dir` | yes | — | Built output dir: `out` (Next export), `dist` (Astro/Vite). |
| `build_command` | no | `npm run build` | Command that produces the static output. |
| `install_command` | no | derived | Override install; default per `package_manager`. |
| `package_manager` | no | `npm` | `npm` \| `pnpm` \| `yarn` — sets default install + dependency cache. |
| `node_version` | no | `22` | Node.js version. |
| `deployment_action` | no | `upload` | `upload` to build+deploy, `close` to tear down a PR preview. |

**Build env vars** (e.g. `NEXT_PUBLIC_*`) are not inputs — set them on the calling
job/step `env:` and the build step inherits them. Checkout the repo before this step.

## Production deploy (Next export, pnpm)

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: cogx-sol/ci/swa-deploy@v1
        with:
          api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          output_dir: out
          build_command: pnpm build
          package_manager: pnpm
        env:
          NEXT_PUBLIC_CONTACT_ENDPOINT: ${{ vars.NEXT_PUBLIC_CONTACT_ENDPOINT }}
          # …other NEXT_PUBLIC_* the build needs
```

## PR previews

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  preview:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    permissions: { contents: read, pull-requests: write }
    steps:
      - uses: actions/checkout@v7
      - uses: cogx-sol/ci/swa-deploy@v1
        with:
          api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          output_dir: out
          build_command: pnpm build
          package_manager: pnpm

  close:
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: cogx-sol/ci/swa-deploy@v1
        with:
          api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          output_dir: out
          deployment_action: close
```

## Astro / Vite

```yaml
      - uses: cogx-sol/ci/swa-deploy@v1
        with:
          api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          output_dir: dist
          build_command: npm run build
```
