# Releases

Built artifacts that you can download from the repo — no Flutter install,
no Actions tab, no unzip.

| File | Built | What it is |
|---|---|---|
| **[`terrastep-debug.apk`](terrastep-debug.apk)** | 2026-08-18 **v0.1.2+3** | 80 m accuracy gate + GPS-chip fallback. Uninstall the old build first. |

## Install on your phone

1. Open this folder on GitHub (mobile app is fine).
2. Tap `terrastep-debug.apk` → download.
3. Open the file → allow *install from unknown sources* for the browser/GitHub app.
4. Grant **Location** (precise) and **Physical activity** when asked.

## What this build is for

A screen-on walk around the block. Confirm a hex fills, screenshot the
debug overlay, note battery %. Tracking **stops when you lock the screen**
— the foreground service is not in this build (open item O11).

Full test checklist: [`../CURRENT_PROGRESS.md`](../CURRENT_PROGRESS.md) §0b
and [`../app/README.md`](../app/README.md).

## Rebuild

CI rebuilds a matching APK on every push that touches `app/`, `packages/`,
`scripts/`, or the workflow. Pin is Flutter **3.27.4**. See
`.github/workflows/build-apk.yml`.
