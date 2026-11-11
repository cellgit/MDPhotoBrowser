#!/usr/bin/env bash
# 出 MDPhotoBrowser.xcframework（iOS 真机 + 模拟器两片，各带 dSYM），再打一个 zip 并算出 SwiftPM 的 checksum：
# 发版时把 zip 挂到 Release 上，二进制接入的 Package.swift 用 .binaryTarget(url:checksum:) 引它。
#
# 用法：scripts/build-xcframework.sh [输出目录，默认 build]
#
# 编的是 MDPhotoBrowser.xcodeproj 里的 framework target，它和 Package.swift 同一份 Sources/MDPhotoBrowser。
# BUILD_LIBRARY_FOR_DISTRIBUTION 打开库演进、生成 .swiftinterface，换了 Swift 编译器版本的 App 也能用。
# 不签名：App 嵌入时 Xcode 会用 App 的证书重签。
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-build}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
rm -rf "$out/archives" "$out/MDPhotoBrowser.xcframework" "$out/MDPhotoBrowser.xcframework.zip"

archive() {
  echo "archive $2"
  xcodebuild archive \
    -project MDPhotoBrowser.xcodeproj \
    -scheme MDPhotoBrowser \
    -configuration Release \
    -destination "$1" \
    -archivePath "$out/archives/$2.xcarchive" \
    -derivedDataPath "$out/DerivedData" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
}

archive "generic/platform=iOS" ios
archive "generic/platform=iOS Simulator" ios-simulator

slices=()
for name in ios ios-simulator; do
  slices+=(-framework "$out/archives/$name.xcarchive/Products/Library/Frameworks/MDPhotoBrowser.framework")
  slices+=(-debug-symbols "$out/archives/$name.xcarchive/dSYMs/MDPhotoBrowser.framework.dSYM")
done
xcodebuild -create-xcframework "${slices[@]}" -output "$out/MDPhotoBrowser.xcframework"

(cd "$out" && zip -qry MDPhotoBrowser.xcframework.zip MDPhotoBrowser.xcframework)
echo "$out/MDPhotoBrowser.xcframework"
echo "$out/MDPhotoBrowser.xcframework.zip"
echo "checksum $(swift package compute-checksum "$out/MDPhotoBrowser.xcframework.zip")"
