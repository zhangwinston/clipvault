# Xdown 最终架构设计文档

> 项目：X(Twitter) 视频下载工具移动 App（内部代号 Xdown；上架名见 §8.4）
> 定稿依据：《Xdown-PRD.md》+ 四方案竞标 + 三视角评审（2026-09-25）
> 开发环境硬约束：Windows 11 + Git Bash + Node.js 24（v24.11.0）+ Flutter 3.47.5（D:/Program/flutter）；**无 JDK / Android SDK / 模拟器 / macOS**。质量验证闭环 = `flutter analyze` + `flutter test`（宿主机 VM），辅以 Node 24 工具脚本与 `bin/smoke.dart` 真端点冒烟。Dart 业务层保持 iOS/Android 双平台兼容。
> 项目根目录：`D:/Program/xdown/`

---

## ① 选型结论与理由

### 1.1 评分摘要表

| 方案 | PRD 覆盖度 | 工程可行性 | 产品与合规 | 平均 | 结论 |
|---|---|---|---|---|---|
| **P1：Flutter + 纯客户端 Syndication 解析（PRD 4.1 方案 A）** | **9** | **9** | **9** | **9.0** | **胜出，定稿主体** |
| P2：Flutter 极薄客户端 + Node 自建解析后端 | 7.2 | 6 | 8 | 7.1 | 落选，吸收 6 项设计 |
| P3：React Native bare + 混合解析 | 8.3 | 5.5 | 7 | 6.9 | 落选，吸收 3 项设计 |
| P4：原生双端（Kotlin/Compose + Swift/SwiftUI） | 6.5 | 3.5 | 7.5 | 5.8 | 落选，仅作基准参照 |

### 1.2 胜出理由

1. **唯一经三视角评委独立复现 100% 成立的方案**：token 算法（与 yt-dlp master 源码 `_generate_syndication_token` 逐字一致）、无 token 返回空 `{}`、服务端宽松校验、`variants` 无分辨率字段需 URL 正则、`video.twimg.com` 直链 Range 206 支持——全部实测通过。
2. **验证闭环与环境完全咬合**：核心逻辑（token 移植 / URL 提取 / 解析映射 / 下载引擎 / 持久化 / UI）全部落在 `flutter analyze + flutter test` 可达范围；夹具回放 + 本地 mock HttpServer + drift 内存库 + widget 测试 + 宿主机 `bin/smoke.dart` E2E 冒烟，是 Dart 可跑 CLI 的独有红利。P4 在本环境零编译验证闭环（评委 2 裁决"可设计不可落地"），P3 自认盲区更大且 UI 层零测试规划。
3. **依赖零编造零过气**：dio 5.11.1 / flutter_riverpod 3.4.3 / drift 2.35.0 / gal 2.3.3 / receive_sharing_intent 1.9.0 / video_player 2.14.0 全部经评委核对 pub.dev 属实且活跃；弃选判断（isar 停更且 SDK<3.0、image_gallery_saver 停更、ffmpeg_kit_flutter DISCONTINUED 且二进制撤库）亦全部属实。
4. **合规叙事最干净**：纯客户端架构使"零收集零账号"真实可兑现（无服务器经手用户 URL）；权限最小化且是唯一给出权限被拒完整降级路径的方案；NSFW 双保险（PRD 话术 + 不载缩略图）最利于年龄分级。
5. **P2 的"极薄客户端"名不副实**（评委 2 裁决）：其降级路径要求客户端内置完整同源 Syndication 解析（即 P1 全部难点）再叠加后端/代理池/规则中心，工作量是 P1 超集而非减法；生产核心面（guard/proxy）在本机不可验证不可运维，个人工具承担基础设施成本不成立。

### 1.3 对 P1 全部扣分点的逐条回应

| # | 评委扣分点 | 处置（修正 → 落位章节 / 接受 → 风险章节） |
|---|---|---|
| 1 | HLS 合成（PRD 3.3 明确条款）推迟 P2 且条件立项 | **接受并说明**（§12.9）：三重依据——实测全样本 MP4 与 HLS 并存、ffmpeg_kit_flutter 官方停运且二进制已从 Maven/CocoaPods 撤库、活跃分叉 ffmpeg_kit_flutter_new 为 Full-GPL 且 +30~60MB。产品上 P0 仅出 MP4 档不损失主流程；仅当实测出现 m3u8-only 片源才立项。 |
| 2 | 选 PRD 4.1 方案 A（推荐度"中"）而非推荐的 B | **接受并增强为 A'**（§6.7、§12.12）：方案 B 的服务器带宽、出口 IP 限频、代理池持续运营开支对个人工具不可成立（评委 2 裁决）。本设计把"端点/token 算法版本/UA/超时"外置为可远端下发的 endpoints 配置（吸收 P2/P4），使 X 接口小变更不必发版；解析器做成可替换接口 `TweetParser`，预留升级到方案 C/B 的切换点。 |
| 3 | token 语料单测是"Node 同公式生成语料对照 Dart"的自我印证 | **修正**（§11.1）：语料由 Node 的 **V8 引擎原生 `Number.prototype.toString(36)`** 生成——端点算法本身即 JS 语义，V8 就是该算法的参考实现，并非 Dart 同公式自我对照；再叠加 `bin/smoke.dart` 真端点放行验证与边界值向量人工核对，构成三重验证。 |
| 4 | 剪贴板"浮窗"（PRD 措辞）改为内联横幅 | **接受**：横幅打扰最小，点击升级为 BottomSheet 已在交互流中定义；同时吸收 P3 的 iOS `UIPasteboard.detectPatterns` 预检（§8.2），降低粘贴横幅触发面。 |
| 5 | 相册名"X-Downloads"含 X 字样，与商标规避策略自相矛盾且未自我察觉 | **修正**：上架名与相册名统一改为中性名 **ClipVault**（无 X/Twit 前缀，§8.4）；"X-Downloads"仅作为 PRD 原文建议留档。 |
| 6 | 免责声明无条款版本化机制 | **修正**（吸收 P2，§8.3）：`disclaimerVersion` + `acceptedAt` 持久化，条款升级需重新确认。 |
| 7 | 商店名策略只说规避、未指出项目代号/PRD 示例名本身的商标风险 | **修正**（吸收 P2/P4，§8.4）：明示"Xdown"代号含 X、"TwitSaver"含 Twit 前缀均有风险，采用 ClipVault。 |
| 8 | 解析等待态（骨架屏）未设计 | **修正**（吸收 P2，§7.2）：解析中骨架卡片 + 耗时计时器。 |
| 9 | `toString(36)` IEEE754 精确移植是高风险自研资产 | **接受**（§12.2）：10 万级语料穷举 + 边界值 + 真端点对账兜底；服务端当前宽松放行为最后防线（明确不作依赖）。 |
| 10 | 原生侧（gal 入册 / ForegroundService / iOS Share Extension）无法本机验证 | **接受**（§12.3）：该盲区为四方案所共有；本设计将原生面压到最小（全插件、除 iOS detectPatterns 小模块外零自研原生代码），交付配置文档与装 Android Studio 后的回归清单。 |

### 1.4 从落选方案吸收的亮点（评委明确肯定项）

