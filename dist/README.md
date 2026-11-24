# 交付产物

| 文件 / 目录 | 说明 |
|---|---|
| `RainCheck-1.0.0-unsigned.apk` | Android 客户端（Jetpack Compose Material 3 + CameraX/ZXing Core + Android Keystore AES-GCM），**真未签名**（同时不含 V1 `META-INF/*.RSA/.DSA/.EC/.SF` 与 V2/V3 `APK Sig Block 42`，且内嵌 `assets/protocol_profile.json` 与仓库 SHA-256 一致），包名 `cn.raincheck.android`，minSdk 24 / targetSdk 34 |
| `../iosApp/` | iOS 客户端源码（SwiftUI · iOS 26/27 Liquid Glass + AVFoundation + Keychain + 独立 Swift 协议引擎 + `RainCheckTests`）+ XcodeGen `project.yml`；**Windows 本机不编译 IPA**，由 `macos-26` CI 执行单测并打包未签名 IPA |
| `../cli/build/install/cli/` | JVM 命令行客户端（`parse` / `accounts` / `login` / `signin` / `context` / `probe`，支持 `--profile` 外部协议加载） |
| `../tools/mock_server.py` | 零依赖严格离线演练服务端（双载体鉴权、策略回退演练、完整扫码与验证码登录链、会话刷新） |
| `../tools/demo.py` | 跨平台 6 组全场景端到端验证脚本 |
| `../tools/check_artifacts.py` | 协议 SHA-256、JUnit XML、APK V1+V2/V3 未签名与 iOS 工程结构化校验工具 |
| `../tools/verify.ps1` | Windows 一键离线全量验收脚本 |

## 安装未签名 APK

Android 不允许直接安装未签名包，需使用自有密钥对齐并签名后安装：

```bash
# 生成本地一次性调试密钥（示例）
keytool -genkeypair -keystore raincheck-debug.jks -alias raincheck \
  -keyalg RSA -keysize 2048 -validity 3650 -storepass raincheck -keypass raincheck \
  -dname "CN=RainCheck Debug"

# 对齐 + 签名
zipalign -p -f 4 RainCheck-1.0.0-unsigned.apk RainCheck-aligned.apk
apksigner sign --ks raincheck-debug.jks --ks-pass pass:raincheck \
  --out RainCheck-signed.apk RainCheck-aligned.apk
adb install -r RainCheck-signed.apk
```

安装前可用校验工具复核未签名状态与协议版本：

```bash
python3 ../tools/check_artifacts.py apk-unsigned RainCheck-1.0.0-unsigned.apk
python3 ../tools/check_artifacts.py profile-sync --root .. --apk RainCheck-1.0.0-unsigned.apk
```

## iOS 未签名 IPA

未签名 IPA 在 macOS 或 GitHub Actions（`macos-26` runner，[`.github/workflows/ios-unsigned.yml`](../.github/workflows/ios-unsigned.yml)）上自动执行 `RainCheckTests` 单测后打包产出，完整命令见 [`../docs/BUILD.md`](../docs/BUILD.md) 第 4 节。

真机安装未签名 IPA 需自行使用开发者证书或工具重签（Xcode / AltStore / TrollStore 等），本工程不包含任何签名证书或描述文件。
