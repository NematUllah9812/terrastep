# Releases

Built artifacts that you can download from the repo — no Flutter install,
no Actions tab, no unzip.

| File | Built | What it is |
|---|---|---|
| **[`terrastep-debug.apk`](terrastep-debug.apk)** | 2026-08-19 **v0.1.5+6** | Idle GPS 20 s / walk 2 s. Uninstall old first. Dump must say `v0.1.5+6`. |

## Install on your phone

1. Open this folder on GitHub (mobile app is fine).
2. Tap `terrastep-debug.apk` → download.
3. Open the file → allow *install from unknown sources* for the browser/GitHub app.
4. Grant **Location** (precise) and **Physical activity** when asked.

## What this build is for

Battery test. Stand still until overlay `gps mode` says **idle 20s**,
walk until it says **walk 2s**, then pocket 20–30 min. Shade must show
**Terrastep is tracking**. Copy overlay after. Target **&lt;4 %/hr**.

Full test checklist: [`../CURRENT_PROGRESS.md`](../CURRENT_PROGRESS.md) §0b
and [`../app/README.md`](../app/README.md).

## Rebuild

CI rebuilds a matching APK on every push that touches `app/`, `packages/`,
`scripts/`, or the workflow. Pin is Flutter **3.27.4**. See
`.github/workflows/build-apk.yml`.