| 来源 | 亮点 | 本设计落位 |
|---|---|---|
| P2 | 免责条款版本化（更新条款需重新确认） | §8.3、`settings_controller.dart` |
| P2 | "解析中骨架卡片 + 耗时计时"等待体验 | §7.2、`ui/common/parse_skeleton.dart` |
| P2 | 错误码契约层 + fixtures 双向断言纪律 | §6.6、`contracts/` + `test/parse/contract_test.dart` |
| P2/P4 | 端点参数外置为可热更配置（endpoints.json / 远端 rules） | §6.7、`parse/endpoint_config.dart` + `assets/config/endpoints.json` |
| P3 | 1.8s 指标的预算拆解（网络 0.8s / 映射 <0.1s / UI <0.3s / 余量 0.6s） | §6.8 |
| P3 | 429 触发全队列 30s 冷却 | §4.3、`download_engine.dart` |
| P3 | iOS `UIPasteboard.detectPatterns` 剪贴板预检 | §8.2（原生小模块，真机验证后启用） |
| P3 | 深色模式跟随系统、文案收口 i18n | §7.1、`core/app_strings.dart` |
| P4 | 权限论证："READ_MEDIA_VIDEO 完全不需要"（纠正 PRD 4.2-3 过度索取） | §8.1 |
| P4 | 错误分类精细度（429 独立降级路径、EndpointDrift 驱动配置热更） | §6.6 |
| P4 | Node 探针脚本常规化（端点漂移每日哨兵） | §11.4、`tools/fetch_fixtures.mjs` |
| 评委裁决 | fxtwitter 备选必须按官方 `/status/:id` 路径防御性重写（P2 描述的结构两评委核查结论矛盾，不可采信） | §6.9 |

**明确规避的负面项**（评委点名，不得进入实现）：
- P2"审核期可指向受限模式"——本设计无后端，不存在该手段；
- P3 的 `READ_MEDIA_VIDEO` 索取理由（与其"缩略图走 URL 直接渲染"自相矛盾）——不申请该权限；
- P3"403 一律归锁推"的误导性归因——403 在解析语境归 `RateLimited`（风控/限频），在下载语境 = 直链签名过期、自动重解析刷新（§4.3）；
- P4 的 Googlebot UA 伪装——评委实测默认 UA + 正确 token 即 200，伪装无必要且徒增 ToS/商店风险，统一用普通浏览器 UA。

---

## ② 总体架构图

```text
┌───────────────────────────────────────────────────────────────────────────┐
│                     ClipVault（Flutter 单代码库，iOS / Android）             │
│                                                                           │
│  ┌─ UI 层（Material 3，深色模式跟随系统，flutter_riverpod 3 驱动）─────────┐  │
│  │  首页 Home        清晰度 Sheet      下载 Downloads    我的 Settings     │  │
│  │  （输入/横幅/      （预览卡+变体     （进行中/队列/    （免责重看/偏好/    │  │
│  │   骨架等待）        降序列表）        失败/历史）       缓存清理）         │  │
│  │  首启免责闸门 · 播放页 Player(P1) · 七类错误一物一视图                    │  │
│  └────────────────────────────┬────────────────────────────────────────┘  │
│                    ProviderContainer（AsyncNotifier / StreamProvider）      │
├───────────────────────────────────────────────────────────────────────────┤
│  业务层（Dart，零 platform import；原生能力全部隔离在接口 + 薄适配文件）      │
│                                                                           │
│  输入                解析                         下载            持久化     │
│  ┌────────────┐    ┌────────────────────┐    ┌────────────┐  ┌──────────┐ │
│  │url_extract │    │ TweetParser(可替换) │    │DownloadEngine│ │HistoryRepo│ │
│  │clipboard_  │───▶│ ├SyndicationParser ├─▶ │ FIFO队列+信号量│ │ drift/    │ │
│  │ watcher    │    │ │ (主源，tweet-     │   │ (并发2,Range  │ │ SQLite    │ │
│  │share_      │    │ │  result+token)   │   │ 续传+退避3次  │ │ Stream查询│ │
│  │ receiver   │    │ └FxTwitterParser   │   │ +429全队列冷却│ │ 启动恢复   │ │
│  │(P1)        │    │   (备源，降级)      │   ├────────────┤  └──────────┘ │
│  └────────────┘    │ EndpointConfig     │   │GallerySaver │   设置         │
│                    │ (外置可热更，§6.7)  │   │ (gal→相册)   │   shared_     │
│                    └────────────────────┘    │CacheCleaner  │   preferences │
│                                              │ (P2 自动清理) │               │
│  core：js_number_radix36 · token · backoff · sealed ParseError · app_strings│
├───────────────────────────────────────────────────────────────────────────┤
│  平台插件层（原生面最小化）                                                 │
│  dio · gal · receive_sharing_intent(P1) · video_player(P1)                 │
│  flutter_local_notifications(P1) · shared_preferences · drift(+sqlite3)    │
│  iOS detectPatterns MethodChannel 小模块（P1，真机验证后启用，§8.2）         │
└───────────────────────────────────────────────────────────────────────────┘
      │ ① HTTPS 单次往返（解析，6s 超时）         │ ② HTTPS Range（直链分片下载）
      ▼                                          ▼
  cdn.syndication.twimg.com/tweet-result     video.twimg.com/*.mp4?tag=14
  api.fxtwitter.com/status/{id}（备选降级）

  宿主机工具链（Node 24，不进 App）：
  tools/token_corpus.mjs（V8 参考实现语料）· tools/fetch_fixtures.mjs（端点哨兵）
  tools/check_contract.mjs（契约校验）· bin/smoke.dart（真端点 E2E 冒烟）
```

解析链只有一次 HTTPS 往返（实测本机冷请求亚秒级，JSON 约 3-6KB），无 guest token 链式请求——这是 PRD "≤1.8s" 指标的结构性前提。下载流量客户端直连 CDN，不经任何自有服务。

---

## ③ 项目目录结构（文件级）

