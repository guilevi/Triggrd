#!/bin/sh
# Rebuilds the bundled triggrd-system binary (universal: Apple silicon + Intel).
# Only needed after editing triggrd-system.swift; requires the Xcode command
# line tools. The spoon ships with the binary already built.
#
#   build.sh                                   ad-hoc signed only
#   build.sh --sign "Developer ID Application: Name (TEAMID)" [--notary-profile PROFILE]
#
# Always writes unsigned/triggrd-system, ad-hoc signed, for anyone who wants to
# sign it with their own certificate. triggrd-system (what the installer uses)
# is that same build, or with --sign, signed with the given Developer ID
# (hardened runtime, secure timestamp) and, with --notary-profile, notarized
# via `xcrun notarytool` using that keychain profile.
#
# Unsigned/ad-hoc builds work fine when built locally. If the spoon is
# downloaded, though, macOS quarantines its files and may refuse to run an
# unnotarized service, and "Background item added" names no developer.
set -e
cd "$(dirname "$0")"

identity=""
profile=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) identity="$2"; shift 2 ;;
        --notary-profile) profile="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swiftc -O -target arm64-apple-macos12 -o "$tmp/arm64" triggrd-system.swift
swiftc -O -target x86_64-apple-macos12 -o "$tmp/x86_64" triggrd-system.swift
lipo -create -output "$tmp/triggrd-system" "$tmp/arm64" "$tmp/x86_64"

mkdir -p unsigned
cp "$tmp/triggrd-system" unsigned/triggrd-system
codesign --force --sign - unsigned/triggrd-system

if [ -z "$identity" ]; then
    cp unsigned/triggrd-system triggrd-system
    echo "Built triggrd-system (ad-hoc signed)."
    exit 0
fi

cp "$tmp/triggrd-system" "$tmp/signed"
codesign --force --options runtime --timestamp --identifier com.triggrd.system \
    --sign "$identity" "$tmp/signed"

if [ -n "$profile" ]; then
    # A bare executable can't be stapled; Gatekeeper looks the ticket up online.
    ditto -c -k "$tmp/signed" "$tmp/signed.zip"
    xcrun notarytool submit "$tmp/signed.zip" --keychain-profile "$profile" --wait \
        | tee "$tmp/notary.log"
    grep -q "status: Accepted" "$tmp/notary.log" || { echo "Notarization failed." >&2; exit 1; }
fi

cp "$tmp/signed" triggrd-system
echo "Built triggrd-system (signed by $identity${profile:+, notarized})."
