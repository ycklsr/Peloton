#!/bin/bash
#
# Installs Peloton on a connected iPhone, without opening Xcode.
#
#   ./Tools/install-ios.sh            the connected iPhone
#   ./Tools/install-ios.sh IphoneY    names one, when several are plugged in
#
# What it replaces: plug the phone in, open Xcode, pick the device, ⌘R. Which
# you have to redo every seven days — a free Apple ID signs for seven days and
# then the app simply stops launching. Your data survives that; the app does
# not. Re-running this script is the renewal.
#
# Four things:
#
#   1. finds the iPhone by itself, and refuses to guess when two are plugged
#      in — installing on the wrong phone is silent and confusing;
#   2. builds in **Release**, with -allowProvisioningUpdates, so the seven-day
#      certificate is renewed without Xcode being opened at all;
#   3. checks that duel-crpe-2027.html inside the built bundle is the one in
#      the working tree, BEFORE anything is installed. The whole domain lives
#      in that one file, and a build that reused a stale copy of it installs
#      and launches perfectly while simply being last week's app;
#   4. installs over the existing copy and relaunches it.
#
# Your data stays on the phone. It lives in the app's own container, keyed on
# fr.yannick.crpe2027.Peloton, and in the sync folder — installing over the top
# is an upgrade, not a fresh start. (Deleting the app from the home screen, on
# the other hand, takes the container with it. The sync folder still has
# everything; the phone would pull its history back on the next launch.)
#
# First time only, on the iPhone:
#   · Settings → Privacy & Security → Developer Mode → on (the phone restarts)
#   · after the first install, iOS refuses to open it until you go to
#     Settings → General → VPN & Device Management → your Apple ID → Trust

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../Peloton" && pwd)"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_HTML="$PROJECT_DIR/Peloton/duel-crpe-2027.html"
BUNDLE_ID="fr.yannick.crpe2027.Peloton"
BUILD_LOG="/tmp/peloton-ios-build.log"

# ── Which iPhone? ─────────────────────────────────────────────────────────
LIST="$(mktemp)"; trap 'rm -f "$LIST"' EXIT
xcrun devicectl list devices --json-output "$LIST" > /dev/null 2>&1 \
  || { echo "✗ devicectl did not answer. Is Xcode installed, and its licence accepted?"; exit 1; }

DEVICES="$(python3 - "$LIST" "${1:-}" <<'PY'
import json, sys
path = sys.argv[1]
wanted = sys.argv[2] if len(sys.argv) > 2 else ""
rows = []
for d in json.load(open(path)).get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    pr = d.get("deviceProperties", {})
    cp = d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or cp.get("pairingState") != "paired":
        continue
    ident = d.get("identifier", "")
    name = pr.get("name") or "?"
    if wanted and wanted not in (name, ident):
        continue
    rows.append("\t".join([ident, name,
                           hw.get("marketingName") or "",
                           pr.get("osVersionNumber") or "",
                           cp.get("tunnelState") or ""]))
print("\n".join(rows))
PY
)"

if [ -z "$DEVICES" ]; then
  echo "✗ No paired iPhone found${1:+ matching \"$1\"}."
  echo "  Plug it in over USB, unlock it, and answer \"Trust\" if it asks."
  echo "  Developer Mode must be on: Settings → Privacy & Security → Developer Mode."
  exit 1
fi
if [ "$(printf '%s\n' "$DEVICES" | wc -l | tr -d ' ')" -gt 1 ]; then
  echo "✗ Several iPhones are connected:"
  printf '%s\n' "$DEVICES" | while IFS=$'\t' read -r id name model os _; do
    echo "      $name — $model, iOS $os"
  done
  echo
  echo "  Name the one you mean:  ./Tools/install-ios.sh <name>"
  exit 1
fi

IFS=$'\t' read -r UDID NAME MODEL OSVER TUNNEL <<<"$DEVICES"
echo "▸ Target: $NAME — $MODEL, iOS $OSVER"
[ "$TUNNEL" = "connected" ] || echo "  (link is \"$TUNNEL\" — if the next step hangs, unlock the phone)"