```text
D:/Program/xdown/
├── DESIGN.md                          # 本文档
├── README.md                          # 本机验证命令、Android Studio 补装与回归指引
├── pubspec.yaml                       # 依赖锁定 + assets/fixtures 声明
├── analysis_options.yaml              # flutter_lints + strict-casts + strict-inference
├── contracts/                         # 前后端/模块间共享契约（单一事实源）
│   ├── resolve.schema.json            # ResolveResult JSON Schema（§6.6）
│   └── error_codes.md                 # 七类错误码契约（码值/语义/UI 动作）
├── assets/
│   ├── config/
│   │   └── endpoints.json             # 内置端点配置预设 v1（§6.7）
│   └── fixtures/                      # 真实端点录制夹具（测试回放 + 哨兵对账）
│       ├── syndication_video_ok.json        # 单视频推文（全 variants）
│       ├── syndication_multi_video.json     # 多视频推文（mediaDetails 2 个 video）
│       ├── syndication_photo_only.json      # 纯图推文（→ NotVideoTweet）
│       ├── syndication_404_dogpage.html     # 404 dogpage HTML（→ TweetNotFound）
│       ├── syndication_empty.json           # 200 + 空 {}（无 token 行为）
│       ├── syndication_sensitive.json       # possibly_sensitive（→ RestrictedContent）
│       └── fxtwitter_status_ok.json         # 备选源样本（防御性结构，§6.9）
├── tools/                             # Node 24 脚本（宿主机，不进 App）
│   ├── token_corpus.mjs               # V8 原生 toString(36) 生成 10 万级语料 CSV
│   ├── fetch_fixtures.mjs             # 拉真实端点刷新夹具 + 与旧夹具 diff（漂移哨兵）
│   └── check_contract.mjs             # fixtures 对 contracts/resolve.schema.json 校验
├── bin/
│   └── smoke.dart                     # 宿主机 E2E 冒烟：真端点解析 + Range 下载前 64KB 校验
├── lib/
│   ├── main.dart                      # 入口：ProviderScope、ImageCache 30MB 上限、首启免责闸门
│   ├── app.dart                       # MaterialApp、3 Tab 骨架、主题（亮/暗）
│   ├── core/
│   │   ├── js_number_radix36.dart     # ECMAScript Number::toString(36) 的 Dart 精确移植（核心资产）
│   │   ├── token.dart                 # getToken(id)：double 舍入 + radix36 + 剥离非 [a-z]
│   │   ├── url_extract.dart           # x.com/twitter.com/t.co 归一化、tweetId 提取（纯函数）
│   │   ├── error.dart                 # sealed ParseError 七类 + DownloadError
│   │   ├── backoff.dart               # 指数退避（800ms×2^n+抖动，3 次）
│   │   └── app_strings.dart           # 全部用户可见文案收口（含 PRD 指定话术）
│   ├── parse/
│   │   ├── models.dart                # TweetMeta / VideoVariant / ResolveResult
│   │   ├── endpoint_config.dart       # 端点配置：内置加载 + 远端拉取 + 原子替换
│   │   ├── syndication_client.dart    # dio 单次 GET，6s 超时，版本守卫
│   │   ├── syndication_parser.dart    # JSON→模型：遍历 mediaDetails，TweetParser 主实现
│   │   └── fxtwitter_parser.dart      # TweetParser 备选实现（防御性结构）
│   ├── download/
│   │   ├── download_task.dart         # 任务实体与状态机
│   │   ├── download_engine.dart       # 队列+信号量(2)+Range 续传+速度/ETA+退避+429 冷却
│   │   └── gallery_saver.dart         # gal.putVideo 封装 + 权限时序 + 被拒降级
│   ├── data/
│   │   ├── tables.dart                # drift 表：download_records
│   │   ├── database.dart              # drift 数据库（executor 注入，测试用内存库）
│   │   └── history_repository.dart    # Stream 查询 + 启动恢复未完成任务
│   ├── clipboard/
│   │   └── clipboard_watcher.dart     # didChangeAppLifecycleState(resume) + 横幅去重
│   ├── sharing/
│   │   └── share_receiver.dart        # receive_sharing_intent（P1）
│   ├── player/
│   │   └── player_screen.dart         # video_player 封装、全屏/手势（P1）
│   ├── settings/
│   │   └── settings_controller.dart   # 免责版本化 + P2 偏好 + 缓存清理策略
│   └── ui/
│       ├── home/home_screen.dart      # 输入框+粘贴+剪贴板横幅+解析按钮+骨架等待
│       ├── sheet/quality_sheet.dart   # 清晰度 BottomSheet（降序/码率/预估体积/MP4）
│       ├── downloads/downloads_screen.dart  # 进行中/队列/失败/历史 分区
│       ├── downloads/task_tile.dart   # 单任务行：进度/速率/ETA/操作
│       ├── history/history_screen.dart      # 历史详情操作（P1 完整）
│       ├── settings/settings_screen.dart    # 我的 Tab
│       └── common/
│           ├── disclaimer_dialog.dart # 首启《使用协议》闸门（版本化）
│           ├── error_views.dart       # 七类错误一物一视图
│           ├── preview_card.dart      # 推文预览卡（头像/正文/缩略图/时长）
│           └── parse_skeleton.dart    # 解析中骨架卡片 + 耗时计时
├── test/                              # 全部宿主机 flutter test 可跑（§11）
│   ├── core/js_radix36_test.dart      # 对照 token_corpus 语料逐条断言
│   ├── core/token_test.dart           # getToken 端到端 + 已知向量
│   ├── core/url_extract_test.dart
│   ├── core/backoff_test.dart
│   ├── parse/syndication_parser_test.dart   # 夹具回放七场景
│   ├── parse/fxtwitter_parser_test.dart
│   ├── parse/endpoint_config_test.dart
│   ├── parse/contract_test.dart       # fixtures ↔ resolve.schema.json 契约断言
│   ├── download/download_engine_test.dart   # 本地 HttpServer mock 全场景
│   ├── data/history_repository_test.dart    # drift 内存库
│   ├── ui/home_screen_test.dart
│   ├── ui/quality_sheet_test.dart
│   ├── ui/downloads_screen_test.dart
│   └── ui/disclaimer_test.dart
├── android/                           # flutter create 生成后：manifest 权限+intent-filter(P1)
│   └── app/src/main/AndroidManifest.xml
└── ios/                               # flutter create 生成后：Info.plist 权限文案；
    └── Runner/Info.plist              #     detectPatterns 小模块与 Share Extension 文档（P1 交付）
```

---

## ④ 模块详细设计

### 4.1 链接输入与解析（core/url_extract + clipboard + parse/*）

**职责**：多通道获取推文 URL → 归一化 → 提取 Tweet ID → 本地算 token → 单次 HTTPS 拿全量 JSON → 七类错误分类 → `TweetMeta + variants`。

- **输入通道**：
  1. 手动输入/一键粘贴（Home 输入框，清空 × 按钮）；
  2. 剪贴板 resume 识别：`WidgetsBindingObserver.didChangeAppLifecycleState(resume)` 时读取剪贴板，命中正则则展示内联横幅"检测到推文视频链接，点击立即解析"（同一链接去重，不重复打扰；PRD 的"浮窗"升级为横幅→BottomSheet，理由见 §1.3-#4）；
  3. 系统分享（P1）：Android manifest intent-filter 接收 x.com/twitter.com 分享文本；iOS Share Extension 交付代码+配置文档（需 Xcode，本机无法构建验证，如实标注）；
  4. t.co 短链解析（P1，HEAD 跟随 Location）。
- **URL 提取**（`url_extract.dart`，纯函数 100% 单测）：单一正则 `^https?://(?:(?:www|m|mobile)\.)?(x|twitter)\.com/(?:i/web/)?[^/]+/status(?:es)?/(\d+)`，容忍 `/video/N` 后缀与 `?s=20&t=…` 查询串、分享文案中夹杂链接（含中英文空格混排）、`web.twitter.com/i/web/status/{id}`；Tweet ID 做 15~20 位数字 + int64 范围双重校验。
- **解析入口**：`SyndicationParser implements TweetParser`（可替换接口，预留方案 C/B 切换点与 fxtwitter 备源插拔）。

### 4.2 清晰度选择（ui/sheet/quality_sheet.dart）

解析成功弹出 BottomSheet：
- 推文预览卡：封面（`media_url_https`，`cacheWidth` 降采样解码）/头像/昵称/正文两行截断/时长徽标/多视频推文的视频切换 Chip（mediaDetails 遍历）；
- 变体列表按码率**降序**，每行主标识 `720p (HD)` 式分辨率标签 + 副行 `2.18 Mbps · 约 24.5 MB · MP4`（estBytes = bitrate × duration_millis / 8）；
- 默认高亮最高码率档（P2 尊循"省流 720p"偏好）；
- 分辨率从 URL 路径 `/vid/avc1/1280x720/` 正则提取（响应无分辨率字段，实测确认）；缺失时按码率映射兜底标签；
- 仅展示 `content_type == video/mp4 && bitrate > 0` 的变体；HLS 变体不暴露（裁剪理由 §12.9）；
- 底部"开始下载"→ 创建任务入队 → toast"已加入下载队列"。

### 4.3 下载引擎（download/download_engine.dart + download_task.dart）

**结构**：`DownloadEngine` 单例（Riverpod 暴露），内存队列（重启经 drift 恢复）+ `ParallelGate` 信号量（permits=2，设置可调 1-3，规避限速）。

**任务状态机**：`queued → running → (paused | completed | failed | canceled)`，幂等转移，全部经 Stream 广播给 UI（与 P1 通知共用）。

**断点续传**：目标文件 `downloads/{tweetId}_{bitrate}.part` 落应用文档目录；请求头 `Range: bytes={bytesDone}-`，期望 206（video.twimg.com 实测支持）；三态处理：
- 206 → 从 bytesDone 追加写；
- 200（范围被忽略）→ 截断 .part 从零重写；
- 连接中断 → 保留 .part，退避后重试续传。
- content-length 校验总量；每 64KB flush。

**流式内存**：dio `ResponseType.stream` + 64KB 缓冲循环写 `RandomAccessFile`，任意大文件内存占用恒定（PRD ≤100MB 峰值，实测预计 <20MB）。

