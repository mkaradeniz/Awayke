#!/bin/zsh

set -euo pipefail

repo_dir="${0:A:h:h}"
team_id="${AWAYKE_TEAM_ID:-MU78QS2CA9}"
signing_identity="${AWAYKE_SIGNING_IDENTITY:-Developer ID Application}"
install_app="${AWAYKE_INSTALL_PATH:-/Applications/Awayke.app}"
task_dir="$(mktemp -d /tmp/awayke-local-install.XXXXXX)"
source_dir="$task_dir/source"
build_dir="$task_dir/build"
previous_app="$task_dir/previous-Awayke.app"
failed_app="$task_dir/failed-Awayke.app"

cleanup() {
    /bin/rm -rf "$task_dir"
}
trap cleanup EXIT

mkdir -p "$source_dir"
/usr/bin/rsync -a \
    --exclude=.git \
    --exclude=build \
    --exclude=DerivedData \
    "$repo_dir/" "$source_dir/"

helper_info="$source_dir/AwaykeHelper/Info.plist"
if ! /usr/bin/grep -q TEAM_ID_PLACEHOLDER "$helper_info"; then
    print -u2 "The helper authorization placeholder is missing."
    exit 1
fi
/usr/bin/sed -i '' "s/TEAM_ID_PLACEHOLDER/$team_id/g" "$helper_info"

xcodebuild \
    -quiet \
    -project "$source_dir/Awayke.xcodeproj" \
    -scheme Awayke \
    -configuration Release \
    -derivedDataPath "$build_dir" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    DEVELOPMENT_TEAM="$team_id" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

built_app="$build_dir/Build/Products/Release/Awayke.app"
built_helper="$built_app/Contents/MacOS/daemonphantom.Awayke.Helper"

codesign --verify --deep --strict --verbose=2 "$built_app"
codesign --verify --strict --verbose=2 "$built_helper"

for signed_path in "$built_app" "$built_helper"; do
    actual_team="$(codesign -dv --verbose=4 "$signed_path" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2}')"
    if [[ "$actual_team" != "$team_id" ]]; then
        print -u2 "Unexpected signing team for $signed_path: $actual_team"
        exit 1
    fi
done

osascript -e 'tell application id "daemonphantom.Awayke" to quit' 2>/dev/null || true
for attempt in {1..10}; do
    if ! pgrep -x Awayke >/dev/null; then
        break
    fi
    sleep 1
done
if pgrep -x Awayke >/dev/null; then
    print -u2 "Awayke did not quit cleanly."
    exit 1
fi

if [[ -e "$install_app" ]]; then
    mv "$install_app" "$previous_app"
fi

if ! ditto "$built_app" "$install_app"; then
    [[ ! -e "$install_app" ]] || mv "$install_app" "$failed_app"
    [[ ! -e "$previous_app" ]] || mv "$previous_app" "$install_app"
    exit 1
fi

if ! codesign --verify --deep --strict "$install_app"; then
    mv "$install_app" "$failed_app"
    [[ ! -e "$previous_app" ]] || mv "$previous_app" "$install_app"
    exit 1
fi

open -a "$install_app"
for attempt in {1..10}; do
    if pgrep -x Awayke >/dev/null; then
        break
    fi
    sleep 1
done
if ! pgrep -x Awayke >/dev/null; then
    mv "$install_app" "$failed_app"
    [[ ! -e "$previous_app" ]] || mv "$previous_app" "$install_app"
    open -a "$install_app" 2>/dev/null || true
    print -u2 "The local build did not start. The previous application was restored."
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$install_app/Contents/Info.plist")"
print "Installed local Awayke $version at $install_app"