# ── Does the web app even run? ───────────────────────────────────────────
# Both suites load duel-crpe-2027.html and execute it, so a syntax error stops
# here — before anything is built, signed, installed and launched. The bundle
# check further down proves the RIGHT file was copied; only this proves the
# file works at all. That gap once shipped an app that could not boot.
echo "▸ Checking the web app…"
if command -v node > /dev/null 2>&1; then
  for suite in projection notifications; do
    node "$REPO_DIR/Tests/$suite.test.mjs" "$SOURCE_HTML" > "/tmp/peloton-$suite.log" 2>&1 \
      || { echo "✗ Tests/$suite.test.mjs failed — nothing was installed."
           tail -20 "/tmp/peloton-$suite.log"
           exit 1; }
  done
  echo "▸ Both suites pass."
else
  echo "  (node not found — suites skipped, install continues)"
fi

# ── Build ─────────────────────────────────────────────────────────────────
# -allowProvisioningUpdates is what renews the seven-day certificate: without
# it, xcodebuild refuses rather than re-signing, and you are back in Xcode.
echo "▸ Building (Release, signing for this device)…"
cd "$PROJECT_DIR"
STAMP="$(date +%Y%m%d%H%M%S)"
echo "▸ Build version: $STAMP"
xcodebuild -project Peloton.xcodeproj -scheme Peloton \
           -destination "id=$UDID" -configuration Release \
           -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$STAMP" build \
           > "$BUILD_LOG" 2>&1 \
  || { echo "✗ Build failed. Details: $BUILD_LOG"
       echo "  If it is about signing: open Xcode once, Settings → Accounts,"
       echo "  and check your Apple ID is still there."
       exit 1; }

BUILT_DIR="$(xcodebuild -project Peloton.xcodeproj -scheme Peloton \
             -destination "id=$UDID" -configuration Release \
             CURRENT_PROJECT_VERSION="$STAMP" -showBuildSettings 2>/dev/null \
             | awk -F' = ' '$1 ~ /^ *BUILT_PRODUCTS_DIR$/ {print $2; exit}')"
APP="$BUILT_DIR/Peloton.app"
[ -d "$APP" ] || { echo "✗ App not found: $APP"; exit 1; }

# ── Is it really the current web app? ─────────────────────────────────────
# On iOS the bundle is flat: the resource sits at the root, not under
# Contents/Resources as it does on the Mac.
BUNDLED_HTML="$APP/duel-crpe-2027.html"
[ -f "$BUNDLED_HTML" ] || { echo "✗ No duel-crpe-2027.html inside $APP"
                            echo "  In Xcode: click the file → Target Membership → tick Peloton."
                            exit 1; }
cmp -s "$BUNDLED_HTML" "$SOURCE_HTML" \
  || { echo "✗ The built bundle carries a DIFFERENT duel-crpe-2027.html:"
       echo "      bundle: $BUNDLED_HTML"
       echo "      source: $SOURCE_HTML"
       echo "  Clean the build folder and try again (Xcode: ⇧⌘K)."
       exit 1; }
echo "▸ Embedded duel-crpe-2027.html matches the working tree."

# ── Install and launch ────────────────────────────────────────────────────
echo "▸ Installing on $NAME…"
xcrun devicectl device install app --device "$UDID" "$APP" > /dev/null \
  || { echo "✗ Install refused. If this is the first time, iOS needs you to"
       echo "  trust the certificate: Settings → General → VPN & Device"
       echo "  Management → your Apple ID → Trust. Then run this again."
       exit 1; }

echo "▸ Launching…"
xcrun devicectl device process launch --device "$UDID" \
      --terminate-existing "$BUNDLE_ID" > /dev/null \
  || echo "  (it did not launch by itself — open it from the home screen)"

echo "✓ Peloton installed on $NAME."
echo
echo "  The free certificate lasts seven days. When the app stops opening,"
echo "  run this again — the data on the phone is untouched by that."