**进度遥测**：3 秒滑动窗口算 speedBps；ETA = 剩余字节 / 平滑速率；节流 500ms 广播。

**重试与错误区分**：
- 网络类错误：指数退避 800ms×2^n + 抖动，3 次后 `failed(retryable=true)` 一键重试（`core/backoff.dart`，序列被单测断言）；
- 403/410（video.twimg.com 签名参数过期）→ **自动回炉重解析刷新直链一次**（复用既有 tweetId，仅刷新 URL 不丢进度）再重试——403 不归"锁推"（评委对 P3 的批评在此规避）；
- 404 → `failed(permanent)`；
- **429 → 全队列 30s 冷却**（吸收 P3）：暂停所有 running/queued 任务，30s 后自动恢复，UI 提示"触发限速，队列稍后自动继续"。

**后台保活（分层诚实交付）**：
- P0 = 前台可见下载 + 锁屏中断但断点可续（iOS 系统杀进程后 .part 仍在）；
- P1-Android = 原生 ForegroundService(type=dataSync) + flutter_local_notifications 常驻进度通知（POST_NOTIFICATIONS 运行时权限，首次下载时请求）；
- P1-iOS = beginBackgroundTask 约 30s 宽限 + 回前台自动续传；完整 URLSession background session 属原生桥 P1 增强项（无 macOS 无法验证，默认不承诺）。

**完成处理**：校验大小 → `gal.putVideo(path, album: 'ClipVault')` → 记录 `albumSavedAt` → 沙盒副本按设置去留（默认保留作缓存，P2 自动清理）。

### 4.4 相册保存与缓存自动清理（download/gallery_saver.dart + settings/settings_controller.dart）

- `gal 2.3.3`（BSD-3，verified publisher，LocalSend 同款）封装 `putVideo`，自定义相册名 **ClipVault**（原 PRD 建议"X-Downloads"因商标一致性弃用，§8.4）；
- 权限按需在"下载完成首次入册"时机请求：iOS `NSPhotoLibraryAddUsageDescription` 仅 add-only 增量权限；Android 29+ 走 MediaStore **零运行时权限**，≤28 声明 `WRITE_EXTERNAL_STORAGE` 且 `maxSdkVersion=28` 且保存时请求；
- **被拒完整降级路径**：回落为仅存应用沙盒，历史条目标出"重新保存至相册"入口，任务不因拒绝而中断（四方案中独有的完整路径，评委 3 肯定）；
- 缓存清理：P0 手动入口（我的 Tab 显示缓存占用 + 一键清理）；P2 自动化（3 天或 2GB LRU，PRD 原文数值）。

### 4.5 下载历史与内置播放器（data/* + ui/downloads + ui/history + player/）

- drift/SQLite 持久化：启动时扫描**全部**未完成记录（queued/running/paused，不按 .part 存在性过滤——.part 缺失或排队未落盘由引擎归零重下，杜绝僵尸行）并重新入队；Stream 驱动 UI 实时刷新；`tweetJson` 元数据快照使历史页**无需重新解析即可离线渲染**缩略图/作者/文案/清晰度标签；
- 历史条目字段（PRD 3.4）：缩略图/标题/下载时间/清晰度标签/文件大小；
- 操作集：删除（P0 即有）；播放/系统分享/重新保存相册（P1 完整）；
- 内置播放器（P1）：`video_player 2.14.0`（官方维护）+ 自定义手势层（横滑进度、竖滑音量、全屏横竖屏）；PiP 依赖平台能力（Android activity 嵌画模式、iOS 14+ AVPictureInPictureController），**真机验证前隐藏入口**；media_kit 列为候补（其更新放缓已如实评估）。

### 4.6 设置（settings/settings_controller.dart + ui/settings/settings_screen.dart）

- P0 即有：免责声明重看（版本化，§8.3）、权限说明（iOS 粘贴横幅/Android 12 剪贴板 toast 的系统提示解释）、缓存占用与手动清理、版本信息与端点配置版本显示（仅诊断用途，不泄漏运维概念到 C 端）；
- P2 激活：默认画质偏好（最高/省流 720p）、并发数(1-3)、仅 Wi-Fi 下载、自动清理策略（3 天/2GB）。

### 4.7 历史备份与卸载重装恢复（2026-09-26 增补）

**问题**：DB 与下载文件均在应用私有目录，卸载即全失；但已入相册的视频在公共媒体库**卸载后保留**，且同包名重装后 owner 复联可免权限读回。

**三层方案**（`lib/backup/`，测试 `test/backup/backup_service_test.dart`）：

| 层 | 机制 | 适用 |
|---|---|---|
| ① 云自动恢复 | `allowBackup` 显式化 + `res/xml/backup_rules.xml`（API≤30）/ `data_extraction_rules.xml`（31+）：含 DB/偏好、排除 downloads 缓存 | GMS 设备零交互 |
| ② 本地自动备份 | 历史流防抖 3s 全量快照 → `BackupStore`；Android 经 `clipvault/backup` 通道写公共 `Downloads/ClipVault/clipvault_backup.json`（MediaStore，API 29+）；重装首启空库静默导入，按 `{tweetId}_{bitrate}.mp4` 回查相册复活 filePath/albumSavedAt | 全平台核心路径 |
| ③ iOS | Documents 目录（`UIFileSharingEnabled` 在「文件」App 可见 + iCloud 整机备份覆盖） | iOS 兜底 |

**导入语义**：活动态（queued/running/paused）一律归 **canceled**（无 .part 可续，绝不自动重下，用户可从历史重试）；手动恢复按 (tweetId, bitrate) 去重合并；备份损坏/缺失静默降级不抛。设置页「备份与恢复」：自动备份开关（默认开）+ 立即备份/从备份恢复。

---

## ⑤ 数据模型（Dart 类字段级）与本地存储

### 5.1 解析域模型（lib/parse/models.dart）

```dart
enum VariantContentType { mp4, hls }

class VideoVariant {
  final VariantContentType contentType; // 实际仅暴露 mp4（§12.9）
  final int bitrate;                    // bps，如 2176000
  final String url;                     // video.twimg.com 直链（含签名参数，会过期）
  final int? width;                     // URL /(\d+)x(\d+)/ 正则提取
  final int? height;
  final int estimatedBytes;             // bitrate × durationMillis / 8
  String get qualityLabel;              // '1080p (Full HD)' / '720p (HD)' / '480p (SD)' / '360p'
}

class TweetMeta {
  final String tweetId;
  final String userName;                // user.name
  final String screenName;              // user.screen_name
  final String avatarUrl;               // user.profile_image_url_https
  final String text;                    // 正文（note_tweet 优先，两行截断展示）
  final DateTime createdAt;
  final String thumbnailUrl;            // mediaDetails[].media_url_https（多视频为当前选中项）
  final int durationMillis;             // video_info.duration_millis
  final bool possiblySensitive;
  final int videoCount;                 // 多视频推文 >1 时 UI 出 Chip
  final List<VideoVariant> variants;    // 仅 mp4、bitrate>0、按 bitrate 降序
}

/// 契约信封：所有 Parser 实现的统一产出（contracts/resolve.schema.json 的 Dart 侧）
class ResolveResult {
  final TweetMeta tweet;
  final String parserVersion;           // 'syndication-v1' | 'fxtwitter-v1'
}
```

### 5.2 错误模型（lib/core/error.dart，sealed）

见 §6.6 七类枚举。附带 `DownloadError { retryable, permanent(reason), urlExpired }` 供引擎内部区分。

### 5.3 持久层（lib/data/tables.dart，drift 表）

