#!/bin/zsh
set -eu
cd -- "${0:A:h}"
task_bundle_id="${CODEX_QUOTA_BUNDLE_ID:-io.github.angeV587.CodexQuota}"
swift build -c release -Xswiftc -gnone
bundle="$PWD/dist/CodexQuota.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 .build/release/CodexQuota "$bundle/Contents/MacOS/CodexQuota"
cp Info.plist "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $task_bundle_id" "$bundle/Contents/Info.plist"
/usr/bin/strip -S "$bundle/Contents/MacOS/CodexQuota"
codesign --force --sign - --identifier "$task_bundle_id" "$bundle"
codesign --verify --strict "$bundle"
print -r -- "$bundle"
