#!/bin/zsh
# Installs (or reinstalls) the latest money.app from GitHub Releases:
#   curl -fsSL https://raw.githubusercontent.com/kimdobinn/money/main/install.sh | zsh
# After this, the app updates itself (menu bar → "vX.Y.Z 업데이트", or 설정 > 표시 > 앱 업데이트).
set -euo pipefail
URL="https://github.com/kimdobinn/money/releases/latest/download/money.zip"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading money…"
curl -fL# "$URL" -o "$tmp/money.zip"
ditto -x -k "$tmp/money.zip" "$tmp"
codesign --verify --deep --strict "$tmp/money.app"

pkill -x money 2>/dev/null && sleep 1 || true
rm -rf /Applications/money.app
ditto "$tmp/money.app" /Applications/money.app
xattr -dr com.apple.quarantine /Applications/money.app 2>/dev/null || true
open /Applications/money.app
echo "Installed /Applications/money.app — sign in with Google in 설정 > 동기화 to see your portfolio."
