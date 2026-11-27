#!/bin/zsh
# Regenerates the Xcode project, builds Release, installs to /Applications and relaunches.
set -euo pipefail
cd "${0:A:h}"
xcodegen generate -q
VERSION=$(cat VERSION)
xcodebuild -project Brokers.xcodeproj -scheme Brokers -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
pkill -x money 2>/dev/null || true
pkill -x Brokers 2>/dev/null || true  # pre-rename build
sleep 1
rm -rf /Applications/Brokers.app  # renamed to money.app
ditto build/Build/Products/Release/money.app /Applications/money.app
open /Applications/money.app
echo "Installed /Applications/money.app"
