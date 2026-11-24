# 构建与验证

## 0. 本机实测与工具链环境

| 组件 | 推荐版本 / 说明 |
|---|---|
| OS | Windows 10/11 / Windows Server（本地验证）或 Linux / macOS（CI） |
| JDK | JDK 17 或 JDK 21（`tools/verify.ps1` 优先复用现有 `JAVA_HOME` 或 `PATH` 中的 `java`，仅在未配置时才尝试默认本机兜底路径） |
| Gradle | 8.11.1（通过项目自带 `./gradlew` / `.\gradlew.bat` 运行） |
| Android SDK | Platform 34 + Build-Tools 34.0.0（本地通过 `local.properties` 配置 `sdk.dir`，CI 自动清理并由 `setup-android` 接管） |
| Kotlin / Compose | Kotlin 2.0.21 + Kotlin Compose Compiler Plugin + AGP 8.7.3 |
| Python | Python 3.10+（仅使用标准库，零第三方依赖，用于 `mock_server.py`、`demo.py`、`check_artifacts.py`） |
| Xcode（iOS 专用） | Xcode 26/27（iOS 26/27 Liquid Glass SDK，macOS / GitHub Actions `macos-26` runner） |

---

## 1. 协议一致性与核心单测

```powershell
cd work\raincheck

# 校验 protocol/profile.json 与 Android/iOS 源码副本逐字节一致
python tools\check_artifacts.py profile-sync --root .

# 强制重跑协议引擎与 CLI 单元测试（不使用 Gradle 缓存跳过）
.\gradlew.bat :core:jvmTest --rerun :cli:test --rerun --console=plain

# 解析 JUnit XML 报告，断言测试总数达标且 0 失败 0 跳过
python tools\check_artifacts.py junit-xml --dir core\build\test-results\jvmTest --min-tests 20
python tools\check_artifacts.py junit-xml --dir cli\build\test-results\test --min-tests 4
```

---

## 2. CLI 构建与全场景离线端到端演练

```powershell
# 构建 CLI 发行包并校验 cli.jar 内嵌 profile.json SHA-256
.\gradlew.bat :cli:installDist --console=plain
python tools\check_artifacts.py profile-sync --root . --check-cli-jar

# 运行 6 组完整端到端验证（自动在临时目录写日志，不污染 tools/ 目录）
python tools\demo.py
```

`tools/demo.py` 跨平台自动选择可执行文件（Windows 选 `cli.bat`，Linux/macOS 选 `cli`），自动拉起开启严格校验的 `tools/mock_server.py`（`--require-ticket --reject-source-14 --strict-headers --strict-csrf --refresh-session`）并依次断言：

1. **Mock 协议严格性自检**：非法 JSON 返回 400、缺业务 Header 返回 400、省略签名 `s` 必拒、Cookie POST 缺 `X-CSRFToken` 返回 403；
2. **8 账号并发 + 真实策略回退 + 会话回填**：预签到 `u1001`、`u1002` 走 Cookie+CSRF，断言 `POST /api/v3/lesson/checkin == 16`（`source=14` × 8 + `source=5` × 8）、严格分布 `SUCCESS == 7` 且 `ALREADY == 1`、8 账号全部吸收新 `set-auth`/`Set-Cookie` 并通过 `basic-info` 复验；
3. **401 失效账号**：精准判定 `AUTH_REQUIRED`；
4. **过期二维码**：在第 1 策略立即中止（`TICKET_EXPIRED`，增量仅 1 次请求）；
5. **`--dry-run` 演练模式**：`/api/*` 请求增量严格为 `0`，输出 `DRY_RUN` 轨迹；
6. **完整扫码登录链 + 4 位验证码登录链**：`pre-info` → `admin/scan(scanned/confirmed/need_code)` → `poll`/`login-with-code` → `basic-info` 200 全链路闭环。

独立使用 CLI 示例：

```powershell
$cli = "cli\build\install\cli\bin\cli.bat"
& $cli parse "c=abc&t=1763900000&s=sig&v=2"
& $cli accounts list
& $cli signin --qr "@qr.txt" --concurrency 8 --dry-run --json report.json
& $cli signin --qr "@qr.txt" --profile custom-profile.json --concurrency 8
```

> 命令行中二维码若包含 `&`，请使用 `@文件` 或加双引号避免被 Shell 截断。添加 Token 时优先使用 `--token-stdin` 或环境变量 `RAINCHECK_TOKEN`，避免凭据留在命令行历史中。

---

## 3. Android 未签名 APK 构建与校验

Android 端已全面重写为 **Jetpack Compose Material 3 + CameraX/ZXing Core + Android Keystore AES-GCM 加密存储**，且 `release` 刻意不配置 `signingConfig`：

```powershell
.\gradlew.bat :androidApp:assembleRelease --console=plain

# 精确校验未签名产物：同时扫描 V1 (META-INF/*.RSA/.DSA/.EC/.SF) 与 V2/V3 (APK Sig Block 42)
python tools\check_artifacts.py apk-unsigned androidApp\build\outputs\apk\release\androidApp-release-unsigned.apk

# 校验 APK 内嵌 assets/protocol_profile.json 与 protocol/profile.json 逐字节一致
python tools\check_artifacts.py profile-sync --root . --apk androidApp\build\outputs\apk\release\androidApp-release-unsigned.apk
```

