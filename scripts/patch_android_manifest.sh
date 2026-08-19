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

python3 - "$MANIFEST" <<'PY'
import sys
path = sys.argv[1]
xml = open(path).read()

needed = [
    ('ACCESS_FINE_LOCATION',
     '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>'),
    ('ACCESS_COARSE_LOCATION',
     '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>'),
    ('ACCESS_BACKGROUND_LOCATION',
     '    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>'),
    ('ACTIVITY_RECOGNITION',
     '    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>'),
    ('FOREGROUND_SERVICE"',
     '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>'),
    ('FOREGROUND_SERVICE_LOCATION',
     '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>'),
    ('WAKE_LOCK',
     '    <uses-permission android:name="android.permission.WAKE_LOCK"/>'),
    ('POST_NOTIFICATIONS',
     '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'),
    ('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
     '    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>'),
    ('INTERNET',
     '    <uses-permission android:name="android.permission.INTERNET"/>'),
]

insert = []
for needle, line in needed:
    if needle not in xml:
        insert.append(line)
        print(f'   + {needle.strip(chr(34))}')

features = '''    <uses-feature android:name="android.hardware.sensor.stepcounter" android:required="false"/>
    <uses-feature android:name="android.hardware.location.gps" android:required="false"/>'''
if 'android.hardware.sensor.stepcounter' not in xml:
    insert.append(features)
    print('   + sensor/gps features')

if insert:
    block = '\n'.join(insert) + '\n'
    old = '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
    if old not in xml:
        sys.exit('ERROR: unexpected manifest header')
    xml = xml.replace(old, old + '\n' + block, 1)
    print('→ injected missing permissions')
else:
    print('→ permissions already present')

if 'usesCleartextTraffic' not in xml:
    xml = xml.replace('android:label="terrastep"',
                      'android:label="Terrastep"\n        android:usesCleartextTraffic="true"')
    xml = xml.replace('android:label="Terrastep"',
                      'android:label="Terrastep"\n        android:usesCleartextTraffic="true"', 1) \
        if 'usesCleartextTraffic' not in xml else xml

# Magic-link callback. singleTask so the email tap returns to this activity
# instead of stacking a second MainActivity.
if 'android:launchMode="singleTop"' in xml:
    xml = xml.replace('android:launchMode="singleTop"',
                      'android:launchMode="singleTask"', 1)
    print('   + launchMode singleTask')

if 'io.terrastep.app' not in xml:
    callback = '''
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="io.terrastep.app" android:host="login-callback"/>
            </intent-filter>'''
    needle = '        </activity>'
    if needle not in xml:
        sys.exit('ERROR: activity close tag not found')
    xml = xml.replace(needle, callback + '\n' + needle, 1)
    print('   + magic-link intent-filter io.terrastep.app://login-callback/')

open(path, 'w').write(xml)
print('   done')
PY

echo "→ manifest ready"
grep -c "uses-permission" "$MANIFEST" | xargs echo "   permissions declared:"
