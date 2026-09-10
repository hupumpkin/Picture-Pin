#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/DesignPeek Draft.app"

cd "$project_dir"
swift build -c release

mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/.build/release/DesignPeekDraft" "$app_dir/Contents/MacOS/DesignPeekDraft"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"

echo "$app_dir"
