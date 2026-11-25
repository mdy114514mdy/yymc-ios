#!/bin/bash
# 在 macOS 上把 Sources/App.swift 编成 YYMC.app 并打包成 unsigned .ipa
# 需要：Xcode 命令行工具（xcrun / swiftc / iphoneos SDK）
set -euo pipefail

APP_NAME=YYMC
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS=15.0

echo "== SDK: $SDK"
echo "== 编译 (arm64)"

xcrun --sdk iphoneos swiftc \
  -target "arm64-apple-ios${MIN_IOS}" \
  -O \
  -sdk "$SDK" \
  -parse-as-library \
  -framework UIKit \
  -framework WebKit \
  -framework Network \
  Sources/App.swift \
  -o "$APP_NAME"

echo "== 组装 .app"
rm -rf Payload "$APP_NAME.ipa"
mkdir -p "Payload/$APP_NAME.app"
cp "$APP_NAME" "Payload/$APP_NAME.app/$APP_NAME"
cp Info.plist "Payload/$APP_NAME.app/Info.plist"
if [ ! -d site ]; then
  echo "✗ 缺少 site/ 资源目录" >&2
  exit 1
fi
cp -R site "Payload/$APP_NAME.app/site"

echo "== 打包 ipa"
( cd Payload && zip -qry "../$APP_NAME.ipa" "$APP_NAME.app" )

echo "== 结果"
du -sh "Payload/$APP_NAME.app" || true
ls -lh "$APP_NAME.ipa"
echo "（unsigned：用 Sideloadly / AltStore 在 Windows 上签名后安装）"
