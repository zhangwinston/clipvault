# ClipVault（内部代号 Xdown）

[![CI](https://github.com/zhangwinston/clipvault/actions/workflows/ci.yml/badge.svg)](https://github.com/zhangwinston/clipvault/actions/workflows/ci.yml) [![Release](https://img.shields.io/badge/release-continuous-blue)](https://github.com/zhangwinston/clipvault/releases/tag/continuous)

## 下载安装

| 产物 | 入口 | 说明 |
|---|---|---|
| Android APK | [Releases · continuous](https://github.com/zhangwinston/clipvault/releases/tag/continuous) | Release 构建 · debug 签名，下载后直接侧载安装 |
| iOS IPA | 同上 | **未签名**，需自签（AltStore / Sideloadly / 企业证书）后安装 |

> `continuous` 标签随 main 分支每次推送滚动更新，始终是最新构建；无需登录即可下载。

X(Twitter) 视频下载 App —— Flutter 单代码库（Android + iOS），纯客户端 Syndication 解析（DESIGN 方案 A'）。

> **唯一权威契约为 [DESIGN.md](./DESIGN.md)**：数据模型 §5、解析端点/token 算法/错误七分类 §6、UI 信息架构 §7、权限合规 §8、状态管理与技术决策 §9、测试清单 §11。模块间接口以契约为准，偏离须申报。

- 商标合规：上架名 / 相册名 / 商店名统一 **ClipVault**（无 X/Twit 前缀，DESIGN §8.4）；代号 Xdown 仅存于仓库与文档。
- 合规边界：零收集零账号（纯客户端，无服务器经手用户 URL）；不绕过任何 DRM（仅处理公开可直链访问的 progressive MP4）。

---

## 一、本机验证命令

环境：Windows 11 + Git Bash + Node.js 24（v24.11.0）+ Flutter 3.47.5（Dart 3.13.4）。
**无 JDK / Android SDK / 模拟器 / macOS** —— 一切原生行为留待补装后回归（见第三节）。

```bash
# 0. 首次拉取依赖（集中验证阶段统一执行，并行开发期间勿各自运行）
flutter pub get

# 1. 静态分析（Milestone 1 判据：零 error）
#    规则 = flutter_lints + strict-casts + strict-raw-types + strict-inference
flutter analyze

# 2. 全量测试（全部离线可跑：夹具回放 + 本地 mock HttpServer + drift 内存库）
flutter test

# 3. drift 代码生成（lib/data/*.dart 的表定义 → *.g.dart）
dart run build_runner build --delete-conflicting-outputs

# 4. Node 工具链（宿主机脚本，不进 App）
node tools/token_corpus.mjs        # 生成 test/resources/token_corpus.csv（10 万级语料，seed=42 确定性可复现）
node tools/fetch_fixtures.mjs      # 端点哨兵：真实端点录制/刷新夹具 + 与旧夹具 diff；漂移或录制失败时退出码 1
node tools/check_contract.mjs      # 契约校验：fixtures ↔ contracts/resolve.schema.json ↔ contracts/error_codes.md

# 5. 宿主机 E2E 冒烟（真端点：解析 200 + 有效 token + Range 下载前 64KB 校验）
dart run bin/smoke.dart
```

### 已知环境注意点

- **宿主机跑 drift 测试缺 sqlite3.dll**：`database.dart` 的 executor 注入设计优先 `NativeDatabase.memory()`，缺 dll 时回落 `WasmDatabase` 内存库跑同样断言（DESIGN §11.1 / §12-11）。
- **token_corpus.mjs 的确定性**：固定 seed=42，重跑产出逐字节一致的 CSV；换 seed 会改变随机采样（边界向量不变）。
- **fetch_fixtures.mjs 的哨兵语义**：与旧夹具不一致即报告 DRIFT 并退出码 1（`--allow-drift` 可放行）；候选推文 ID 全部失效（删除/404）时报告 FAIL，夹具需人工合成并申报。

---

## 二、契约资产与夹具来源申报（2026-09-25 实测）

| 夹具（assets/fixtures/） | 来源 | 说明 |
|---|---|---|
| `syndication_video_ok.json` | **真实录制** | id=1790637656616943991（@historyinmemes），HLS + 3 档 MP4（288k/832k/2176k，顶档 720p） |
| `syndication_multi_video.json` | **合成** | 以真实录制响应的字段形状为模板构造 2 个 `type=video` 条目（真实多视频样本 ID 未寻得） |
| `syndication_photo_only.json` | **合成** | 真实字段形状的 2 个 `type=photo` 条目（→ E05） |
| `syndication_404_dogpage.html` | **真实录制** | id=1999999999999999999（未来雪花 ID）→ HTTP 404 + `class="dog"` 错误页 |
| `syndication_empty.json` | **真实录制** | 不带 token 请求 → HTTP 200 + 空 `{}`（DESIGN §6.1 实测行为） |
| `syndication_sensitive.json` | **合成** | 真实录制模板 + `possibly_sensitive=true`（→ E06；真实敏感样本未寻得） |
| `fxtwitter_status_ok.json` | **真实录制** | `api.fxtwitter.com/status/:id`；`videos[]` 同时含 `url` 直链、`formats[]` 多码率、`variants[]` 三形态——印证 §6.4 防御性双形态设计 |

契约文件：

- `contracts/resolve.schema.json` —— ResolveResult 信封 JSON Schema（Dart 侧 `ResolveResult` / Node 侧 check_contract 双端单一事实源）；variants 排序与 mp4-only 由两个契约测试程序化断言（schema 无法表达）。
- `contracts/error_codes.md` —— E01~E07 七类错误码 + DownloadError 契约；含 2026-09-25 实测注记（mediaDetails 可整体缺失 → E05）。

### token 语料 CSV 格式（`test/resources/token_corpus.csv`，供 core 单测解析）

```text
首行为表头：tweetId,radix36,token
tweetId  原始推文 ID 字符串（超 2^53，逐位十进制，勿转 double）
radix36  ((Number(tweetId)/1e15)*Math.PI).toString(36) 的 V8 原生输出（可含 "." 与 "0"）
token    radix36.replace(/(0+|\.)/g, '')（可为空串，如 id=0）
```

采样：1e18~2e18 雪花区间逐位十进制随机 10 万条 + 77 个边界向量（0/1/2、2^53±邻域、全 0/全 9 尾数、
进位链压力值、(id/1e15)*π 整数边界两侧探针、已知向量 1790637656616943991→4c9gcitu1vq）。

---

## 三、Android Studio / JDK 补装后的回归清单（DESIGN §11.5）

以下各项在本机（无 JDK/Android SDK/模拟器/macOS）**无法验证**，补装环境后逐项执行：

| # | 回归项 | 验证要点 | 涉及 |
|---|---|---|---|
| 1 | gal 真机入册 | `gal.putVideo(path, album: 'ClipVault')` 实际生成相册与视频；Android 29+ MediaStore 零权限写入 | §4.4 / §8.1 |
| 2 | 权限弹窗时序 | iOS `NSPhotoLibraryAddUsageDescription` 首次保存时请求；Android ≤28 WRITE_EXTERNAL_STORAGE 保存时请求；**拒绝后降级沙盒 + 历史重存入口不中断** | §8.1 / §4.4 |
| 3 | ForegroundService 通知 | P1：`FOREGROUND_SERVICE_DATA_SYNC` + flutter_local_notifications 常驻进度通知；POST_NOTIFICATIONS 拒绝不阻塞下载 | §4.3 |
| 4 | 剪贴板系统提示 | Android 12+ 剪贴板 toast、iOS 粘贴横幅出现时机与设置页解释文案 | §8.2 |
| 5 | iOS Share Extension | Xcode 添加 target 后分享面板唤起（P1 交付代码+配置文档） | §4.1-3 |
| 6 | detectPatterns 模块 | `ClipboardPatternPlugin.swift` MethodChannel 预检只探不取，规避 iOS 粘贴横幅；**真机验证前保持兜底路径** | §8.2 |
| 7 | PiP | Android 嵌画 / iOS AVPictureInPictureController；**真机验证前隐藏入口** | §4.5 |
| 8 | 后台保活行为 | 锁屏中断但断点可续；iOS ~30s 宽限自动续传 | §4.3 |
| 9 | iOS 剪贴板 changeCount 通道（2026-09-26 新增） | `AppDelegate.swift` 的 `clipvault/clipboard` 通道（UX P1-2 根治：内容未变不读文本 → 不触发系统粘贴横幅）；验证通道注册、编译与「未变化时不弹横幅」行为（本机无 macOS 未验证，随 CI IPA 构建回归） | UX-REVIEW P1-2 |
| 10 | sqlite3_flutter_libs EOL 迁移（2026-09-26 挂账） | 该包已 EOL：正确迁移是移除 `0.5.42`、依赖 sqlite3 3.x native assets 分发原生库（`0.6.0+eol` 为空壳版本，**勿直接升**）；库缺失表现为运行时 dlopen 崩溃而非构建失败，必须真机验证 DB 读写后再合入 | 依赖 |

补装步骤建议：Android Studio（含 JDK 17 + SDK 34+）→ `flutter doctor` 全绿 → 先跑第 1/2/4 项（P0 范围），P1 项随里程碑补。

> **构建版本注意（connectivity_plus 7.x）**：其 changelog 要求 Android 侧 AGP ≥ 8.12.1 / Gradle wrapper ≥ 8.13 / Kotlin 2.2.0。`flutter create` 生成的默认 android/ 模板版本较旧，首次 `flutter build apk` 前需按报错提示升级 `android/settings.gradle.kts`、`android/gradle/wrapper/gradle-wrapper.properties` 与 Kotlin 插件版本（或降级 connectivity_plus 至 6.x 并同步调整 API 调用）。本机无 Android SDK 未验证，属 §11.5 回归清单首项。

---

## 四、目录速览（完整文件级结构见 DESIGN §③）

```text
contracts/          契约单一事实源（resolve.schema.json / error_codes.md）
assets/config/      内置端点配置预设（endpoints.json，可远端热更，§6.7）
assets/fixtures/    七夹具（录制/合成来源见上表）
tools/              Node 24 宿主机脚本（token_corpus / fetch_fixtures / check_contract）
bin/smoke.dart      真端点 E2E 冒烟（P7 交付）
lib/                core 纯函数层 / parse 解析层 / download 引擎 / data 持久层 / ui …
test/               全部宿主机可跑（resources/token_corpus.csv 语料在库内）
```
