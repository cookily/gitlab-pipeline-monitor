#!/bin/bash
# 构建 GitLab 流水线菜单栏监控应用，输出到 ~/Applications/GitLabPipelineMonitor.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GitLabPipelineMonitor"
APP_DIR="$HOME/Applications/$APP_NAME.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# 通用二进制（universal）：同一产物同时支持 Intel 与 Apple Silicon（M 系列）Mac
# swiftc 不支持 clang 式 -arch，按 target 各编一次再 lipo 合并（CLT 自带双架构 Swift 标准库）
swiftc -swift-version 5 -O -target x86_64-apple-macos12.0 -o "$APP_DIR/Contents/MacOS/$APP_NAME.x86_64" main.swift
swiftc -swift-version 5 -O -target arm64-apple-macos12.0 -o "$APP_DIR/Contents/MacOS/$APP_NAME.arm64" main.swift
lipo -create "$APP_DIR/Contents/MacOS/$APP_NAME.x86_64" "$APP_DIR/Contents/MacOS/$APP_NAME.arm64" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
rm -f "$APP_DIR/Contents/MacOS/$APP_NAME.x86_64" "$APP_DIR/Contents/MacOS/$APP_NAME.arm64"
# 必须 ad-hoc 签名：Intel Mac 链接器不会自动签名，而未签名的应用 macOS 通知系统直接无视
# （授权弹窗不出现、系统设置通知列表不收录、通知静默失败）
codesign --force --sign - "$APP_DIR"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
echo "已构建: $APP_DIR"
