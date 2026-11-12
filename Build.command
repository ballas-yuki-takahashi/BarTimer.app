#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
trap 'printf "\nビルドに失敗しました。上のエラーを確認してください。\n"; read -r -p "Enterで閉じる"' ERR
if ! xcrun --find swiftc >/dev/null 2>&1; then
  printf 'Apple Command Line Tools が必要です。インストール後、もう一度実行してください。\n'
  xcode-select --install || true
  read -r -p 'Enterで閉じる'
  exit 1
fi
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bartimer.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/Bar Timer.app"
mkdir -p "$APP/Contents/MacOS"
ARCH="$(uname -m)"
printf 'Bar Timer をビルドしています…\n'
xcrun swiftc -swift-version 5 -O -target "${ARCH}-apple-macosx12.0" -framework AppKit -framework SwiftUI main.swift -o "$APP/Contents/MacOS/BarTimer"
"$APP/Contents/MacOS/BarTimer" --self-test
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
# Keep existing installations intact; create this app next to the source.
if [ -e 'Bar Timer.app' ]; then
  printf '既存の Bar Timer.app があります。名前を変更してから再実行してください。\n'
  exit 1
fi
mv "$APP" './Bar Timer.app'
open './Bar Timer.app'
printf '完了。次回からは Bar Timer.app をダブルクリックしてください。\n'
