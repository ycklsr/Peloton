#!/bin/bash
#
# Installs Peloton on this Mac, and keeps exactly one copy of it.
#
#   ./Tools/install-mac.sh                 updates wherever it is installed
#   ./Tools/install-mac.sh /Applications   forces the folder
#
# Does four things that dragging the build product out of DerivedData does
# not:
#
#   1. builds in **Release** (faster and lighter than Debug);
#   2. installs over the copy you actually launch. The first version of this
#      script wrote to ~/Applications and nowhere else, so a Dock icon
#      pointing at /Applications went un-updated for as long as it existed,
#      without one word of warning: the script said "installed", and the app
#      you opened was the old one;
#   3. **quits the running copy** before replacing it — without that, two
#      copies can run at the same time, and since they share the same
#      identifier they also share the same device identity: both would
#      write the SAME file in the sync folder, the very thing the whole
#      architecture is built to make impossible;
#   4. checks, once the copy is done, that the HTML inside the installed
#      bundle really is the one in the working tree. `cp` succeeding proves
#      nothing about what xcodebuild put in the bundle.
#
# It refuses to run while TWO copies are installed, for the reason in (3):
# as far as the sync folder is concerned, two bundles both carrying
# fr.yannick.crpe2027.Peloton are ONE device — and which of them your Dock
# opens is a coin toss.
#
# Your data stays put: it lives in
# ~/Library/Containers/fr.yannick.crpe2027.Peloton (keyed on the app's
# identifier, not on its location) and in the sync folder.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../Peloton" && pwd)"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_HTML="$PROJECT_DIR/Peloton/duel-crpe-2027.html"

# ── Where is it installed? ────────────────────────────────────────────────
FOUND=()
for c in "/Applications/Peloton.app" "$HOME/Applications/Peloton.app"; do
  if [ -d "$c" ]; then FOUND+=("$c"); fi
done

if [ "${1:-}" != "" ]; then
  DESTINATION="${1%/}/Peloton.app"
elif [ "${#FOUND[@]}" -gt 1 ]; then
  echo "✗ Two copies are installed:"
  for f in "${FOUND[@]}"; do echo "      $f"; done
  echo
  echo "  Both carry fr.yannick.crpe2027.Peloton, so they are one device as far"
  echo "  as the sync folder is concerned: they write the same file, and which"
  echo "  one your Dock opens is a coin toss."
  echo
  echo "  Keep the one your Dock points at — check it with:"
  echo "      defaults read com.apple.dock persistent-apps | grep -o 'file:///[^\"]*Peloton[^\"]*'"
  echo "  delete the other, then run this again."
  exit 1
elif [ "${#FOUND[@]}" -eq 1 ]; then
  DESTINATION="${FOUND[0]}"
elif [ -w /Applications ]; then
  DESTINATION="/Applications/Peloton.app"
else
  DESTINATION="$HOME/Applications/Peloton.app"
fi

echo "▸ Target: $DESTINATION"

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

echo "▸ Building (Release)…"
cd "$PROJECT_DIR"
# CURRENT_PROJECT_VERSION changes on every install, and it has to.
# chronod decides whether to re-read a widget's descriptor by comparing
# (version, containerVersion) — CFBundleVersion of the extension and of its
# host. Pinned at "1", every rebuild looked "Unchanged extension" to it, so it
# served the descriptor captured at the very first build for days: wrong
# families, wrong kind, and no amount of reinstalling, re-registering or
# rebooting could shift it. A build stamp guarantees a new value each time.
STAMP="$(date +%Y%m%d%H%M%S)"
echo "▸ Build version: $STAMP"
xcodebuild -project Peloton.xcodeproj -scheme Peloton \
           -destination 'platform=macOS' -configuration Release build \
           CURRENT_PROJECT_VERSION="$STAMP" \
           > /tmp/peloton-build.log 2>&1 \
  || { echo "✗ Build failed. Details: /tmp/peloton-build.log"; exit 1; }

BUILT_DIR="$(xcodebuild -project Peloton.xcodeproj -scheme Peloton \
             -destination 'platform=macOS' -configuration Release \
             CURRENT_PROJECT_VERSION="$STAMP" -showBuildSettings 2>/dev/null \
             | awk -F' = ' '$1 ~ /^ *BUILT_PRODUCTS_DIR$/ {print $2; exit}')"
SOURCE="$BUILT_DIR/Peloton.app"
[ -d "$SOURCE" ] || { echo "✗ App not found: $SOURCE"; exit 1; }

echo "▸ Quitting the running copy (if there is one)…"
osascript -e 'tell application "Peloton" to quit' > /dev/null 2>&1 || true
sleep 1
pkill -f "Peloton.app/Contents/MacOS/Peloton" > /dev/null 2>&1 || true
sleep 1

echo "▸ Installing into $(dirname "$DESTINATION")…"
mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION"
cp -R "$SOURCE" "$DESTINATION"

# ── Did the bundle really get the current web app? ────────────────────────
# The whole domain lives in that one file. A build that reused a stale
# resource would install and launch perfectly, and simply be last week's app.
INSTALLED_HTML="$DESTINATION/Contents/Resources/duel-crpe-2027.html"
if [ ! -f "$INSTALLED_HTML" ]; then
  echo "✗ No duel-crpe-2027.html inside the installed bundle."; exit 1
fi
if ! cmp -s "$INSTALLED_HTML" "$SOURCE_HTML"; then
  echo "✗ The installed bundle carries a DIFFERENT duel-crpe-2027.html:"
  echo "      bundle: $INSTALLED_HTML"
  echo "      source: $SOURCE_HTML"
  echo "  Clean the build folder and try again (Xcode: ⇧⌘K)."
  exit 1
fi
echo "▸ Embedded duel-crpe-2027.html matches the working tree."

echo "▸ Launching…"
open "$DESTINATION"

echo "✓ Peloton installed — $(du -sh "$DESTINATION" | cut -f1) — $DESTINATION"
echo
echo "  Reminder: never run Peloton from Xcode (⌘R) while the installed copy"
echo "  is running. Both would write the same sync file. This script takes"
echo "  care of it for you; by hand, quit the app first."