```text
DownloadRecords
  id             INTEGER PRIMARY KEY AUTOINCREMENT
  tweetId        TEXT    (idx)
  variantUrl     TEXT
  contentType    TEXT          -- 'mp4'
  bitrate        INTEGER
  width          INTEGER NULLABLE
  height         INTEGER NULLABLE
  qualityLabel   TEXT          -- '720p (HD)'
  status         TEXT          -- queued|running|paused|completed|failed|canceled
  bytesTotal     INTEGER NULLABLE
  bytesDone      INTEGER NOT NULL DEFAULT 0
  speedBps       INTEGER NOT NULL DEFAULT 0
  etaSec         INTEGER NULLABLE
  filePath       TEXT NULLABLE          -- 终转正路径
  partPath       TEXT NULLABLE          -- 断点文件
  errorCode      TEXT NULLABLE          -- ParseError/DownloadError 码
  autoRetries    INTEGER NOT NULL DEFAULT 0
  tweetJson      TEXT                   -- 元数据快照（历史页离线渲染）
  albumSavedAt   INTEGER NULLABLE       -- 空=未入相册（重存入口依据）
  createdAt      INTEGER
  updatedAt      INTEGER  (复合索引 (status, updatedAt))
```

### 5.4 偏好（shared_preferences，P0 即存）

```text
disclaimer.version     int     -- 当前已同意条款版本（升级重弹，§8.3）
disclaimer.acceptedAt  int
endpoint.configJson    string  -- 远端下发的端点配置缓存（§6.7）
endpoint.configVersion int
settings.concurrency   int     -- 默认 2（P2 暴露 UI）
settings.qualityMode   string  -- 'highest'（P2: '720p' 省流）
settings.wifiOnly      bool    -- P2
settings.autoCleanDays int / settings.autoCleanMaxBytes int   -- P2
```

### 5.5 存储布局

- 结构化库：`appDocuments/xdown.db`（drift/SQLite 单文件，响应式 Stream）；
- 下载工件：`appDocuments/downloads/{tweetId}_{bitrate}.mp4` + 同名 `.part`；
- 缩略图：`Image.network` + `cacheWidth` 降采样，全局 `ImageCache` 上限压至 30MB；
- 无安全存储需求：零账号零令牌，无敏感物。

---

## ⑥ 解析层设计

### 6.1 端点与请求（主源：Syndication，实测 2026-09-25）

```text
GET https://cdn.syndication.twimg.com/tweet-result?id={tweetId}&lang=en&token={token}
Headers:
  User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) ...Chrome/129  （普通浏览器 UA）
  Accept: application/json
超时：6s 接收超时（dio）；lang=zh-CN 失败回落 en
```

- 匿名可用，无需 Cookie/Key/特殊 UA（评委实测默认 UA + 正确 token 即 200，**明确不采用 Googlebot 伪装**）；
- 实测边界：不带 token 返回 HTTP 200 + 空 JSON `{}`（token 实际必需）；带任意错误 token 当前仍返回全量数据（服务端校验宽松，2026-09 观察，**不可依赖**，仍按官方算法计算——该机制洞察为 P1 独有并被评委确认）；
- 404 时返回 X 的 dogpage HTML（content-type text/html），据此区分"推文不存在"。

### 6.2 token 算法（唯一权威实现）

```js
// 与官方嵌入组件及 yt-dlp master _generate_syndication_token 一致（评委源码比对+独立复现双确认）
((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')
// 实测向量：id=1790637656616943991 → 中间值 "4c9.gcitu1vq" → token "4c9gcitu1vq"
```

Dart 移植（`core/token.dart` + `core/js_number_radix36.dart`）分三步，是全方案最核心自研资产：
1. id 字符串按 IEEE754 正确舍入为 double（与 JS `Number(id)` 位级一致；推文 ID 超 2^53 存在双精度舍入，必须处理）；
2. `(id / 1e15) * Math.PI` 的 double 精确值按 ECMAScript `Number::toString(36)` 规则转 36 进制串（复刻 V8 DoubleToRadixCString：整数/小数部分分离、小数逐位乘 36 进位）；
3. `replaceAll(RegExp(r'(0+|\.)'), '')` 剥离。

**三重验证**（回应"自我印证"扣分，§11.1）：语料由 Node V8 原生 `toString(36)` 生成（参考实现）+ `bin/smoke.dart` 真端点放行 + 边界向量人工核对。P4 的固定常量 `353i5ab8p5f` 与 P3 的 `token=0` 均为宽松校验副产品，**不采信、不依赖**。

### 6.3 响应解析路径

```text
HTTP 200
 └─ body == '{}'                                  → TweetNotFound（无 token 行为特判）
 └─ __typename != 'Tweet' 或关键结构缺失            → EndpointDrift（守卫，§6.6-E07）
 └─ 404 / body 为 dogpage HTML(content-type html)  → TweetNotFound
 └─ possibly_sensitive == true                     → RestrictedContent（不载缩略图）
 └─ mediaDetails 遍历：
     ├─ 无 type ∈ {video, animated_gif} 条目        → NotVideoTweet（GIF 归入可下载）
     └─ 每个 video 条目：video_info.variants[]
         ├─ content_type == 'video/mp4' && bitrate > 0 → 收集
         │   ├─ 分辨率：URL /vid/avc1/(\d+)x(\d+)/ 正则（响应无分辨率字段，实测确认）
         │   └─ estimatedBytes = bitrate × duration_millis / 8
         └─ 按 bitrate 降序 → TweetMeta.variants
封面双源：media_url_https（主）/ user.profile_image_url_https（头像）
```

多视频推文（`/video/1`、`/video/2`）实测 mediaDetails 含 2 个 type=video 条目，必须遍历（P1 实测发现并经评委确认）。

### 6.4 备选源（FxTwitter，P1 降级备援）

```text
GET https://api.fxtwitter.com/status/{id}     （官方路径；P2 方案所写 /2/status/:id 与 formats[] 结构
                                              两评委核查结论矛盾 → 按防御性结构实现：顶层 code+tweet，
                                              videos[].url 单直链与 formats[] 多码率两种形态都容忍，
                                              开工当日以 tools/fetch_fixtures.mjs 实测对账后锁定）
```
- 第三方公益服务，可用性与寿命不保证，仅作 `RateLimited`/`EndpointDrift` 时的降级备选，**不作为主解析层**（评委裁决）；
- 备源同样实现 `TweetParser` 接口，经 endpoints 配置开关（§6.7）。

### 6.5 解析编排（parsingFlow 总图）

```text
输入(粘贴/横幅/分享(P1)/t.co(P1))
 → url_extract 提取 TweetID（失败→UrlInvalid，零网络请求）
 → token 本地计算（<1ms）
 → TweetParser.resolve(id)（主源 Syndication；EndpointDrift/RateLimited 时按配置切备源）
 → 七类分类判定（§6.6）
 → TweetMeta + variants → 清晰度 Sheet → 下载引擎
重试：网络类指数退避 800ms/1.6s/3.2s+抖动 ×3 → 失败态 + 一键重试
```

### 6.6 错误分类枚举（sealed ParseError，七类；contracts/error_codes.md 为契约源）

| 码 | 枚举 | 触发条件（实测依据） | UI 动作（app_strings.dart 收口） |
|---|---|---|---|
| E01 | `UrlInvalid` | 正则/位数/int64 校验不过 | 提示格式示例，零网络请求 |
| E02 | `NetworkTimeout` | 网络层异常/DNS/超时 | 退避 3 次自动重试后透出 + 一键重试按钮 |
| E03 | `RateLimited` | 上游 429/403 风控（**独立分类**，吸收 P4 精细度；403 不归"锁推"） | 触发备源切换；下载语境另触发全队列 30s 冷却（§4.3） |
| E04 | `TweetNotFound` | HTTP 404 / dogpage HTML / 200+空`{}` | "推文不存在或已删除"；锁推通常表现为 404/空{}，合并提示并附"非公开推文无法解析"补充文案 |
| E05 | `NotVideoTweet` | 200 合法 JSON 但 mediaDetails 无 video/animated_gif | "该推文不是视频推文" |
| E06 | `RestrictedContent` | possibly_sensitive=true 或媒体字段缺失受限启发式 | PRD 指定话术"该视频受内容限制，无法匿名解析"；**不加载缩略图**（NSFW 双保险） |
| E07 | `EndpointDrift` | `__typename != 'Tweet'` 或关键字段结构性缺失 | "解析服务暂不可用，请升级 App 版本"；同时驱动端点配置刷新检查（§6.7）+ 本地哨兵日志（开发者对账） |

