#!/bin/bash
# Makes a release of Overlap: an optimized build, zipped for sharing, signed for Sparkle and added to the update
# feed. Nothing here needs an Apple developer account.
#
#   Scripts/make-release.sh 0.6.0
#
# Writes build/Releases/updates/Overlap-<version>.zip, the feed build/Releases/appcast.xml, and a copy of the
# newest zip as build/Releases/Overlap.zip for first installs. Scripts/publish-release.sh puts them on the
# repository's GitHub Pages. Every zip in build/Releases/updates stays in the feed, so keep earlier ones there.
#
# The build is signed with the "Overlap Code Signing" certificate when the Keychain has one (see RELEASING.md),
# and ad hoc otherwise. The Sparkle key is read from ~/Library/Application Support/Overlap Release, or from the
# file OVERLAP_SPARKLE_KEY names.
set -euo pipefail

usage() {
    echo "usage: $0 <version> [--download-url-prefix <url>] [--build <number>] [--bundle-id <id>] [--output <folder>]" >&2
    exit 64
}

[[ $# -ge 1 && $1 != -* ]] || usage
version=$1
shift
root=$(cd "$(dirname "$0")/.." && pwd)
# Where Sparkle downloads each version's zip: the updates folder on the repository's GitHub Pages.
prefix="https://chasingux.github.io/Overlap/updates/"
# Sparkle compares build numbers, so each release needs a bigger one; the commit count always grows.
build=$(git -C "$root" rev-list --count HEAD)
bundle_id=""
output="$root/build/Releases"
while [[ $# -gt 0 ]]; do
    case $1 in
        --download-url-prefix) prefix=$2; shift 2 ;;
        --build) build=$2; shift 2 ;;
        --bundle-id) bundle_id=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        *) usage ;;
    esac
done

key=${OVERLAP_SPARKLE_KEY:-"$HOME/Library/Application Support/Overlap Release/sparkle-private-key"}
if [[ ! -f $key ]]; then
    echo "No Sparkle key at $key. See RELEASING.md." >&2
    exit 1
fi

# A self-signed certificate isn't trusted the way Apple's are, so it's looked up among all identities, not only
# the valid ones.
identity="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"Overlap Code Signing"'; then
    identity="Overlap Code Signing"
fi

derived="$root/build/ReleaseDerivedData"
settings=(
    MARKETING_VERSION="$version"
    CURRENT_PROJECT_VERSION="$build"
    CODE_SIGN_IDENTITY="$identity"
    CODE_SIGN_STYLE=Manual
    # The hardened runtime only matters for notarizing, and without Apple's Team ID it would stop the app loading
    # its own Sparkle framework.
    ENABLE_HARDENED_RUNTIME=NO
)
[[ -n $bundle_id ]] && settings+=(PRODUCT_BUNDLE_IDENTIFIER="$bundle_id")

mkdir -p "$output/updates"
log="$output/build-$version.log"
echo "Building Overlap $version ($build), signed with ${identity/-/an ad hoc signature}…"
if ! xcodebuild -project "$root/Overlap.xcodeproj" -scheme Overlap -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$derived" "${settings[@]}" build > "$log" 2>&1; then
    grep -E "error:" "$log" | sort -u >&2 || tail -20 "$log" >&2
    echo "The build failed; the whole log is in $log." >&2
    exit 1
fi
rm -f "$log"

app="$derived/Build/Products/Release/Overlap.app"
zip="$output/updates/Overlap-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
cp "$zip" "$output/Overlap.zip"

tools="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$tools/generate_appcast" --ed-key-file "$key" --download-url-prefix "$prefix" --maximum-deltas 0 \
    -o "$output/appcast.xml" "$output/updates"
echo "$version" > "$output/version.txt"

echo "Made Overlap $version in $output."
