#!/usr/bin/env bash
#
# Fotografiert das Beispiel-Board in hell und dunkel -- einmal je Build, damit
# der sichtbare Stand jedes Builds festgehalten ist.
#
#   scripts/screenshots.sh [AUSGABEORDNER]
set -euo pipefail

OUT=${1:-screenshots}
BUNDLE_ID=${BUNDLE_ID:-com.example.soundtablet}
DERIVED=${DERIVED:-build/simulator}
COMMIT=$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

xcodegen generate >/dev/null

UDID=$(xcrun simctl list devices available \
  | grep -E '^[[:space:]]+iPhone' | head -1 \
  | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "Kein iPhone-Simulator verfuegbar." >&2; exit 1; }

xcodebuild build -scheme SoundTablet -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet
APP=$(find "$DERIVED/Build/Products" -maxdepth 3 -name "SoundTablet.app" | head -1)
[ -n "$APP" ] || { echo "Keine gebaute App gefunden." >&2; exit 1; }

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

# Einmal starten, damit der Datenordner existiert, dann Beispiel-Board hineinlegen
# (sonst zeigt jedes Bild nur den Leerzustand).
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null; sleep 2
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents/SoundTablet/Demo"
mkdir -p "$DIR"
python3 -I - "$DIR" <<'PY'
import json, math, struct, sys, uuid, wave
d = sys.argv[1]; tracks = []
for name, f, col in [("Intro Music", 220, "#E5484D"), ("Applause", 330, "#30A46C"), ("Drums 04", 440, "#0091FF"),
                     ("Crickets", 550, "#6E56CF"), ("Ticking Clock", 660, "#F5B800"), ("Welcome Voiceover", 770, "#D6409F")]:
    tid = str(uuid.uuid4()).upper(); fn = tid + ".wav"
    w = wave.open(d + "/" + fn, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * f * n / 44100))) for n in range(44100)))
    w.close()
    tracks.append({"id": tid, "name": name, "fileName": fn, "colorHex": col, "automations": [],
                   "settings": {"volume": 1, "loop": False, "solo": False, "fadeIn": 0, "fadeOut": 0, "trimIn": 0}})
json.dump({"id": str(uuid.uuid4()).upper(), "name": "Demo", "colorHex": "#0091FF", "tracks": tracks, "sortIndex": 0},
          open(d + "/board.json", "w"))
PY

mkdir -p "$OUT"
for MODE in light dark; do
  xcrun simctl ui "$UDID" appearance "$MODE" >/dev/null
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep 4
  xcrun simctl io "$UDID" screenshot "$OUT/$COMMIT-board-$MODE.png" >/dev/null
  echo "$COMMIT-board-$MODE.png"
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "Fertig: $OUT"
