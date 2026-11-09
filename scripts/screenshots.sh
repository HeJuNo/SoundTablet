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
    k = len(tracks)  # vary subtitle and settings so the tile design (second line, icons) is visible
    tracks.append({"id": tid, "name": name, "fileName": fn, "colorHex": col, "automations": [],
                   "subtitle": ["2 bars · 120 BPM", None, "Section 2", None, "Loop", "Voice"][k],
                   "settings": {"volume": 1, "loop": k in (0, 2, 4), "solo": k == 5, "fadeIn": 1 if k in (0, 3) else 0,
                                "fadeOut": 2 if k in (0, 1) else 0, "trimIn": 0}})
# "Loop Demo": clicks at 120 BPM for 17 s, so the loop suggestions and the editor have something real to show
tid = str(uuid.uuid4()).upper(); fn = tid + ".wav"
w = wave.open(d + "/" + fn, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
frames = []
for n in range(44100 * 17):
    t = (n % 22050) / 44100  # a click every 0.5 s
    frames.append(struct.pack("<h", int(20000 * math.sin(2 * math.pi * 1000 * t) * math.exp(-t / 0.008)) if t < 0.05 else 0))
w.writeframes(b"".join(frames)); w.close()
tracks.append({"id": tid, "name": "Loop Demo", "fileName": fn, "colorHex": "#30A46C", "automations": [],
               "settings": {"volume": 1, "loop": False, "solo": False, "fadeIn": 0, "fadeOut": 0, "trimIn": 2}})
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
# Weitere Zustaende (nur Debug-Build): Track-Editor, Loop-Vorschlaege, Track-Einstellungen, Defaults.
for SCREEN in editor suggestions settings defaults; do
  for MODE in light dark; do
    xcrun simctl ui "$UDID" appearance "$MODE" >/dev/null
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demoScreen "$SCREEN" >/dev/null
    sleep 6
    xcrun simctl io "$UDID" screenshot "$OUT/$COMMIT-$SCREEN-$MODE.png" >/dev/null
    echo "$COMMIT-$SCREEN-$MODE.png"
  done
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "Fertig: $OUT"
