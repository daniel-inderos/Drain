#!/bin/zsh
# Builds Drain.app next to this script.
#   ./build.sh            build ./Drain.app
#   ./build.sh --install  also replace /Applications/Drain.app and relaunch it
# Signing: DRAIN_SIGN_IDENTITY=<identity or hash> picks one ("-" = ad hoc); otherwise the
# first "Apple Development" identity in the keychain; otherwise ad hoc.
set -euo pipefail
cd "${0:A:h}"

case "${1:-}" in
  ""|--install) ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { echo "Too many arguments (try --help)" >&2; exit 2; }

swift build -c release

APP=Drain.app
STAGE=Drain.app.new
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp .build/release/Drain "$STAGE/Contents/MacOS/Drain"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"

# A stable identity keeps the login item and permissions across rebuilds; ad hoc changes every build.
identity="${DRAIN_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  found="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  identity="$(print -r -- "$found" | awk '/"Apple Development/ { print $2; exit }')"
fi
if [[ -n "$identity" && "$identity" != "-" ]] && codesign --force --sign "$identity" "$STAGE" >/dev/null 2>&1; then
  echo "Signed with identity ${identity:0:8}"
else
  [[ -z "$identity" || "$identity" == "-" ]] || echo "Signing with identity ${identity:0:8} failed."
  codesign --force --sign - "$STAGE" >/dev/null 2>&1 || { echo "Ad hoc signing failed." >&2; exit 1; }
  echo "Signed ad hoc (login item and permissions will not survive rebuilds)"
fi

rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  # Copy beside the destination first, so a failure leaves the old app in place.
  rm -rf /Applications/Drain.app.new
  ditto "$APP" /Applications/Drain.app.new
  pkill -x Drain || true
  rm -rf /Applications/Drain.app
  mv /Applications/Drain.app.new /Applications/Drain.app
  open /Applications/Drain.app
  echo "Installed /Applications/Drain.app"
fi
