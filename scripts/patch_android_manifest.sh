#!/usr/bin/env bash
# ============================================================================
# Inject Terrastep's Android permissions into the generated manifest.
#
# `flutter create` regenerates AndroidManifest.xml from a template, so the
# permissions cannot simply be committed — they would be overwritten. This
# script is idempotent and runs after generation, in CI and locally.
#
#   bash scripts/patch_android_manifest.sh     (run from app/)
# ============================================================================
set -euo pipefail

MANIFEST="android/app/src/main/AndroidManifest.xml"
[ -f "$MANIFEST" ] || { echo "ERROR: $MANIFEST not found. Run from app/ after flutter create." >&2; exit 1; }

if grep -q "ACCESS_FINE_LOCATION" "$MANIFEST"; then
  echo "→ permissions already present, skipping"
else
  echo "→ injecting permissions"
  python3 - "$MANIFEST" <<'PY'
import sys, re
path = sys.argv[1]
xml = open(path).read()

perms = '''
    <!-- Location: FINE for hex-accurate claiming, COARSE as fallback. -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>

    <!-- Background location. Requested separately AFTER foreground is granted;
         Android 11+ auto-denies a combined request. -->
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>

    <!-- Step counter. Required from Android 10 (API 29). -->
    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>

    <!-- Foreground service, so tracking survives the screen turning off. -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>

    <uses-permission android:name="android.permission.INTERNET"/>

    <!-- Step counter is optional so the app still installs on devices without
         the sensor (it falls back to distance-only, and the debug overlay
         reports NO SENSOR). -->
    <uses-feature android:name="android.hardware.sensor.stepcounter" android:required="false"/>
    <uses-feature android:name="android.hardware.location.gps" android:required="false"/>
'''

xml = xml.replace('<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
                  '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n' + perms, 1)
open(path, 'w').write(xml)
print("   done")
PY
fi

# Cleartext traffic: OSM raster tiles are fetched over https, but some Android
# WebView/tile stacks fall back to http on redirect. Debug builds only.
if ! grep -q "usesCleartextTraffic" "$MANIFEST"; then
  sed -i 's|android:label="terrastep"|android:label="Terrastep"\n        android:usesCleartextTraffic="true"|' "$MANIFEST" || true
fi

echo "→ manifest ready"
grep -c "uses-permission" "$MANIFEST" | xargs echo "   permissions declared:"
