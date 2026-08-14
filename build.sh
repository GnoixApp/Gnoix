#!/bin/bash

# 晚风TV iOS应用构建脚本
# 使用方法: ./build.sh [clean|build|run|test]

set -euo pipefail

PROJECT_NAME="WFTVIOS"
SCHEME_NAME="WFTVIOS"
DESTINATION="generic/platform=iOS"
RUN_DEVICE_NAME="iPhone 16"
WORKSPACE_PATH="${PROJECT_NAME}.xcworkspace"
BUILD_CONFIGURATION="Release"

resolve_build_settings() {
    local settings
    settings="$(xcodebuild -showBuildSettings -workspace "$WORKSPACE_PATH" -scheme "$SCHEME_NAME" -configuration "$BUILD_CONFIGURATION" -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>/dev/null)"

    APP_BUNDLE_ID="$(echo "$settings" | awk -F' = ' '/PRODUCT_BUNDLE_IDENTIFIER = / {print $2; exit}')"
    BUILT_PRODUCTS_DIR="$(echo "$settings" | awk -F' = ' '/BUILT_PRODUCTS_DIR = / {print $2; exit}')"
    FULL_PRODUCT_NAME="$(echo "$settings" | awk -F' = ' '/FULL_PRODUCT_NAME = / {print $2; exit}')"
    APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

    if [[ -z "${APP_BUNDLE_ID:-}" || -z "${APP_PATH:-}" ]]; then
        echo "❌ 无法解析构建产物信息，请检查 Scheme/Workspace 配置"
        exit 1
    fi
}

echo "🎬 晚风TV iOS应用构建脚本"
echo "================================"

case "${1:-ipa}" in
    "clean")
        echo "🧹 清理项目..."
        xcodebuild clean -workspace "$WORKSPACE_PATH" -scheme "$SCHEME_NAME"
        echo "✅ 清理完成"
        ;;
    "build")
        echo "🔨 构建项目..."
        xcodebuild build -workspace "$WORKSPACE_PATH" -scheme "$SCHEME_NAME" -configuration "$BUILD_CONFIGURATION" -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
        echo "✅ 构建完成"
        ;;
    "ipa")
        echo "📦 构建并打包 IPA..."
        xcodebuild build -workspace "$WORKSPACE_PATH" -scheme "$SCHEME_NAME" -configuration "$BUILD_CONFIGURATION" -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
        resolve_build_settings
        if [[ ! -d "$APP_PATH" ]]; then
            echo "❌ 构建产物不存在: $APP_PATH"
            exit 1
        fi
        
        OUTPUT_DIR="./build_output"
        IPA_PATH="./WFTVIOS.ipa"
        rm -rf "$OUTPUT_DIR" "$IPA_PATH"
        mkdir -p "$OUTPUT_DIR/Payload"
        cp -R "$APP_PATH" "$OUTPUT_DIR/Payload/"
        
        cd "$OUTPUT_DIR"
        zip -q -r "../WFTVIOS.ipa" Payload
        cd ..
        rm -rf "$OUTPUT_DIR"
        
        echo "🎉 IPA打包完成: $(pwd)/WFTVIOS.ipa"
        ;;
    "run")
        echo "🚀 运行项目(模拟器)..."
        DEST_SIM="platform=iOS Simulator,name=${RUN_DEVICE_NAME}"
        xcodebuild build -workspace "$WORKSPACE_PATH" -scheme "$SCHEME_NAME" -configuration "Debug" -destination "$DEST_SIM"
        
        sim_settings="$(xcodebuild -showBuildSettings -workspace "$WORKSPACE_PATH" -scheme "$SCHEME_NAME" -configuration "Debug" -destination "$DEST_SIM" 2>/dev/null)"
        SIM_APP_PATH="$(echo "$sim_settings" | awk -F' = ' '/BUILT_PRODUCTS_DIR = / {print $2; exit}')/$(echo "$sim_settings" | awk -F' = ' '/FULL_PRODUCT_NAME = / {print $2; exit}')"
        SIM_BUNDLE_ID="$(echo "$sim_settings" | awk -F' = ' '/PRODUCT_BUNDLE_IDENTIFIER = / {print $2; exit}')"

        xcrun simctl boot "$RUN_DEVICE_NAME" 2>/dev/null || true
        xcrun simctl bootstatus "$RUN_DEVICE_NAME" -b
        xcrun simctl install "$RUN_DEVICE_NAME" "$SIM_APP_PATH"
        xcrun simctl launch "$RUN_DEVICE_NAME" "$SIM_BUNDLE_ID"
        echo "✅ 应用已在模拟器启动"
        ;;
    "test")
        echo "🧪 运行测试..."
        xcodebuild test -workspace "$WORKSPACE_PATH" -scheme "$SCHEME_NAME" -configuration "$BUILD_CONFIGURATION" -destination "$DESTINATION"
        echo "✅ 测试完成"
        ;;
    *)
        echo "使用方法: $0 [clean|build|ipa|run|test]"
        echo ""
        echo "命令说明:"
        echo "  ipa    - 构建并打包生成 SideStore/AltStore 安装用的 IPA 文件"
        echo "  build  - 构建项目"
        echo "  clean  - 清理项目构建文件"
        echo "  run    - 构建并在模拟器中运行项目"
        echo "  test   - 运行项目测试"
        echo ""
        echo "示例:"
        echo "  $0 ipa    # 生成可安装的 .ipa 文件"
        echo "  $0 build  # 仅构建"
        ;;
esac 
