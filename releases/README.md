# Releases

Built artifacts that you can download from the repo — no Flutter install,
no Actions tab, no unzip.

| File | Built | What it is |
|---|---|---|
| **[`terrastep-debug.apk`](terrastep-debug.apk)** | 2026-08-18 **v0.1.4+5** | Foreground service (O11). Uninstall the old build first. Confirm dump says `v0.1.4+5`. |

## Install on your phone

1. Open this folder on GitHub (mobile app is fine).
2. Tap `terrastep-debug.apk` → download.
3. Open the file → allow *install from unknown sources* for the browser/GitHub app.
4. Grant **Location** (precise) and **Physical activity** when asked.

## What this build is for

Pocket / screen-off walk (threshold 1.8). A persistent
**Terrastep is tracking** notification must stay up. Leave the phone in
your pocket 20–30 min, unlock, tap the overlay copy icon. Expect ~1 Hz
`raw gps` and a non-zero pedometer. Target **&lt;4 %/hr**; stop-and-redesign
if **&gt;6 %/hr**.

Full test checklist: [`../CURRENT_PROGRESS.md`](../CURRENT_PROGRESS.md) §0b
and [`../app/README.md`](../app/README.md).

## Rebuild

CI rebuilds a matching APK on every push that touches `app/`, `packages/`,
`scripts/`, or the workflow. Pin is Flutter **3.27.4**. See
`.github/workflows/build-apk.yml`.