- 产物路径：`androidApp/build/outputs/apk/release/androidApp-release-unsigned.apk`
- 归档副本：`dist/RainCheck-1.0.0-unsigned.apk`
- 如需安装到真机，请先自行签名（`zipalign` + `apksigner sign`，参见 [`dist/README.md`](../dist/README.md)）；`debug` 变体使用 AGP 默认调试密钥仅供本地 `adb` 调试。
- CI 流水线见 [`.github/workflows/android-unsigned.yml`](../.github/workflows/android-unsigned.yml)（`ubuntu-latest`，包含协议校验、`:core:jvmTest --rerun`、`demo.py`、APK 构建及 V1+V2/V3 未签名门禁）。

---

## 4. iOS（Liquid Glass）单测与未签名 IPA 构建

iOS 端采用 **SwiftUI · iOS 26/27 液态玻璃（Liquid Glass）** 设计系统，使用独立原生 Swift 协议引擎、Keychain 安全存储与 `RainCheckTests` XCTest 靶标。Windows 本机仅执行结构化工程校验（不编译 IPA），macOS / CI 构建步骤如下：

```bash
# 1) 严格校验协议副本一致（不一致直接失败）与工程配置
cd work/raincheck
cmp -s protocol/profile.json iosApp/Resources/protocol_profile.json
python3 tools/check_artifacts.py ios-project --ios-dir iosApp

# 2) 生成 Xcode 工程
brew install xcodegen
cd iosApp
xcodegen generate

# 3) 在 iOS Simulator 上执行 RainCheckTests 单元测试
#    （arm64 Simulator 运行 TEST_HOST 需零证书本地 Ad-Hoc 签名，使用独立 build-sim 目录不影响后续未签名 Release 包）
xcodebuild test \
  -project RainCheck.xcodeproj \
  -scheme RainCheck \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -derivedDataPath build-sim \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="-" AD_HOC_CODE_SIGNING_ALLOWED=YES

# 4) 构建未签名 Release .app 并打包为未签名 IPA
xcodebuild \
  -project RainCheck.xcodeproj \
  -scheme RainCheck \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP_PATH="build/Build/Products/Release-iphoneos/RainCheck.app"
test ! -e "$APP_PATH/_CodeSignature"
rm -rf Payload RainCheck-unsigned.ipa
mkdir -p Payload && cp -R "$APP_PATH" Payload/RainCheck.app
zip -qry RainCheck-unsigned.ipa Payload
```

- **GitHub Actions CI**：[`.github/workflows/ios-unsigned.yml`](../.github/workflows/ios-unsigned.yml) 运行于 **`macos-26`** runner（支持 Xcode 26/27 与 iOS 26/27 Liquid Glass SDK，已替换退役的 `macos-14`），自动执行 `cmp -s` 协议校验、`RainCheckTests` 模拟器单测、未签名 `.app` 构建、零 `_CodeSignature` 校验并上传 `RainCheck-unsigned.ipa` artifact。
- 真机安装未签名 IPA 需自行使用开发者证书或工具重签（Xcode / AltStore / TrollStore 等），本工程不包含任何证书或描述文件。

---

## 5. Windows 一键离线验收

```powershell
# 完整验收（协议同步 → 单测 XML 断言 → CLI & jar 校验 → 6 组 E2E 演练 → 未签名 APK V1+V2/V3 校验 → iOS 工程结构校验 → 工作区无脏日志）
powershell -NoProfile -File tools\verify.ps1

# 常用参数
powershell -NoProfile -File tools\verify.ps1 -SkipAndroid   # 跳过 Android APK 编译
powershell -NoProfile -File tools\verify.ps1 -SkipDemo      # 跳过端到端演练
powershell -NoProfile -File tools\verify.ps1 -UpdateDist    # 验收通过后同步更新 dist/RainCheck-1.0.0-unsigned.apk
powershell -NoProfile -File tools\verify.ps1 -Port 18787    # 指定隔离演练端口
```

---

## 6. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `端口 127.0.0.1:8787 已被占用` | 本机已有旧服务监听 8787；关闭旧进程、改用 `--port 18787`，或确认目标就是演练服后加 `--no-server` |
| `Could not GET ... (bad_record_mac) Tag mismatch` | 网络代理或安全软件干扰 TLS 握手；重跑一次 Gradle 命令即可续传缓存 |
| `adb install` 报 `INSTALL_PARSE_FAILED_NO_CERTIFICATES` | 安装的是未签名发布包，请先按 `dist/README.md` 自行签名 |
| CLI 输出中文乱码 | Windows 终端若为 GBK（代码页 936），请先执行 `chcp 65001` |
| 演练提示账号池为空 | 检查 `--store` 参数指向的文件路径，运行 `accounts list` 确认 |
