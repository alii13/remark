#!/bin/bash
# release.sh <version> [build]
#
# Builds + notarizes the app, packages it as a Sparkle update, and regenerates the signed
# appcast. Then prints the publish steps for you to run (they change GitHub and need your push
# bypass, so the script stops short of doing them).
#
# Needs: REMARK_SIGN_IDENTITY and REMARK_NOTARY_PROFILE set, and the Sparkle EdDSA private key
# in your login keychain (created once by vendor/sparkle/bin/generate_keys).
set -e
cd "$(dirname "$0")"
VERSION="${1:?usage: release.sh <version>   e.g. release.sh 0.2}"
BUILD="${2:-$(date +%Y%m%d%H%M)}"   # Sparkle compares CFBundleVersion; keep it increasing

export REMARK_BUILD="$BUILD"
echo "building + notarizing v$VERSION (build $BUILD)…"
bash build.sh notarize

mkdir -p dist
ARCHIVE="dist/Remark-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent build/Remark.app "$ARCHIVE"
echo "packaged $ARCHIVE"

# Sign each archive in dist/ and (re)write the appcast. The enclosure URLs point at the GitHub
# release asset for this version.
vendor/sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/alii13/remark/releases/download/v$VERSION/" \
  dist
mv -f dist/appcast.xml appcast.xml
echo "appcast.xml regenerated and signed"

cat <<NEXT

Done building. To publish v$VERSION:

  1. Create the GitHub release with the update archive:
       gh release create v$VERSION "$ARCHIVE" --title "v$VERSION" --notes "<what changed>"

  2. Commit and push the appcast (Sparkle reads it from the raw URL on main):
       git add appcast.xml
       git commit -m "Release v$VERSION"
       git push origin main            # needs your one-time Git Guard bypass

Running Remarks will see the update within a day, or on "Check for Updates".
NEXT
