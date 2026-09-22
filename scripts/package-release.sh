#!/usr/bin/env bash
# Produces what a release of the Swift package needs:
#
#   dist/ClayzoEngineCore.xcframework.zip   the Rust core, iOS + simulator + macOS
#   dist/checksum.txt                        `swift package compute-checksum` of the zip
#   dist/Package.swift                       Package.swift with the binary target pointed
#                                            at the zip's download URL and checksum
#
# Usage: scripts/package-release.sh <download-url-of-the-zip>
#
# publish-swift.yml runs this and pushes the result to the package repository
# (its Package.swift must sit at the repository root — SwiftPM has no sub-path
# packages), with the zip committed at the tag and dist/Package.swift as that
# tag's manifest. Consumers then add the package by URL; Xcode downloads the
# zip once and verifies the checksum.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
url="${1:?download url of ClayzoEngineCore.xcframework.zip}"
dist="$here/dist"

"$here/scripts/build-xcframework.sh"

# Debug info and local symbols are of no use to a consumer's linker and are
# most of the archive's weight.
find "$here/ClayzoEngineCore.xcframework" -name "*.a" -exec strip -S -x {} \;

rm -rf "$dist"
mkdir -p "$dist"
(cd "$here" && ditto -c -k --keepParent ClayzoEngineCore.xcframework "$dist/ClayzoEngineCore.xcframework.zip")
checksum="$(cd "$dist" && swift package compute-checksum ClayzoEngineCore.xcframework.zip)"
echo "$checksum" > "$dist/checksum.txt"

sed -e "s|.binaryTarget(name: \"ClayzoEngineCore\", path: \"ClayzoEngineCore.xcframework\"),|.binaryTarget(name: \"ClayzoEngineCore\", url: \"$url\", checksum: \"$checksum\"),|" \
  "$here/Package.swift" > "$dist/Package.swift"

echo "zip       $(du -h "$dist/ClayzoEngineCore.xcframework.zip" | cut -f1)"
echo "checksum  $checksum"
echo "Package.swift written to dist/ with the binary target at $url"
