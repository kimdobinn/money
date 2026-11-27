#!/bin/zsh
# Publishes a new version to GitHub Releases (kimdobinn/money). Installed copies see it in the
# menu bar / dashboard ("vX.Y.Z 업데이트") and update themselves in place.
#
#   ./release.sh                 # 1.1.0 -> 1.1.1
#   ./release.sh minor           # 1.1.0 -> 1.2.0
#   ./release.sh 2.0.0 "notes"   # explicit version and release notes
set -euo pipefail
cd "${0:A:h}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes — commit them first so the release matches the repo." >&2
  exit 1
fi

cur=$(cat VERSION)
case "${1:-patch}" in
  patch|minor|major)
    new=$(echo "$cur" | awk -F. -v k="${1:-patch}" '{
      if (k=="major") print $1+1".0.0"; else if (k=="minor") print $1"."$2+1".0"; else print $1"."$2"."$3+1 }') ;;
  *) new=$1 ;;
esac
if git rev-parse -q --verify "refs/tags/v$cur" >/dev/null; then
  log=$(git log --pretty='- %s' "v$cur"..HEAD)
else
  log=$(git log -10 --pretty='- %s')
fi
notes=${2:-$log}
echo "Releasing v$new (was v$cur)"

echo "$new" > VERSION
./build.sh   # builds Release with this version and installs it on this Mac too

out=build/release
rm -rf "$out" && mkdir -p "$out"
ditto -c -k --keepParent build/Build/Products/Release/money.app "$out/money.zip"
python3 -c 'import json,sys; json.dump({"version": sys.argv[1], "notes": sys.argv[2]}, open(sys.argv[3], "w"), ensure_ascii=False)' \
  "$new" "$notes" "$out/latest.json"

git diff --quiet VERSION || git commit -q -m "Release v$new" VERSION
git tag "v$new"
git push -q origin HEAD "v$new"
gh release create "v$new" "$out/money.zip" "$out/latest.json" --title "money v$new" --notes "$notes"
echo "Published v$new"