### 6.7 端点配置外置（吸收 P2/P4，方案 A → A' 的核心增强）

`parse/endpoint_config.dart` + `assets/config/endpoints.json`：

```json
{
  "version": 1,
  "primary": {
    "kind": "syndication",
    "urlTemplate": "https://cdn.syndication.twimg.com/tweet-result?id={id}&lang={lang}&token={token}",
    "tokenAlgo": "radix36-v1",
    "ua": "Mozilla/5.0 ... Chrome/129",
    "timeoutMs": 6000
  },
  "fallback": { "kind": "fxtwitter", "enabled": false, "urlTemplate": "https://api.fxtwitter.com/status/{id}" },
  "driftGuard": { "typenameEquals": "Tweet", "requiredFields": ["user.screen_name"] }
}
```

- 加载顺序：内置 assets → shared_preferences 缓存的远端版本（版本号更高则原子替换）→ 启动后台异步尝试远端拉取（URL 可配，默认空=关闭，绝不影响离线可用）；
- `EndpointDrift`（E07）触发时主动刷新一次远端配置——X 小改参数（UA/超时/字段名/token 算法版本）可免发版自愈；大改仍需发版（结构性风险接受，§12.1）；
- 该设计使 PRD 4.2-1"应对 X 接口变更"在纯客户端架构下获得最大弹性，同时**不引入 P2 的后端/代理池运维负担**。

### 6.8 性能预算（1.8s 指标拆解，吸收 P3）

| 阶段 | 预算 | 依据 |
|---|---|---|
| URL 提取 + token 计算 | <1ms | 纯本地 |
| HTTPS 单次往返 | ≤0.8s | 实测本机冷请求亚秒级；dio 连接池复用 DNS/TLS |
| JSON→模型映射 | <0.1s | 3-6KB JSON |
| UI 渲染 Sheet | <0.3s | 骨架卡片过渡 |
| 余量 | 0.6s | 弱网抖动 |
| 熔断 | 6s 超时 → E02 | 不虚报达标：真机指标待设备端实测，结构上无冗余往返 |

---

## ⑦ UI 信息架构与导航流

**IA**：底部 3 Tab——「首页」「下载」「我的」（设置并入我的，P2 激活偏好区）。深色模式跟随系统（Material 3 亮/暗主题）。全部文案收口 `core/app_strings.dart`。

**导航流**：
```text
冷启动 → 首启免责声明全屏 Dialog（《使用协议》勾选同意才放行；版本化 §8.3）
       → 首页
分享进入(P1) → 首页自动填充解析
解析成功 → QualitySheet(BottomSheet) → 「开始下载」→ toast → 下载 Tab
历史条目点击(P1) → Player 全屏页
```

**每屏构成**：

1. **首页**：大号 URL 输入框（清空 ×、一键粘贴按钮）、「解析」主按钮；resume 时命中剪贴板则顶部内联横幅"检测到推文视频链接，点击立即解析"（同链接去重）；**解析中骨架卡片 + 耗时计时器**（吸收 P2，缓解 1.8s 等待感）；最近解析卡片（内存态）。
2. **清晰度 Sheet**：推文预览卡（封面/头像/昵称/正文两行/时长/多视频 Chip）+ 变体列表按码率降序（行模板见 §4.2）+「开始下载」。
3. **下载 Tab**：进行中区（缩略图+标题+清晰度标签+百分比+速率+已用/剩余时间+暂停/继续/取消）+ 等待队列 + 失败区（错误话术+一键重试）+ 历史区（缩略图/标题/下载时间/清晰度/大小；操作=播放/系统分享/重新保存相册/删除）。
4. **我的 Tab**：免责声明重看、权限说明（系统粘贴横幅/剪贴板 toast 解释）、缓存占用与清理、诊断信息（配置版本，仅技术只读）、P2 偏好区。
5. **播放页（P1）**：全屏 video_player + 手势层（横滑进度、竖滑音量、旋转）；PiP 入口真机验证后揭示。

**全局**：七类 ParseError 一物一视图（`error_views.dart`），网络类均带重试按钮；NSFW 视图不加载缩略图。

---

## ⑧ 权限与合规

### 8.1 权限清单与申请时机（严格按需、首屏零索取）

**Android**（`android/app/src/main/AndroidManifest.xml`）：
- `INTERNET`（normal 级，无用户感知）；
- `POST_NOTIFICATIONS`（13+）：仅 P1 启用常驻进度通知时、首次开始下载场景请求；拒绝不阻塞下载仅无通知；
- `WRITE_EXTERNAL_STORAGE`：仅 `maxSdkVersion=28` 且保存时请求；29+ 经 MediaStore 写入**零运行时权限**；
- **明文论证不申请 `READ_MEDIA_VIDEO`**（吸收 P4，纠正 PRD 4.2-3 过度索取）：本 App 不读取用户既有媒体库——历史缩略图走 URL 网络渲染，自有文件经应用私有路径/FileProvider 自查自读；
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC`：P1 前台服务声明，下载中才启动。

**iOS**（`ios/Runner/Info.plist`）：
- 仅 `NSPhotoLibraryAddUsageDescription`（add-only 最小权限），文案："仅用于将您下载的视频保存到相册"，首次保存时请求；
- 无定位/通讯录/麦克风等一切无关权限。

**权限被拒降级**：回落仅存沙盒 + 历史"重新保存至相册"入口，任务不中断（§4.4）。

### 8.2 剪贴板合规

- Android 10+ 仅前台可读（resume 时机合规）；Android 12 剪贴板 toast 为系统提示，设置页提供解释文案；
- iOS：P0 用 `Clipboard.getData`（触发系统粘贴横幅，设置页解释）；P1 增强——原生小模块 `ios/Runner/ClipboardPatternPlugin.swift` 经 MethodChannel 暴露 `UIPasteboard.detectPatterns` 预检（只探"是否含 URL"不取内容，规避横幅），**真机验证后启用，未验证前保持兜底路径**（吸收 P3，如实标注交付边界）。

### 8.3 免责声明（版本化，吸收 P2）

- 首启强制全屏《使用协议》Dialog，PRD 5 原文话术："本工具仅供个人备份合法可公开访问的内容，禁止侵权与商业传播"；不同意即退出；
- 版本化：`disclaimer.version`（当前 1）+ `acceptedAt` 存 shared_preferences；条款更新（版本号递增）后再次启动重新弹窗确认；
- 我的 Tab 常驻重看入口。

### 8.4 应用命名与商店过审

- **上架名：ClipVault**（不含 X/Twit 前缀）；商店名、图标、相册名统一（相册名弃 PRD 建议的"X-Downloads"，§1.3-#5）；
- 明示风险：内部代号 Xdown 含"X"、PRD 示例名"TwitSaver"含"Twit"前缀，均有商标投诉风险（吸收 P2/P4 深度）——代号仅存于仓库与文档；
- 图标用下载箭头/胶片母题；文案中"X (Twitter)"仅作叙述性合理使用指代平台；
- 应用描述定位（吸收评委共识）："用户自有内容的个人备份工具""无内容浏览/发现功能、仅用户主动输入链接""**不绕过任何 DRM**（仅处理公开可直链访问的 progressive MP4）"；
- 提审材料：抽样演示（公开新闻类视频）、隐私政策声明**零收集零账号**（纯客户端架构使该声明真实可兑现）；
- 诚实披露：下载类目存在被拒再审可能（App Store 5.2.2 先例），接受并备再审话术；不做任何"审核期行为切换"（P2 负面项明确规避）。

### 8.5 NSFW

解析层 `possibly_sensitive` / 受限启发式 → 阻断并出 PRD 指定话术，敏感项不加载缩略图；年龄分级按商店问卷如实勾选 UGC 可能性。

---

## ⑨ 状态管理等关键技术决策及理由

| # | 决策 | 理由 |
|---|---|---|
| 1 | **flutter_riverpod 3.4.3**（AsyncNotifier 解析流、StreamProvider 双流合并任务+历史） | 编译期安全、`ProviderContainer` override 使 widget 测试无需真引擎；3.x 2026-09 活跃发版 |
| 2 | **dio 5.11.1** 而非 http | 流式下载（ResponseType.stream）+ Range + 取消 + 超时 + 拦截器一体化 |
| 3 | **drift 2.35.0** 而非 isar/hive | isar 2023 停更且 SDK<3.0 与 Dart 3 不兼容；drift 活跃 + SQL + 响应式 Stream；executor 注入设计使测试可换内存库 |
| 4 | **gal 2.3.3** 而非 image_gallery_saver | 后者 2023 停更；gal BSD-3、verified publisher、LocalSend 同款 |
| 5 | **video_player 2.14.0** 为主，media_kit 候补 | 官方维护 vs 更新放缓 9 个月（真机验证后定夺，不预支承诺） |
| 6 | **纯客户端方案 A'**（A + 端点配置外置） | 见 §1.3-#2：B 的基础设施成本对个人工具不成立；A' 经 endpoints 配置获得大部分热更弹性 |
| 7 | **原生面最小化**：全插件、零自研原生代码（唯一例外 iOS detectPatterns 小模块） | 无 JDK/SDK 环境下把不可验证面压到最小（§12.3） |
| 8 | **Dart 业务层零 platform import**：core/parse/download(接口)/data 均纯 Dart，原生能力隔离在接口+薄适配 | `flutter analyze/test` 全覆盖业务逻辑的前提 |
| 9 | **sealed ParseError** 七类 | 穷举 switch 编译期强制处理；一物一视图 |
| 10 | **TweetParser 可替换接口 + endpoints 配置** | 预留方案 C/B 升级与备源插拔（§6.7） |
| 11 | **ImageCache 上限 30MB + 缩略图 cacheWidth 降采样 + 64KB 流式写盘** | 内存 ≤100MB 指标的机制性保障（非调参达标） |
| 12 | **文案收口 app_strings.dart + 深色模式跟随系统** | 吸收 P3；便于审核话术统一与后续多语言 |

---

## ⑩ MVP 边界与里程碑

### P0（Milestone 1——本机 analyze/test 可完整验证，PRD 6 前三项全含）

- 手动输入/粘贴 URL 解析 → 清晰度列表（全部 MP4 档位：降序+分辨率标签+码率+预估体积+MP4 标注，默认最高档高亮）；
- 剪贴板 resume 识别横幅一键解析（同链接去重）；
- 多任务队列（并发 2、.part 断点续传、指数退避 3 次、429 全队列 30s 冷却、速度/百分比/ETA 实时）；
- gal 保存相册（自定义相册 ClipVault，权限按需，被拒降级沙盒+重存入口）；
- drift 下载历史列表（缩略图/时间/清晰度/大小、删除）；
- 首启免责声明（版本化）；
- 七类错误分类 UI + 一键重试；解析中骨架卡片+耗时计时；深色模式；
- token 算法 10 万语料穷举单测、解析夹具回放、引擎 mock 测试、契约测试。

**Milestone 1 验收判据**：`flutter analyze` 0 error（含 strict-casts/strict-inference）；`flutter test` 全绿；token 语料穷举 100% 通过；`bin/smoke.dart` 真端点冒烟通过（解析 200 + Range 下载前 64KB 校验）。

### P1

- Android 分享面板唤起（intent-filter，本机可完成 manifest 配置）；iOS Share Extension（交付代码+配置文档，待 macOS 构建，如实标注）；
- 内置播放器（video_player 全屏/手势，PiP 真机验证后开）；
- Android ForegroundService 进度通知保活 + iOS 后台宽限续传；
- t.co 短链解析；fxtwitter 降级备选解析源（实测对账后启用）；detectPatterns 预检启用；
- NSFW/受限行为真机核对补样本。

### P2

- 偏好设置（默认画质/省流 720p、仅 Wi-Fi、并发数 UI）；
- 沙盒缓存自动清理（3 天/2GB LRU）；
- HLS m3u8 双轨合成**条件立项**（仅当实测出现 m3u8-only 片源；ffmpeg_kit_flutter_new min/LGPL 变体按需动态 feature，§12.9）；
- PiP 全量手势。

---

## ⑪ 测试计划（全部 `flutter test` 宿主机可跑）

### 11.1 单元测试清单

| 文件 | 覆盖内容 |
|---|---|
| `test/core/js_radix36_test.dart` | **对照 `tools/token_corpus.mjs` 语料逐条断言**（V8 原生 toString(36) 生成 = 参考实现，非 Dart 自我印证）：2010-2026 真实雪花 ID 区间（1e18~2e18）随机采样 10 万条 + 边界（0、1、2^53±1、全 0/全 9 尾数、产生 36 进制进位链的值、`(id/1e15)*π` 落在整数边界两侧的值） |
| `test/core/token_test.dart` | getToken 端到端；已知向量 `1790637656616943991 → 4c9gcitu1vq`（评委复现值）硬编码断言 |
| `test/core/url_extract_test.dart` | x.com/twitter.com/www/m./mobile/i/web/status(es)//video/N/?s=20&t=/分享文案混排空格/15~20 位/int64 溢出/非法输入 |
| `test/core/backoff_test.dart` | 800ms×2^n+抖动序列、3 次上限、注入时钟断言（fakeAsync） |
| `test/parse/syndication_parser_test.dart` | 七夹具回放：video_ok / multi_video / photo_only（→E05）/ 404 dogpage（→E04）/ 空{}（→E04）/ sensitive（→E06）/ 结构缺失（→E07 守卫）；variants 降序、分辨率 URL 提取、estBytes、多视频遍历 |
| `test/parse/fxtwitter_parser_test.dart` | 备选源防御性结构（code+tweet、videos 单 url 与 formats 两种形态） |
| `test/parse/endpoint_config_test.dart` | 内置加载 / 版本比较 / 原子替换 / 远端拉取失败回落（mock dio） / drift 触发刷新 |
| `test/parse/contract_test.dart` | 全部 fixtures 反序列化为 ResolveResult 并通过 `contracts/resolve.schema.json` 断言（吸收 P2 契约纪律） |
| `test/download/download_engine_test.dart` | **本地 HttpServer mock**：206 正常续传 / 200 范围忽略重写 / 中断后重连续传 / 退避序列 / 403→重解析回调（URL 刷新不丢进度）/ 429→全队列 30s 冷却 / 并发上限 2 / 暂停恢复取消 / 速度滑窗与 ETA 节流 |
| `test/data/history_repository_test.dart` | drift 内存库（`NativeDatabase.memory()`；宿主机缺 sqlite3.dll 时回落 drift WasmDatabase 同断言）：CRUD、Stream 更新、启动恢复扫描（全部未完成行，不按 .part 过滤） |

### 11.2 widget 测试清单（ProviderContainer override，不触真网络/真插件）

| 文件 | 覆盖内容 |
|---|---|
| `test/ui/home_screen_test.dart` | 输入框清空/粘贴按钮/解析触发/剪贴板横幅出现与去重/骨架卡片+计时/七类错误视图切换 |
| `test/ui/quality_sheet_test.dart` | 变体降序排列/分辨率标签/码率+预估体积+MP4 标注/默认最高码率高亮/多视频 Chip/开始下载回调 |
| `test/ui/downloads_screen_test.dart` | 任务 tile 进度/速率/ETA/暂停继续取消/失败区重试/历史条目字段与删除/重存入口（albumSavedAt 空） |
| `test/ui/disclaimer_test.dart` | 首启强制弹窗/不同意退出/同意后不再弹/**版本升级重弹**（版本化断言） |

### 11.3 宿主机辅助验证（flutter test 之外，本机可跑）

- `bin/smoke.dart`（dart run）：真端点解析 200 + 计算有效 token + Range 下载前 64KB 落盘校验；
- `tools/check_contract.mjs`（node）：fixtures ↔ schema 契约校验（与 Dart 侧 contract_test 双向防漂移）。

### 11.4 端点哨兵（吸收 P4 探针常规化）

- `tools/fetch_fixtures.mjs`（node）：拉真实端点响应刷新 `assets/fixtures/`，与旧夹具 diff——字段漂移即测试失败，作为**每日/发版前哨兵**，是 EndpointDrift(E07) 守卫的对账依据。

### 11.5 无法本机验证项的回归清单（装 Android Studio / 接触 macOS 后执行）

gal 真机入册、权限弹窗时序、ForegroundService 通知、剪贴板系统横幅/toast、iOS Share Extension、detectPatterns 模块、PiP、后台保活行为——列于 README.md 回归章节。

---

## ⑫ 风险与缓解

| # | 风险 | 等级 | 缓解 / 接受理由 |
|---|---|---|---|
| 1 | **端点硬化/停摆**（tweet-result 为非官方契约，X 可随时收紧；当前错误 token 亦放行、无 token 返空{}，均 2026-09 快照） | 高 | E07 守卫 + 分类话术；fetch_fixtures 哨兵对账；fxtwitter 备源；endpoints 配置远端热更（§6.7）；TweetParser 接口预留切换 PRD 4.1-B/C 服务端解析的升级点。结构性风险接受——这是纯客户端方案 A 的固有代价，换取零运维成本 |
| 2 | **toString(36) 移植精度**（Dart 无内建，雪花 ID 超 2^53 舍入，任何一位偏差即全量解析失败） | 高 | V8 参考实现 10 万语料穷举 + 边界值 + 真端点对账（§11.1 三重验证）；服务端当前宽松放行为最后兜底（明确不作依赖） |
| 3 | **本机无 JDK/Android SDK/模拟器/macOS**：一切原生行为无法本机运行验证 | 高 | 原生面最小化（全插件 + 唯一 detectPatterns 小模块）；交付代码+配置说明+回归清单（§11.5）；flutter test 覆盖全部业务逻辑。接受——四方案共有盲区，本方案盲区最小 |
| 4 | **iOS 交付物**：Share Extension 必须 Xcode 添加 target，Windows 无法产出 ipa | 中 | 交付原生侧代码与配置文档；iOS 可用性完全待验证，如实标注不承诺 |
| 5 | **商店政策**：下载类工具面临 X 商标投诉与"协助侵权"审查 | 中 | §8.4 全套策略（ClipVault 中立名/零收集声明/DRM 声明/抽样演示/审核备注话术）；接受被拒再审可能 |
| 6 | **受限内容行为未验证**：NSFW/锁推在匿名端点的确切返回形态缺真实样本，E06 为启发式 | 中 | 话术与不载缩略图双保险已就位；P1 真机阶段补样本校正分类法 |
| 7 | **直链签名过期**（解析与下载间隔过久 403/410） | 中 | 自动重解析刷新 URL（不丢进度）；极端情况（原推被删）任务失败属可接受降级 |
| 8 | **1080p+ 档位存在性内容相关**：实测样本最高 720p/2176kbps | 低 | PRD 的 1080p 标签仅在片源提供时出现；UI 只展示实存档位 + 设置页预期管理文案 |
| 9 | **HLS 裁剪**（PRD 3.3 有明确条款"内置精简版 FFmpeg…TS 分片合成"） | 中 | **接受并披露**（§1.3-#1）：实测全样本 MP4 与 HLS 并存（裁剪不损失主流程）；ffmpeg_kit_flutter 官方停运且二进制撤库（构建必败）；活跃分叉 Full-GPL 且 +30~60MB；实测 HLS 为音视频分离双轨、合成须 remux 非简单 TS 拼接（成本高）。P2 条件立项：仅出现 m3u8-only 片源才做 |
| 10 | **media_kit 备选线放缓**（2025-12 后无发版） | 低 | video_player 官方线为主；若 P1 手势/PiP 不满足，接受功能降级或再评估 |
| 11 | **drift 宿主机测试的 sqlite3.dll 依赖** | 低 | database.dart 的 executor 注入设计：`NativeDatabase.memory()` 优先，缺 dll 回落 WasmDatabase 内存库跑同样断言（§11.1） |
| 12 | **方案 A vs PRD 推荐方案 B** | 中 | **接受**（§1.3-#2）：B 的代理池/带宽/持续运维对个人工具不成立（评委 2 裁决其 guard/proxy 面本机不可验证不可运维）；A' 经端点配置外置获得大部分热更弹性；升级路径已预留 |
| 13 | **fxtwitter 备源结构不确定**（两评委核查结论矛盾：/2/status/:id 与 formats[] 是否存在不一致） | 低 | 按官方 /status/:id + 防御性双形态解析（§6.4）；开工当日 fetch_fixtures 实测对账锁定；备源默认关闭 |

---

## ⑬ 附录：落选方案可借鉴点（全部已吸收，落位见 §1.4）

| 来源 | 借鉴点 | 吸收方式 |
|---|---|---|
| P2 | 免责条款版本化 | `disclaimer.version/acceptedAt` + 升级重弹（§8.3、§11.2） |
| P2 | 解析中骨架卡片 + 耗时计时 | `ui/common/parse_skeleton.dart`（§7.2） |
| P2 | contracts/ JSON Schema + fixtures 双向契约测试 | `contracts/resolve.schema.json` + `test/parse/contract_test.dart` + `tools/check_contract.mjs`（§11.1/11.3） |
| P2/P4 | 端点参数外置可热更配置 | `assets/config/endpoints.json` + `parse/endpoint_config.dart`（§6.7，方案 A' 核心） |
| P3 | 1.8s 预算拆解 | §6.8 表 |
| P3 | 429 全队列 30s 冷却 | download_engine（§4.3）+ 引擎单测断言 |
| P3 | iOS detectPatterns 剪贴板预检 | 原生小模块 + 真机验证后启用（§8.2） |
| P3 | 深色模式、文案收口 i18n | `app.dart` 主题 + `core/app_strings.dart`（§7） |
| P4 | "READ_MEDIA_VIDEO 完全不需要"论证 | §8.1 明文（纠正 PRD 4.2-3） |
| P4 | 错误分类精细度（429 独立、EndpointDrift 驱动热更） | E03/E07 独立分类（§6.6） |
| P4 | Node 探针常规化 | fetch_fixtures 每日哨兵（§11.4） |
| P4 | protocol/ 契约层组织方式 | contracts/ + assets/fixtures/ 目录形态（§③） |

**规避清单**（评委点名的负面项，禁止进入实现）：P2"审核期指向受限模式"；P3 READ_MEDIA_VIDEO 索取理由；P3"403 一律锁推"；P4 Googlebot UA 伪装；P4 固定 token 常量；P3 token=0 依赖（宽松校验副产品）。

---

*定稿人：首席架构师（workflow 设计阶段输出）。实施按 StructuredOutput 的 implementationPlan 分七步并行开发；除 DESIGN.md 外本阶段不创建其他项目文件。*
