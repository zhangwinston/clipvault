# ClipVault（内部代号 Xdown）代码实现解读文档

> **目标读者**：有 C 或 Rust 代码阅读能力、但对 App 开发（Flutter/Dart、移动端生态）毫无基础的工程师。
> **解读对象**：本仓库（`D:\Program\xdown`）的全部应用代码，需求来源为上级目录的《Xdown-PRD.md》，设计与实现契约见仓库内 [DESIGN.md](./DESIGN.md)。
> **阅读方式**：第一、二部分是预备知识，建议顺序阅读；第三部分按模块深读，可当作"带着地图看代码"的导览手册，每个小节都标注了对应源文件与行号（形如 `lib/core/token.dart:34`，可在 IDE 中点击跳转）。

---

## 目录

- [第一部分 全景](#第一部分-全景)
  - [1. 这个 App 做什么](#1-这个-app-做什么)
  - [2. 技术方案与架构选型](#2-技术方案与架构选型)
  - [3. 仓库目录地图](#3-仓库目录地图)
- [第二部分 预备知识（C/Rust 工程师的 Dart/Flutter 速成）](#第二部分-预备知识)
  - [4. Dart 语言速览](#4-dart-语言速览)
  - [5. async/await 与事件循环](#5-asyncawait-与事件循环)
  - [6. Flutter 的 UI 模型：Widget 与 build](#6-flutter-的-ui-模型)
  - [7. Riverpod 状态管理](#7-riverpod-状态管理)
- [第三部分 模块深读](#第三部分-模块深读)
  - [8. core/：纯函数工具层](#8-core纯函数工具层)
  - [9. parse/：解析层](#9-parse解析层)
  - [10. download/：下载引擎](#10-download下载引擎)
  - [11. data/：持久层](#11-data持久层)
  - [12. ui/：界面层](#12-ui界面层)
  - [13. 周边模块：clipboard / sharing / player / settings](#13-周边模块)
  - [14. 端到端时序：一次"粘贴→解析→下载→入相册"的完整生命](#14-端到端时序)
  - [15. 测试与工具链](#15-测试与工具链)
  - [16. 已知限制与未完成项](#16-已知限制与未完成项)
- [附录 A：Dart 语法糖速查表](#附录-a-dart-语法糖速查表)
- [附录 B：术语表](#附录-b-术语表)

---

# 第一部分 全景

## 1. 这个 App 做什么

X（原 Twitter）官方只对付费会员开放视频下载。本 App 让普通用户做到：

```
复制一条推文链接
   │
   ▼
打开 App（或从系统分享面板唤起）
   │  自动识别剪贴板 / 接收分享文本
   ▼
本地计算 token，直接请求 X 的公开 syndication 接口（不经任何自建服务器）
   │  拿到推文元数据 + 多档清晰度的视频直链（MP4）
   ▼
弹出清晰度选择面板（1080p / 720p / 480p / 360p，含码率与预估体积）
   │
   ▼
流式下载（支持断点续传、暂停/恢复/取消、指数退避重试、限速冷却）
   │
   ▼
保存进系统相册（相册名 "ClipVault"）+ 落一份文件在 App 沙盒
   │
   ▼
下载 Tab / 历史页管理：播放、分享、重新入册、删除
```

用一句话概括实现：**一个纯客户端的推文视频解析器 + 一个带断点续传的下载队列 + 一个本地历史数据库 + 三页 UI**。没有服务端、没有账号、不收集任何数据。

## 2. 技术方案与架构选型

PRD §4.1 给了三个解析方案（纯客户端 / 自建服务端 / 混合）。本项目采用**方案 A 的增强版（DESIGN 称 A'）：纯客户端解析**：

- 解析用的端点、UA、超时等参数**外置成配置文件**（`assets/config/endpoints.json`），并支持远端热更新（默认关闭）。X 的接口小改时，推一个新版本配置即可自愈，不需要发新版 App——这是对"方案 A 接口一变就得发版"缺点的主要缓解。
- 备源（fxtwitter）已实现但默认关闭，遇到风控时可经配置打开降级备援。

**跨平台方案**：Flutter 单代码库同时产出 Android APK 与 iOS IPA。所有平台能力（相册、剪贴板、分享、路径）都通过第三方插件（pub 包）调用，业务代码本身是纯 Dart。

**分层架构**（这是理解代码的最重要一张图）：

```
┌─────────────────────────────────────────────────────────────┐
│  ui/            界面层（Widget 树、屏幕、Sheet、文案）          │
│       │ 只依赖抽象接口（DownloadCommands / TweetParser …）     │
├───────┼─────────────────────────────────────────────────────┤
│  parse/         解析层：URL→推文元数据+清晰度列表（HTTP+分类）  │
│  download/      下载引擎：队列/并发/断点/重试/冷却（纯 Dart）   │
│  data/          持久层：drift(SQLite) 之上的仓库封装           │
│  core/          纯函数层：token 算法/URL 提取/错误模型/退避     │
├───────┴─────────────────────────────────────────────────────┤
│  clipboard/ sharing/ player/ settings/    周边能力模块         │
├─────────────────────────────────────────────────────────────┤
│  平台插件：dio(HTTP) drift(SQLite) gal(相册) video_player …    │
│  （由 Riverpod Provider 在"组合根"统一装配、可注入替换）        │
└─────────────────────────────────────────────────────────────┘
```

关键设计纪律（贯穿全仓库，读代码时会反复看到）：

1. **依赖注入**：所有 IO 对象（HTTP 客户端、数据库、剪贴板、时钟……）都通过构造函数注入，业务类不自己 `new` 资源。因此全部单元测试可以离线跑（注入 fake）。
2. **契约先行**：`contracts/` 目录（JSON Schema + 错误码表）与 `DESIGN.md` 是字段级契约源，代码注释大量引用其章节号（如 "§6.2"）。
3. **不可变数据 + 单一状态机**：下载任务的每次状态演进都是"整条记录替换"，不存在共享可变状态。

## 3. 仓库目录地图

```
xdown/
├── lib/                    ★ 全部应用代码（约 9000 行 Dart，其中 1/6 是生成代码）
│   ├── main.dart           程序入口：初始化、启动恢复、缓存上限
│   ├── app.dart            应用壳：MaterialApp、免责声明闸门、3 Tab 主界面
│   ├── core/               纯函数层（无 IO、无平台依赖）
│   │   ├── token.dart            syndication token 计算（三行核心算法）
│   │   ├── js_number_radix36.dart  V8 Number.toString(36) 的位级精确移植（149 行）
│   │   ├── url_extract.dart      推文 URL 提取与 ID 校验（正则）
│   │   ├── error.dart            错误模型：解析域七类 + 下载域三类
│   │   ├── backoff.dart          指数退避计算器
│   │   └── app_strings.dart      全部用户可见文案常量（收口）
│   ├── parse/              解析层
│   │   ├── models.dart           数据模型（VideoVariant / TweetMeta / ResolveResult）
│   │   ├── syndication_client.dart  HTTP 客户端（单次 GET，不做语义判定）
│   │   ├── syndication_parser.dart  ★ 主解析器：七类错误分类 + 字段映射
│   │   ├── fxtwitter_parser.dart    备源解析器（默认关闭）
│   │   └── endpoint_config.dart     端点配置：内置→缓存→远端热更
│   ├── download/           下载引擎
│   │   ├── download_task.dart      任务实体 + 状态机 + 转移表
│   │   ├── download_engine.dart    ★ 引擎：队列/信号量/Range 断点/重试/冷却（989 行，最大文件）
│   │   └── gallery_saver.dart      相册保存接口 + gal 插件实现
│   ├── data/               持久层
│   │   ├── tables.dart            drift 表定义（DownloadRecords 单表）
│   │   ├── database.dart          数据库类（executor 注入）
│   │   ├── database.g.dart        （生成代码，不用读）
│   │   └── history_repository.dart 仓库：全部 SQL 读写的唯一入口
│   ├── ui/                 界面层
│   │   ├── home/home_screen.dart      首页：输入框/剪贴板横幅/解析编排
│   │   ├── sheet/quality_sheet.dart   清晰度选择底部弹层
│   │   ├── downloads/task_tile.dart   ★ UI 与引擎/持久层的装配接缝（753 行）
│   │   ├── downloads/downloads_screen.dart  下载 Tab 四分区列表
│   │   ├── history/history_screen.dart      历史详情页
│   │   ├── settings/settings_screen.dart    我的 Tab
│   │   └── common/            预览卡/骨架屏/错误视图/免责弹窗
│   ├── clipboard/clipboard_watcher.dart  剪贴板监听（resume 时机）
│   ├── sharing/share_receiver.dart      系统分享接收
│   ├── player/player_screen.dart        内置视频播放器
│   └── settings/settings_controller.dart 设置读写（shared_preferences）
├── assets/config/endpoints.json   内置端点配置（可被远端版本替换）
├── contracts/               契约：resolve.schema.json + error_codes.md
├── test/                    全部离线可跑的测试（core/parse/download/data/ui）
├── tools/                   Node.js 宿主机脚本（不进 App）：
│   ├── token_corpus.mjs         生成 10 万条 token 语料（V8 对照）
│   ├── fetch_fixtures.mjs       端点哨兵：录制/刷新真实响应夹具
│   └── check_contract.mjs       夹具 ↔ 契约 双端一致性校验
├── bin/smoke.dart           真端点 E2E 冒烟（解析 200 + Range 下载 64KB）
├── android/ ios/            平台工程（由 flutter 工具生成，基本不改）
├── DESIGN.md                ★ 权威设计契约（模块间接口以它为准）
└── README.md                构建验证命令 + 契约资产申报
```

---

# 第二部分 预备知识

本章把你已有的 C/Rust 知识作为锚点，讲清楚读这份代码所需的全部 Dart/Flutter 概念。**不需要会写 Dart，只需要能"读"**。

## 4. Dart 语言速览

Dart 是一门带 GC 的面向对象语言，语法介于 Java 和 JavaScript 之间。下表是逐概念对照：

| Dart | 你熟悉的概念 | 说明 |
|---|---|---|
| `int` / `double` | `int64_t` / `IEEE754 double | 注意：**没有 32 位整型**，int 就是 64 位（Web 例外）；double 与 C 完全同构 |
| `String` | 不可变字符串（Rust `String` 但不可变） | UTF-16；`'...'` 单引号即可；`'$a + ${b.c}'` 为字符串插值 |
| `List<T>` / `Map<K,V>` | `Vec<T>` / `HashMap<K,V>` | 字面量 `[1,2]`、`{'k': v}` |
| `null` + `T?` | `Option<T>` | `String?` ≈ `Option<String>`；`?.` 安全调用 ≈ `and_then`；`??` 默认值 ≈ `unwrap_or`；`!` 强解包 ≈ `unwrap()`（可能抛异常） |
| `final` / `const` | `let` / `constexpr` | `final` 运行期一次赋值；`const` 编译期常量（会深度冻结） |
| `class` | 单继承的类 | 所有类默认住在堆上、按引用传递 |
| `abstract class` / `interface` | 纯虚基类 / trait | Dart 3 的 `abstract interface class` ≈ 只许 implements 的 trait |
| `sealed class` + 子类 | **`enum`（Rust 带数据的枚举）** | 见 §8.3，本项目最重要的模式 |
| `extends` / `implements` / `with` | 继承 / 实现 trait / mixin 组合 | `with WidgetsBindingObserver` 是混入一个带默认实现的接口 |
| `switch` 表达式 | `match` | Dart 3 的 switch 是表达式且对 sealed 类型**穷尽检查**（漏分支编译报错） |
| `Exception` + `throw`/`try`/`catch` | 异常（Rust 无对应） | **控制流可以走异常**；本项目引擎内部用私有异常类当"信号"用 |
| `Future<T>` | `Future<Output=T>` / promise | 见 §5 |
| `Stream<T>` | 异步迭代器 / mpsc channel | 见 §5.4 |
| `typedef A = B;` | 类型别名 | `typedef JitterFactory = Duration Function(Duration);` ≈ 函数指针类型 |
| 命名参数 `f(x: 1)` | — | 函数实参带名字；`{required String url}` 表示必填命名参数，`[int x]` 是可选位置参数 |
| `@注解` | derive/属性宏 | `@override`、`@DataClassName('DownloadRecord')` 等 |
| 库与导入 | module/use | 一个文件默认一个库；`import 'a.dart' as tbl;` ≈ `use a as tbl;`（本项目用前缀隔离两个同名枚举） |

几个读代码时最容易困惑的写法，提前拆解：

```dart
// (1) 级联操作符 ".."：对同一对象连续调用多个方法/字段赋值
ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(...);            // 等价于 C 里 s = get(); s.hide(); s.show();

// (2) record 类型（Dart 3）：轻量匿名积类型
typedef TokenParts = ({String radix36, String token});
//                                     ≈ Rust: struct TokenParts { radix36: String, token: String }
final parts = (radix36: '4c9.gcitu1vq', token: '4c9gcitu1vq');
print(parts.token);                // 按字段名访问

// (3) spread 与 collection-if（构建列表的 DSL 感语法）
children: [
  if (pendingClipboard != null) Material(...),   // 条件成立才放这个元素
  ...parseState.recent.map((t) => Tile(tweet: t)), // 把一个列表"摊开"塞进来
]

// (4) 函数是一等公民：到处传回调
typedef NowFn = DateTime Function();             // ≈ fn() -> DateTime
DownloadEngine({ NowFn? now }) : _now = now ?? DateTime.now;
//                                              ≈ .unwrap_or_else(|| DateTime::now)

// (5) 私有性：标识符前缀下线即"库内私有"（≈ Rust 模块私有）
class DownloadEngine {
  final Dio _dio;          // 只有本文件能访问
}
```

## 5. async/await 与事件循环

**这是读懂本仓库所有控制流的关键，也是与 C/Rust 心智模型差别最大的一点。**

### 5.1 单线程事件循环

Dart 的 UI App 运行在**单个线程**（叫 isolate）上，跑一个事件循环——概念上和 Node.js 一致：

```
        ┌────────────────────────────────┐
        │   事件队列（定时器、IO 完成、     │
        │   手势、绘制帧回调…依次入队）      │
        └───────────┬────────────────────┘
                    ▼  逐个取出执行（run to completion）
        ┌────────────────────────────────┐
        │  正在执行的同步代码片段            │
        │  （两个 await 之间的部分不会被打断）│
        └────────────────────────────────┘
```

推论（对本项目至关重要）：

- **没有数据竞争，不需要锁**。任何同步代码块（两个 `await` 之间）是原子的。
- **"并发"来自异步 IO 交错**，而不是多线程并行。多个下载任务各自的 `await 网络数据` 交错推进。
- 真正的并行要用 isolate（不共享内存的类进程模型，靠消息传递），本项目只在 SQLite 驱动内部用到，业务代码无需关心。

### 5.2 Future 与 await

```dart
Future<SyndicationResponse> fetchTweetResult(...) async {
  final response = await _dio.get<String>(url, ...);   // 挂起，让出线程；完成后从这继续
  return SyndicationResponse(...);                      // 返回值被包进 Future
}
```

对照 Rust：`await` ≈ `.await`。但有个重要差别——**Dart 的 Future 是"热"的**：一创建就开始执行（像 JS Promise），不像 Rust Future 是惰性的、要被 poll 才动。所以"调用一个 async 函数"等于"已经开跑了一件事，手里攥着它的句柄"。

### 5.3 用异常做控制流

Dart 没有代数效应也没有 `Result`，本仓库的惯用法是：

- **跨层错误**：解析层抛 `ParseError` 七个子类（§8.3），上层 `try/catch` 捕获后按类型穷举处理——读起来像 Rust `match Err(e) => ...`。
- **引擎内部信号**：`download_engine.dart:968-989` 定义了 `_PauseSignal` / `_CancelSignal` 等私有异常类，纯粹当"带类型的 goto"用：深藏在下载循环里的代码 `throw _PauseSignal()`，外层 `_attemptLoop` 捕获后把任务置为 paused。Rust 工程师可以把它理解成 `Result<(), Signal>` 的 `?` 传播，只是语法形态是异常。

### 5.4 Stream

`Stream<T>` ≈ 异步的 `Iterator` + 订阅模型，本项目三种用法：

```dart
// (a) 数据库响应式查询（drift）：表一变，查询自动重发，新结果推给订阅者
Stream<List<DownloadRecord>> watchAll() => query.watch();

// (b) 引擎事件广播：broadcast 流可有多个订阅者，不回放历史
Stream<DownloadTask> get taskEvents => _taskEvents.stream;

// (c) 逐块读 HTTP 响应体（下载引擎核心循环）
await for (final chunk in body.stream) {   // ≈ loop { let chunk = stream.next().await }
  await raf.writeFrom(chunk);
}
```

## 6. Flutter 的 UI 模型

### 6.1 Widget ≈ 不可变的 UI 描述

Flutter 里界面上的一切（按钮、间距、动画、整页）都是 **Widget**——一个轻量不可变配置对象。写界面 = 声明一棵 Widget 树：

```dart
Widget build(BuildContext context) {
  return Scaffold(                         // 页面脚手架
    appBar: AppBar(title: const Text('ClipVault')),
    body: ListView(                        // 可滚动列表
      children: const [ Text('你好'), DownloadButton() ],
    ),
  );
}
```

`build()` 是**纯函数**：输入是"当前状态 + 主题等上下文"，输出是一棵新的 Widget 树。框架拿新树与旧树做 diff，只把差异部分应用到真正的屏幕上（保留模式）。所以你会在代码里看到大量"重建"——它很便宜，Widget 只是配置描述，不是重量级控件句柄。

### 6.2 StatefulWidget 与 setState

有内部状态的组件分两半：

```dart
class _HomeShellState extends State<HomeShell> {
  int _index = 0;                                   // 状态放 State 对象里
  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: _index,                        // 状态喂给 build
      onDestinationSelected: (v) => setState(() => _index = v),
      //               ^^^^^^^^^  ≈ "状态变了，请重跑 build 重绘"
    );
  }
}
```

`setState(cb)` ≈ 改完数据后调 `request_redraw()`。`initState`/`dispose` ≈ 构造/析构（注册/反注册观察者都在这成对出现，见 `home_screen.dart:214-239`）。

### 6.3 常见 Widget 速查（本项目用到的）

| Widget | 作用 | 类比 |
|---|---|---|
| `Scaffold` | 页面骨架（AppBar + body + 底栏） | 窗口模板 |
| `Column` / `Row` | 垂直/水平排列子元素 | 线性布局 |
| `ListView` / `ListView.builder` | 滚动列表；builder 版惰性构造行 | RecyclerView |
| `IndexedStack` | 多页叠放只显示一页，**其余保活** | 保持各 Tab 状态 |
| `NavigationBar` | 底部导航栏 | TabBar |
| `ListTile` | 一行（图标/标题/副标题/尾部动作） | 列表项模板 |
| `FutureBuilder` / `AsyncValue.when` | 异步三态渲染（loading/error/data） | |
| `showModalBottomSheet` | 底部弹层（清晰度选择用） | BottomSheet |
| `SnackBar` | 底部 toast | |
| `LinearProgressIndicator` | 进度条 | |

## 7. Riverpod 状态管理

跨页面/跨模块共享状态，本项目用 Riverpod。核心就一句话：**一个全局的、类型安全的"按需单例容器" + 订阅刷新**。

```dart
// 声明一个 Provider：惰性、缓存、可被测试覆盖
final Provider<GallerySaver> gallerySaverProvider =
    Provider<GallerySaver>((_) => const GalGallerySaver());

// 读取（拿实例，一次性）
final saver = ref.read(gallerySaverProvider);

// 监听（build 里调用：状态变化时自动重建此 Widget）
final items = ref.watch(downloadsWatchProvider);
```

对照理解：

- `Provider<T>` ≈ 容器里注册的懒工厂 `|| -> T`，首次 `read/watch` 才构造，之后同一实例。
- `ref.watch(p)` ≈ **响应式订阅**：`p` 的值一变，当前 `build` 被重新执行。这让"数据库变更 → UI 自动刷新"只需一行（见 §11.3）。
- 测试时可整体替换：`overrideWith((ref) => fakeImpl)`——这就是全仓库"零真 IO 也能测"的机制。
- `Notifier`/`AsyncNotifier` 是带方法的可变状态单元（如 `HomeParseController`），`state` 字段一赋值，所有 watcher 重建。
- `main.dart:27-39` 的 `ProviderContainer(overrides: [...])` 叫**组合根**：生产实现在这里统一接线；`ref.invalidate(p)` ≈ "扔掉缓存重建一次"（端点配置热更后用新配置重建解析器，`home_screen.dart:138`）。

---

# 第三部分 模块深读

## 8. core/：纯函数工具层

`lib/core/` 下全部是**无 IO、无平台依赖的纯 Dart**（DESIGN §9-8），是全仓库最像 C 代码的地方，也最适合作为阅读起点。

### 8.1 url_extract.dart —— URL 提取与校验

`lib/core/url_extract.dart`（92 行）。职责：从任意文本（输入框内容、剪贴板、分享文案）中提取推文链接，产出 15~20 位的 Tweet ID。

核心是一条正则（`url_extract.dart:21-25`）：

```dart
final RegExp _tweetUrlPattern = RegExp(
  r'https?://(?:(?:www|m|mobile|web)\.)?(?:x|twitter)\.com/'
  r'(?:i/web/)?(?:[^/]+/)?status(?:es)?/(\d+)',
  caseSensitive: false,
);
```

翻译：匹配 `http(s)://[子域.]x.com 或 twitter.com/[可选 i/web/][可选用户名/]status 或 statuses/数字串`，捕获组 1 就是 ID 数字串。一条正则同时覆盖 `www./m./mobile./web.` 子域、`/i/web/status/{id}` 无用户名形态、`/video/N` 后缀、查询串（匹配在数字串处自然截断）。

然后是 **ID 双重校验**（`url_extract.dart:39-45`）——这段逻辑 C 工程师会非常熟悉：

```dart
final RegExp _tweetIdDigits = RegExp(r'^\d{15,20}$');       // (1) 纯 ASCII 数字且 15~20 位
final BigInt _int64Max = BigInt.parse('9223372036854775807');

bool isValidTweetId(String id) {
  if (!_tweetIdDigits.hasMatch(id)) return false;            // 先字符集校验
  final BigInt? value = BigInt.tryParse(id);                 // (2) int64 范围校验
  return value != null && value <= _int64Max;
}
```

注释里解释了为什么必须先跑正则再做数值解析：`BigInt.tryParse` 容忍首尾空白，`'1790637656616943991 '`（带空格恰好 20 位）会被当成合法数字——先做字符集校验堵住这个洞。

注意 `BigInt` ≈ 任意精度整数（Rust 的 `num_bigint`）。**Tweet ID 全程以字符串/TEXT 存储，绝不能转 double**（超过 2^53 丢精度）——这个纪律贯穿全仓库。

### 8.2 token.dart + js_number_radix36.dart —— 令牌算法（全项目技术含量最高的代码）

**背景**：X 的 syndication 接口（`cdn.syndication.twimg.com/tweet-result`）要求 URL 上带一个 `token` 参数，算法来自官方嵌入组件与 yt-dlp，是一行 JS：

```js
((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')
```

即：推文 ID 转数字 → 除以 1e15 → 乘 π → 转 36 进制字符串 → 删掉所有 `0` 和 `.`。已知向量：`1790637656616943991 → 4c9gcitu1vq`。

**难点**：前两步在 Dart 里用 IEEE754 double 运算是逐位一致的；但**第三步 `toString(36)` 是 V8 的私有算法（Dragon4 变体），Dart 标准库的实现与它不一致**。token 差一个字符，请求可能被拒。所以本项目把 V8 的 `DoubleToRadixStringView`（`src/numbers/conversions.cc`）**逐行移植成 Dart**——这就是 `lib/core/js_number_radix36.dart`（149 行）。

顶层入口 `lib/core/token.dart:34-39`：

```dart
TokenParts computeToken(String tweetId) {
  final double n = double.parse(tweetId);        // == JS Number(id)：IEEE754 正确舍入
  final double v = (n / 1e15) * math.pi;         // 与 JS 逐位一致的 double 运算
  final String radix36 = jsNumberToStringRadix(v, 36);
  return (radix36: radix36, token: radix36.replaceAll(_stripPattern, ''));
}
```

移植文件里值得细读的三个片段（全部是 C 工程师的老朋友）：

**(a) 位级类型双关（`js_number_radix36.dart:42-47`）**——求"下一个更大的 double"：

```dart
final ByteData _scratch = ByteData(8);

double _nextUpNonNegative(double value) {
  _scratch.setFloat64(0, value);        // double 的 8 字节写进缓冲
  final int bits = _scratch.getUint64(0); // 按无符号整数读回 —— ≈ union / memcpy 双关
  _scratch.setUint64(0, bits + 1);       // IEEE754 位模式 +1（正数域=下一个可表示值）
  return _scratch.getFloat64(0);
}
```

这正是 C 里 `union { double d; uint64_t u; }` 的安全版。

**(b) 生成到"半个 ulp"为止（`js_number_radix36.dart:76-79`）**：

```dart
double delta = 0.5 * (_nextUpNonNegative(value) - value);  // 半个最小间隔（ulp）
```

小数位不是固定位数，而是逐位乘 36 进位生成，直到**剩余部分小于半个 ulp（双精度已不可分辨）**为止——这就是"一个 double 的 36 进制最短精确表示"的含义，Dragon4 算法的核心思想。

**(c) 大整数低位退化（`js_number_radix36.dart:122-127`）**：

```dart
// V8: while (Double(integer / radix).Exponent() > 0) —— DiyFp 语义阈值 2^53
while (integer / radix >= _kTwoPow53) {
  integer /= radix;
  integerDigits.add(0);       // ≥2^53 的大整数低位在 double 里已不可分辨，垫 '0'
}
```

注释专门说明：`(2**53*36).toString(36)` 与 `(2**53*36+1)` 在 V8 里输出**相同的字符串**——这不是 bug，是 V8 的固有行为，移植必须保真。

**正确性如何证明？** `tools/token_corpus.mjs` 用真 Node（真 V8）以固定 seed=42 生成 10 万条 `tweetId,radix36,token` 语料 CSV（含 2^53 邻域、进位链等 77 个边界向量），Dart 侧测试逐字符对账——50 万+ 随机样本位级一致（README §二）。

### 8.3 error.dart —— sealed class：Dart 版的 Rust enum

`lib/core/error.dart` 定义两棵错误树。**解析域七类**：

```dart
sealed class ParseError implements Exception {
  String get code;                                   // 'E01' ~ 'E07'
}
final class UrlInvalid       extends ParseError { ... }  // E01 链接非法（零网络请求）
final class NetworkTimeout   extends ParseError { ... }  // E02 网络异常/超时（退避重试）
final class RateLimited      extends ParseError { ... }  // E03 429/403 风控（触发备源）
final class TweetNotFound    extends ParseError { ... }  // E04 404/dogpage/空{}（含锁推形态）
final class NotVideoTweet    extends ParseError { ... }  // E05 无视频条目
final class RestrictedContent extends ParseError { ... } // E06 敏感内容（不加载缩略图）
final class EndpointDrift    extends ParseError { ... }  // E07 接口结构漂移（触发配置刷新）
```

对 Rust 工程师直接翻译成：

```rust
enum ParseError {
    UrlInvalid(String?), NetworkTimeout{..}, RateLimited(i32?),
    TweetNotFound, NotVideoTweet, RestrictedContent, EndpointDrift(String?),
}
```

`sealed` 的含义：子类只能在这一个库文件里声明 → 编译器知道全集 → **switch 必须穷尽否则编译失败**（每个错误类再配 `error_views.dart` 里一个视图，见 `ui/common/error_views.dart`，编译期保证"一物一视图"不漏）。

契约红线（`contracts/error_codes.md`，代码注释反复强调）：**HTTP 403 在解析语境 = 风控 E03（换备源/退避），在下载语境 = 直链签名过期（自动重解析刷新 URL），任何实现不得把 403 归入"锁推"提示**。这是初学者最易踩的语义坑。

**下载域三类**（`DownloadError`）：`retryable`（网络类，退避重试）/ `permanent`（404 等不可恢复）/ `urlExpired`（直链过期，自动刷新一次）。

### 8.4 backoff.dart —— 指数退避

`lib/core/backoff.dart`：纯计算类 `ExponentialBackoff`，序列 `800ms × 2^n + 抖动`，最多 3 次（800ms → 1.6s → 3.2s）。设计要点：

- **抖动可注入**（`JitterFactory` 类型）：测试注入零抖动实现，即可确定性地断言精确等待序列——"策略对象不持有定时器，等待由调用方执行"。
- 同一策略在引擎侧还有个孪生实现 `download_engine.dart` 的 `BackoffPolicy`（并行开发期的产物，见 §10.2 开头注释）。

### 8.5 app_strings.dart —— 文案收口

全部用户可见中文文案是 `abstract final class AppStrings` 里的 `static const String`（196 行）。规则：任何 Widget 禁止硬编码文案，必须引用常量。好处：话术审核收口一处改全库，未来多语言只翻这一个文件。PRD 指定话术（免责声明、NSFW 提示）逐字保留。

---

## 9. parse/：解析层

解析层的职责：**输入 Tweet ID，输出 `ResolveResult`（推文元数据 + 按码率降序的 MP4 直链列表）；失败抛七类 ParseError 之一。**

### 9.1 models.dart —— 数据契约

`lib/parse/models.dart`（266 行）定义三个模型（字段与 `contracts/resolve.schema.json` 一一对应）：

- **`VideoVariant`**：一个可下载档位 = 一条 `video.twimg.com` 直链 + 码率 + 宽高 + 预估体积 + 清晰度标签。
  - 分辨率从哪来？**响应里没有分辨率字段**，只能从 URL 路径正则提取：`/vid/avc1/1280x720/` → `(1280, 720)`（`models.dart:48-55`）。
  - `qualityLabel`（`models.dart:108-114`）：按高度分桶 `>=1080/720/480/<480` 得 `1080p (Full HD)`…；高度缺失时按码率兜底映射。这是 UI 上"档位标识"的唯一来源。
  - 预估体积 = `bitrate × durationMillis / 8000`（bps×毫秒换算成字节），`_estimateBytes` 做了 2^53 预检 + int64 钳制（`models.dart:20-30`）——防畸形响应让 int 乘法回绕成负数，违反 schema 的 `minimum: 0`。这段溢出防御 C 工程师看着会很亲切。
- **`TweetMeta`**：一次解析的完整产出（作者/头像/正文/缩略图/时长/是否敏感/视频数/变体列表），带 `toJson/fromJson`（历史页离线渲染的数据源，入库快照用）。
- **`ResolveResult`**：`{tweet, parserVersion}` 信封，所有解析器统一产出。

另定义接口 **`TweetParser`**（`models.dart:264-266`）：

```dart
abstract interface class TweetParser {
  Future<ResolveResult> resolve(String tweetId, {int videoIndex = 0});
}
```

`videoIndex` 用于多视频推文选第 N 个视频。主源、备源、测试假解析器都实现它——UI 编排只认这个接口（§12.2）。

### 9.2 syndication_client.dart —— HTTP 客户端

`lib/parse/syndication_client.dart`（99 行）。**只做一件事：发一次 GET，把原始响应（状态码 + content-type + 文本体）带回来，不做任何语义判定。**

```dart
final response = await _dio.get<String>(url,
  options: Options(
    responseType: ResponseType.plain,      // 要原始文本，不要框架自动 jsonDecode
    validateStatus: (_) => true,           // 404/429/403 全放行，分类是 Parser 的事
    headers: {'User-Agent': config.primary.ua, 'Accept': 'application/json'},
    connectTimeout: ..., receiveTimeout: ...,   // 6s（配置可调）
  ));
```

两个"为什么"值得注意（注释里都写了）：

- **为什么保留原始文本而不自动解 JSON**：因为"200 + 空 `{}`"要原样特判（→ E04），404 的 dogpage 是 HTML 不是 JSON，提前 `jsonDecode` 会直接崩。
- **lang 回落**（`fetchWithLangFallback`，99 行处）：先 `lang=zh-CN` 请求，若返回的是"与语言相关的 4xx"（400~499 且排除 404/403/429 这些已有明确分类的）再回落 `en`。网络层异常不在此处理——那是退避重试的职责。

`dio` 是 Flutter 生态最流行的 HTTP 库（pub 包），这里经构造函数注入，测试换 mock。

### 9.3 syndication_parser.dart —— 主解析器（七分类状态机）

`lib/parse/syndication_parser.dart`（274 行）是解析层的心脏。`resolve()` 流程：本地算 token（<1ms）→ client 发请求 → `parseResponse()` 分类映射。**`parseResponse` 是纯函数（无 IO）**，测试直接回放夹具 JSON 断言分类——这是"夹具回放测试"的基础。

分类顺序（`syndication_parser.dart:80-117`）刻意设计为**状态码先于内容形态**：

```
HTTP 404            → E04 TweetNotFound（推文不存在/锁推常表现为 404）
HTTP 403 / 429      → E03 RateLimited（403 ≠ 锁推！是风控）
HTTP 5xx            → E02 NetworkTimeout（上游瞬时故障，可重试）
其余 4xx             → E07 EndpointDrift（接口漂移信号）
── 以下仅 200 ──
content-type 含 html → E04（dogpage 错误页可能伴随 200 返回）
body 为 '' / '{}' / 'null' → E04（无 token 请求的实测行为）
jsonDecode 失败      → E07
__typename != 'Tweet' → E07（结构漂移守卫，阈值来自端点配置）
possibly_sensitive == true → E06（敏感内容，UI 侧不加载缩略图）
mediaDetails 无 video/animated_gif 条目 → E05（纯文本推文，该字段可整体缺失）
```

随后 `_mapTweet()`（`syndication_parser.dart:120-229`）做字段映射，两个防御性设计：

- **只收集 `content_type == 'video/mp4'` 且 `bitrate > 0` 的变体**，按码率降序排（HLS/m3u8 流不暴露——DESIGN §12.9 裁剪决策，见 §16）。
- **`_safeIntOrNull` / `_safeStringOrNull`**（263-266 行）：所有字段读取防御式进行——类型突变（数字字段变字符串）、非有限值（JSON `1e999` 解出 Infinity）、超 int64 域，一律按"字段缺失"处理。注释解释了动机：上游结构漂移场景（E07 的设计场景）下，硬强转 `as int` 会让 TypeError 以异常形态逃逸 ParseError 契约，被编排层误兜底成 E02 网络错误。跨信任边界解析不可信数据，这是标准姿势。

### 9.4 endpoint_config.dart —— 端点配置与热更

`lib/parse/endpoint_config.dart`（334 行）。方案 A' 的核心：**把"X 接口长什么样"从代码里搬到数据里**。

配置结构（对照 `assets/config/endpoints.json`）：

```json
{
  "version": 1,
  "primary":   { "urlTemplate": "https://cdn.syndication.twimg.com/tweet-result?id={id}&lang={lang}&token={token}",
                 "ua": "Mozilla/5.0 ...", "timeoutMs": 6000 },
  "fallback":  { "enabled": false, "urlTemplate": "https://api.fxtwitter.com/status/{id}" },
  "driftGuard": { "typenameEquals": "Tweet", "requiredFields": ["user.screen_name"] }
}
```

`EndpointConfigRepository` 的加载顺序（`endpoint_config.dart:261-274`）：

```
内置 assets（打包进 App 的 json）
   → prefs 缓存的远端版本（版本号更高则整体原子替换）
   → 后台异步试远端拉取（remoteUrl 默认空 = 关闭，绝不影响离线可用）
   → 运行期 E07（结构漂移）触发时再主动刷新一次（onEndpointDrift）
```

细节都很"运维头脑"：三重可用性门禁（模板必须含 `{id}`、version>0、timeoutMs 在 [500, 30000]——下界防 dio 超时被禁用后请求无限挂起）；远端配置**先写配置体、最后写版本号作为提交点**（中途崩溃时旧版本号不会选中新配置，避免半提交）；任何失败一律回落保持现状不抛异常（因为远端刷新是 `unawaited` 的后台任务，异常逃逸=未处理异步崩溃）。

### 9.5 fxtwitter_parser.dart —— 备源

`lib/parse/fxtwitter_parser.dart`（337 行）。第三方镜像 API `api.fxtwitter.com/status/{id}` 的解析器，同样实现 `TweetParser` 接口，经配置 `fallback.enabled` 开关（默认关闭）。它要容忍两种已知响应形态（`videos[]` 带 `url` 直链 vs 带 `formats[]` 多码率列表）——README 记录了两评委核查结论矛盾，故按防御性双形态实现，开工当日以实测夹具对账（`assets/fixtures/fxtwitter_status_ok.json` 印证了三形态并存）。

---

## 10. download/：下载引擎

引擎三文件中最重要的是 `download_engine.dart`（989 行，全仓库最大）。建议阅读顺序：**先 task 后 engine**。

### 10.1 download_task.dart —— 任务实体与状态机

`lib/download/download_task.dart`（300 行）。

**(a) 状态枚举与转移表**（`download_task.dart:12, 64-90`）：

```
queued ──→ running ──→ completed（硬终态）
  │           │ └──→ failed / canceled / paused
  │           └────→ paused（用户暂停/429 冷却，保留 .part）
  └──→ paused / failed / canceled
paused ──→ queued（恢复/冷却结束） / canceled
failed ──→ queued（一键重试，重置退避与 URL 刷新标记）
```

合法转移以 `const Map<DownloadStatus, Set<DownloadStatus>> kTransitionTable` 显式声明，`withStatus()` 对非法转移抛 `StateError`——**把状态机 bug 从"运行期诡异行为"提前到"编码期异常"**，和 Rust 类型系统编码不变量是同一种思想。

**(b) 不可变快照 + copyWith**。`DownloadTask` 全部字段 `final`，状态演进永远是"复制一条新记录替换旧的"：

```dart
_apply(id, (t) => t.copyWith(status: DownloadStatus.running, bytesDone: 12345));
```

`copyWith` ≈ Rust 的结构体更新语法 `Task { ..old, status: Running }`。有个微妙坑：**区分"省略参数"与"显式传 null"**（比如 retry 要把 errorMessage 清空）——Dart 的可选参数无法区分两者，所以 `download_task.dart:232-254` 用了一个私有哨兵对象 `_kUnset` 作默认值。这是 Dart 生态的标准 idiom。

**(c) 业务键去重**。`.part` 断点文件路径由 `{tweetId}_{bitrate}` 确定性生成——如果同键两个任务并发跑，会以 append 模式交错写同一个文件，字节流直接损坏。所以 `enqueue` 对未终结任务做 (tweetId, bitrate) 去重，命中抛 `DuplicateActiveTaskException`（携带既有任务 id 供 UI 提示"已在队列中"）。终态不占业务键，同键可重新下载。

### 10.2 download_engine.dart —— 引擎本体

989 行，读之前先建立骨架认知。引擎持有一张任务表和一组原语：

```dart
final Map<String, DownloadTask> _tasks;        // id → 快照（唯一事实源）
final ParallelGate _gate;                       // 并发信号量（1-3，默认 2）
final StreamController<DownloadTask> _taskEvents;  // 任务事件广播流
final StreamController<EngineNotice> _noticeCtrl;  // 冷却开始/结束通知流
```

#### 10.2.1 ParallelGate —— 手写计数信号量

`download_engine.dart:112-156`。如果你写过 pthread 或用过 tokio 的 Semaphore，这段可以直接心读：

```dart
class ParallelGate {
  final Queue<Completer<void>> _waiters = Queue();   // 等待队列（Completer ≈ one-shot 信号）
  int _permits = 2, _active = 0;

  Future<void> acquire() {
    if (_active < _permits) { _active++; return Future.value(); }  // 快路径
    final c = Completer<void>(); _waiters.addLast(c); return c.future; // 挂起排队
  }
  void release() { if (_active > 0) _active--; _pump(); }          // 归还并唤醒队首
}
```

FIFO 唤醒，permits 可运行时调整（设置页"并发数"滑条即时生效）。为什么不用库？因为 Dart 标准库没有 Semaphore，而单线程模型下手写完全无竞态。

#### 10.2.2 SpeedWindow —— 3 秒滑动窗口速率估计

`download_engine.dart:78-109`。采样 `(时刻, 累计字节)` 进窗口，驱逐 3 秒前的旧样本，速率 = 窗口两端增量 / 时间跨度。比"瞬时速率"平滑，供 UI 显示 `2.4 MB/s` 与计算 ETA。

#### 10.2.3 调度：_pump 与 _runTask

```dart
void _pump() {
  if (_cooling || _disposed) return;
  while (!_cooling && _gate.availablePermits > 0) {
    // 在任务表里按入队顺序找第一个 queued 且未被拉起的任务
    ... _runTask(next.id);
  }
}
```

`_pump()` 是"有机会就填满并发额度"的泵：入队/恢复/重试/任务结束/冷却结束都会调它。`_runTask` 先 `_gate.acquire()` 拿许可，再进入核心的 `_attemptLoop`。注释点出一个并发细节：Dart async 函数体在**首个 await 之前是同步执行的**，所以 `_runningIds.add(id)` 放在函数开头就能防重复拉起——这是单线程协作式调度才会有的推理。

#### 10.2.4 单次下载 _performDownload —— HTTP 断点续传教科书

`download_engine.dart:589-769`，按注释编号走：

```
1. 对齐断点     .part 文件存在 → bytesDone = 文件实际长度（不信内存值）
2. Range 请求   dio.get(ResponseType.stream)，头 Range: bytes={bytesDone}-
3. 错误分流     429→全队列冷却；403/410→刷新直链；404→永久失败；5xx→瞬时错误退避
4. 206/200 三态  206=服务器支持断点，追加写
                200=范围被忽略，截断 .part 从零重写
                （content-range 起点与 bytesDone 不符 → 瞬时错误重来）
5. 流式写盘     await for (chunk in body.stream)：
                raf.writeFrom(chunk) → 每 64KB flush → 采样速率 → 500ms 节流广播进度
6. 总量校验     content-length ≠ 实写字节 = 短读（连接中断）→ 保留 .part 退避后续传
7. 转正         .part → {tweetId}_{bitrate}.mp4（rename 原子操作）
8. 入相册       调 GallerySaver（失败不阻断完成态，见 10.3）
```

三个内存纪律（对应 PRD "内存峰值 100MB" 指标）：`ResponseType.stream`（不把整个响应体读进内存）、64KB 固定缓冲循环写 `RandomAccessFile`（任意大文件内存恒定）、每 64KB 才 flush 一次（不是每 chunk）。

**控制信号优先级**（`download_engine.dart:704-709`）：每个任务有个 `_RunState`（cancelToken + 三个 bool 标志），写盘循环每收到一个 chunk 先查标志——`cancel > pause > cooldown`，用户意图永远优先于系统冷却。中断以 `_PauseSignal` 等私有异常冒出（§5.3），外层捕获后置状态。`.part` 永不删除，进度不丢。

#### 10.2.5 _attemptLoop —— 重试与自愈

`download_engine.dart:496-583` 的 while 循环捕获各类信号/失败并收敛状态：

- 网络类错误：指数退避（800ms×2^n+抖动）自动重试 3 次，仍失败 → `failed(retryable)`，UI 出"一键重试"。
- **403/410（直链签名过期）**：调注入的 `UrlRefresher` 回调——用 tweetId 重新走一遍解析拿到新直链，**只换 URL 不清进度**，然后 `continue` 重试且不计退避次数。每任务限一次（`urlRefreshed` 标记），手动重试会重置标记再给一次机会。
- 退避等待期间用户可能已按暂停/取消，等待后复查信号再决定走向。

#### 10.2.6 429 全队列冷却

`download_engine.dart:811-891`。任一任务收到 429 → **整个队列**冻结 30 秒：

```
_startCooldown():
  通知流广播 cooldownStarted(截止时刻)          → UI 顶部横幅"触发限速，稍后自动继续"
  所有 running 任务：置冷却标记 + cancelToken 中断（.part 保留）
  所有 queued 任务：置 paused(cooldown=true)

30 秒后（_scheduleCooldownEnd，带代际计数防旧定时器复活）:
  广播 cooldownEnded
  所有 pausedForCooldown 的任务自动回 queued → _pump() 重启
```

细节：冷却期间用户显式暂停的任务会**清除**冷却标记（`pause()`，370-373 行），冷却结束不把它拉起来——"冷却恢复只对无用户信号的任务生效"。冷却中再次 429 则延长截止时刻。

#### 10.2.7 接缝：DownloadStore 与 UrlRefresher

引擎与持久层的唯一耦合是 `DownloadStore` 接口（`download_engine.dart:179-181`，就一个 `upsert(task)` 方法），由 data 层的 `RepoDownloadStore` 适配实现（§12.4）。时钟（`NowFn`/`DelayFn`）与 URL 刷新回调全部注入——**引擎本文件零 platform import、零用户文案**，测试用假时钟 + 本地 mock HttpServer 即可全离线跑。

### 10.3 gallery_saver.dart —— 相册保存与权限降级

`lib/download/gallery_saver.dart`（81 行）。抽象接口 `GallerySaver` + 生产实现 `GalGallerySaver`（封装 `gal` 插件）。

设计核心是**权限被拒的完整降级路径**（PRD 权限最小化 + DESIGN §4.4）：

```
下载完成 → 尝试入册（此时才首次请求相册权限！首屏启动零权限）
  ├─ 同意 → Gal.putVideo(path, album: 'ClipVault') → albumSavedAt 落库
  └─ 拒绝 → 不抛异常、不中断任务：
            视频仍完整保留在 App 沙盒
            albumSavedAt 置空 → 历史页出现"重新保存至相册"入口
```

`saveVideo` 的契约是**永不抛异常**——一切失败收敛为返回值枚举（saved / permissionDenied / failed），保证"任务不因入册失败而中断"。

---

## 11. data/：持久层

### 11.1 技术选型：drift（SQLite ORM + 代码生成）

drift 是 Flutter 生态的类型安全 SQLite ORM。工作方式对 Rust 工程师很好理解：

1. 你用 Dart 类声明表（`lib/data/tables.dart`）；
2. build_runner（编译期代码生成器，≈ derive 宏）生成 `database.g.dart`（1743 行）——**这是生成物，不要读**；
3. 之后所有查询用类型安全的 Dart API 写，不再手拼 SQL 字符串。

### 11.2 tables.dart —— 全库唯一的表

`lib/data/tables.dart`（114 行）：`DownloadRecords` 单表 ≈

```sql
CREATE TABLE download_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tweetId TEXT NOT NULL,          -- 推文 ID（雪花，TEXT 存储防丢精度）
  variantUrl TEXT NOT NULL,       -- 选中直链（会过期）
  bitrate INTEGER NOT NULL,       -- 码率 bps
  status TEXT NOT NULL,           -- 'queued'/'running'/'paused'/'completed'/'failed'/'canceled'
  bytesDone INTEGER DEFAULT 0,    -- 断点续传基准
  bytesTotal INTEGER NULL,        -- 未知为 NULL（无 content-length）
  filePath TEXT NULL,             -- 转正后路径；partPath —— 断点文件路径
  tweetJson TEXT NOT NULL,        -- 推文元数据快照（历史页离线渲染）
  albumSavedAt DATETIME NULL,     -- NULL = 未入相册（"重新保存"入口依据）
  errorCode TEXT NULL, autoRetries INTEGER DEFAULT 0, ...
);
CREATE INDEX idx_download_records_tweet_id ON download_records(tweetId);
CREATE INDEX idx_download_records_status_updated_at ON download_records(status, updatedAt);
```

同文件还定义了 `DownloadStatus` 枚举与字符串互转函数（status 列取值的唯一权威来源）。

> **一个要留意的现状**：`tables.dart` 与 `download_task.dart` 各有一个同名 `DownloadStatus` 枚举（并行开发的产物），桥接处按 `name` 字符串互转，引用处以 `tbl.` / `dt.` 前缀隔离（`task_tile.dart:25-27`）——就是 C 里两个头文件同名 struct 各自命名空间的感觉。

### 11.3 database.dart 与 history_repository.dart

`database.dart`（56 行）：`AppDatabase` 类，executor（数据库连接）一律构造注入——生产是 `LazyDatabase`（首次查询才真正打开 `appDocuments/xdown.db`），测试传 `NativeDatabase.memory()`（内存库跑同样断言）。

`history_repository.dart`（274 行）：全部 SQL 读写的**唯一入口**。四类方法：

- **响应式查询**：`watchAll()` / `watchByStatuses()` 返回 `Stream<List<DownloadRecord>>`。drift 的魔法在这：**表数据一变，查询自动重发，新结果推给订阅者**（底层是 SQLite 的 watch 钩子）。UI 的"下载列表实时刷新"整条链路就靠它（§14 时序图）。
- **写入**：`createTask` / `apply`（自动覆写 updatedAt）/ `updateProgress` / `markAlbumSaved` …
- **启动恢复**：`recoverOnStartup()`（§11.4）。
- **缓存统计**：`computeCacheStats()` 只统计"可清理行"（completed/failed/canceled）的文件体积，与设置页"一键清理"口径严格一致——进行中任务的 .part 是活动进度，不可清也不计入，避免"统计大于可清理"的口径漂移。

一个契约细节：时间戳读出统一经 `_utcAlbumSavedAt` 归一化为 UTC（drift 读回映射为本地时区 DateTime，会破坏往返相等性——注释里有完整解释）。

### 11.4 启动恢复（与 main.dart 联动）

App 被杀/崩溃后重启时（`main.dart:59-107` `_bootstrapRecovery`）：

```
免责声明闸门放行（未同意条款前不恢复，避免未同意就发网络请求）
  → repo.recoverOnStartup()：读出全部未完成记录（queued/running/paused）
  → 逐条映射回引擎任务（id 约定 rec_{行主键}）
  → engine.restoreFrom(tasks)：
       .part 仍在 → bytesDone = 文件实际长度（真断点续传）
       .part 丢失 → 归零重下（不会遗留 UI 可见但永不调度的"僵尸行"）
```

---

## 12. ui/：界面层

### 12.1 main.dart 与 app.dart —— 入口与外壳

`main.dart`（167 行）做四件事：限制图片内存缓存 30MB（`PaintingBinding.instance.imageCache`）；建 Riverpod 容器并接上生产 overrides（缓存统计/清理绑定到历史仓库）；`runApp` 挂载 `XdownApp`；不阻塞首帧地跑启动恢复。

`app.dart`（156 行）是壳：MaterialApp（中文 locale、Material 3 亮暗主题跟随系统）→ `DisclaimerGate` → `HomeShell`（3 Tab + IndexedStack 保活）。

**`DisclaimerGate`**（`app.dart:57-109`）是合规闸门：首次启动（或条款版本升级）强制弹《使用协议》，不同意即退出。关键实现细节：**未同意前根本不挂载 HomeShell**（返回空的 `SizedBox.expand`），所以首页的剪贴板观察者、分享冷启动消费都不存在——杜绝"清晰度 Sheet 叠在免责弹窗上被绕过"的路径。版本化机制：`SettingsState.needsDisclaimer = 已同意版本 < 当前条款版本`（`settings_controller.dart:51`）。

### 12.2 home_screen.dart —— 首页与解析编排

`lib/ui/home/home_screen.dart`（438 行）。

**状态部分**（文件上半）：`HomeParseController` 是一个 Riverpod `Notifier`，状态机 `idle → parsing → resolved/error`：

```dart
Future<void> parse(String input) async {
  final tweetId = extractTweetId(text);      // core 纯函数
  if (tweetId == null) { state = ...E01; return; }   // 零网络请求
  state = ...parsing;                        // UI 切骨架屏
  final result = await _resolveWithRetry(tweetId);   // 编排
  state = ...resolved(result);               // UI 自动弹清晰度 Sheet
}
```

`_resolveWithRetry`（119-156 行）是解析编排的精华，双层循环：

```
外层：E02 网络类 → 指数退避重试（最多 3 次，期间骨架屏持续）
内层：E07 结构漂移 → 端点配置仓库 onEndpointDrift() 刷新配置
        → 拿到新配置 → invalidate 重建解析器 → 重试一次（免发版自愈链路）
      其他错误类 → 直接透出给错误视图
```

**装配部分**（文件下半的 providers）：`endpointConfigRepositoryProvider`（内置 assets → prefs 缓存 → 后台远端）→ `tweetParserProvider`（用当前配置构造 `SyndicationParser`）——测试 override 后者即可注入假解析器。

**UI 部分**：剪贴板横幅（点击解析）+ 输入框（清空/粘贴）+ 解析按钮 + 四相态内容（idle 空贯 / parsing 骨架卡 / error 七类视图 / resolved 预览卡）+ 最近解析（内存态，最多 5 条）。`ref.listen` 监听解析成功自动弹 `QualitySheet`（`_sheetOpenedFor` 标记防重复弹）。

**入队快照**（252-258 行）：点"开始下载"时把 `TweetMeta.toJson() + selectedVariant` 序列化成 JSON 字符串随任务入库——历史页因此**无需再发任何网络请求**就能离线渲染缩略图/作者/文案。

### 12.3 quality_sheet.dart —— 清晰度选择

`lib/ui/sheet/quality_sheet.dart`（231 行）。底部弹层：预览卡 + 多视频 Chip 切换（经 `onSwitchVideo` 回调按 `videoIndex` 重新解析）+ 档位列表（防御性再排一次降序；行模板 `720p (HD)` / `2.18 Mbps · 约 24.5 MB · MP4`）+ 开始下载按钮。默认高亮档由调用方按设置传入（"省流 720p" 偏好 → 降序列表中首个 720p 档，找不到回落最高码率，`home_screen.dart:429-437`）。提交后按钮禁用 + 关闭 Sheet（连点防抖，同变体只入队一次）。

### 12.4 task_tile.dart —— UI 与引擎/持久层的接缝（装配重地）

`lib/ui/downloads/task_tile.dart`（753 行）。文件头注释自称"UI 层与持久层/引擎层的唯一接缝"，包含五块内容：

**(a) `TaskItem`**：drift 行记录 → 纯展示模型（解析 tweetJson 快照得到缩略图/标题/作者；分区判断 `isActive/isQueued/isFailed/isHistory`；`needsResave` = 完成但未入册 → 出"重新保存"入口）。

**(b) `DownloadCommands` 接口 + `EngineDownloadCommands` 实现**：UI 只认抽象命令（enqueue/pause/resume/cancel/retry），测试注入假实现。生产实现的**入队流水线**值得细读（`task_tile.dart:197-244`）：

```
enqueue(tweetId, variant, tweetJson):
  1. 先补交因"仅 Wi-Fi"挂起的任务（网络可能已恢复）
  2. 第一道业务键去重（引擎内已有同 (tweetId,bitrate) 活动任务 → 直接拒绝，不建行）
  3. 建持久化行（drift 自增主键 rowId）
  4. 仅 Wi-Fi 偏好开启且当前非 Wi-Fi → 行保持 queued 挂起（_heldBack 集合），
     监听连接流，Wi-Fi 恢复时批量补交（_flushHeld）
  5. 以 id = 'rec_{rowId}' 构造引擎任务 enqueue
     → 引擎侧去重命中（与第 2 步间的竞态兜底）→ 回滚删除刚建的行
```

`rec_{rowId}` 是**引擎任务 id（String）与数据库行主键（int）的桥接约定**，全仓库通用。

**(c) `RepoDownloadStore`**：实现引擎定义的 `DownloadStore` 接口——引擎每次状态演进调 `upsert(task)`，这里解析出 rowId 把快照写回 drift（§14 时序图的数据回写边）。

**(d) Riverpod 生产装配**（文件尾部一串 Provider）：数据库 → 仓库 → 引擎（注入 store/gallerySaver/下载目录 `appDocuments/downloads`）→ 命令层 → `downloadsWatchProvider`（仓库 `watchAll()` 流映射为 TaskItem 列表，**UI 订阅它即得实时刷新**）→ `coolingProvider`（429 冷却横幅）。并发数设置在此接线到 `engine.concurrency`。

**(e) 格式化纯函数**：`formatBytes/formatSpeed/formatEta/formatElapsed/formatDateTime`——`24.5 MB`、`2.4 MB/s`、`约 1:23` 这些展示字符串的唯一来源。

### 12.5 其余界面

- **downloads_screen.dart**（136 行）：下载 Tab。四分区列表（进行中/等待队列/失败/历史）+ 429 冷却横幅（订阅 `coolingProvider`）。数据全部来自 `downloadsWatchProvider`，本文件无任何命令逻辑。
- **task_tile 的 `TaskTile` Widget**（579-741 行）：单任务行。进行中行 = 缩略图 + 标题 + `720p (HD) · 下载中` + 进度条与百分比同行 + `12.3 MB / 24.5 MB · 2.4 MB/s · 约 1:23 · 已用 0:45` + 暂停/取消按钮（按状态切换 暂停/继续/取消/重试）。历史行点击进详情页。
- **history_screen.dart**（216 行）：历史详情。操作集：播放（`PlayerScreen`）/ 系统分享 / 重新保存至相册（`albumSavedAt` 为空时）/ 删除（级联取消引擎任务 + best-effort 清理物理文件）。命令同样走 `HistoryCommands` 抽象。
- **settings_screen.dart**（180 行）：我的 Tab。免责声明重看、画质偏好（最高/720p 省流）、并发数 1-3、仅 Wi-Fi 下载、缓存占用与一键清理。
- **common/**：`preview_card`（预览卡：头像/昵称/正文两行/封面时长）、`parse_skeleton`（解析中骨架屏 + 秒数计时）、`error_views`（七类错误各一个视图 + 一键重试）、`disclaimer_dialog`（PRD 逐字话术的协议弹窗）。

---

## 13. 周边模块

### 13.1 clipboard_watcher.dart —— 剪贴板监听

`lib/clipboard/clipboard_watcher.dart`（70 行）。设计要点全部为了**合规与礼貌**：

- 只在 App **resume**（从后台回前台）时读一次剪贴板（Android 10+ 前台读取合规；不是后台轮询）；
- 读取结果过 `extractTweetId` 判定，不是推文链接就静默忽略（零网络请求）；
- 命中 → 置待处理状态 → 首页渲染**内联横幅**（"检测到推文视频链接，点击立即解析"，用户主动点击才发起解析，比 PRD 原案"自动弹浮窗"更克制）；
- 同一链接去重（consume 后 `_lastConsumed` 记忆，不重复打扰）；
- `ClipboardReader` 抽象注入，widget 测试不触真剪贴板。

实现上它是个混入 `WidgetsBindingObserver`（生命周期回调接口）的 Riverpod `Notifier`——`didChangeAppLifecycleState(resumed)` 触发读取，首页 `initState` 注册、`dispose` 反注册。

### 13.2 share_receiver.dart —— 系统分享接收

`lib/sharing/share_receiver.dart`（82 行）。抽象 `ShareReceiver`（initialText 一次性 + sharedText 流）+ 生产实现封装 `receive_sharing_intent` 插件（Android manifest 的 intent-filter 声明分享 x.com/twitter.com 链接时唤起本 App）。首页监听它的流，分享文本自动填入并触发解析。iOS 侧 Share Extension 属 P1 待补（README 回归清单 #5）。

### 13.3 player_screen.dart —— 内置播放器

`lib/player/player_screen.dart`（174 行）。`video_player` 插件封装：本地文件初始化 → 全屏黑底播放；手势层：横滑按屏幕宽度比例映射进度增量、左半屏竖滑调音量、点按切换控件显隐。全屏旋转与 PiP 属 P1（真机验证前不揭示入口）。

### 13.4 settings_controller.dart —— 设置

`lib/settings/settings_controller.dart`（171 行）。`AsyncNotifier<SettingsState>`，读写 `shared_preferences`（平台键值存储，≈ 轻量 ini/registry）。管理：免责版本、画质偏好、并发数、仅 Wi-Fi、自动清理参数。`CacheStore` 抽象（缓存统计/清理）在 `main.dart` 由仓库实现 override——设置页的"缓存占用"数字实际来自 §11.3 的 `computeCacheStats`。

---

## 14. 端到端时序

把所有模块串起来。**场景：用户复制了一条推文链接，打开 App，选 720p 下载，中途 429 被冷却，30 秒后自动续传完成并入相册。**

```
[系统] App resume
  └─ ClipboardWatcher.didChangeAppLifecycleState(resumed)        §13.1
       └─ 读剪贴板 → extractTweetId 命中 → state = 链接文本
            └─ HomeScreen rebuild → 渲染横幅
[用户] 点横幅
  └─ HomeParseController.parse(text)                              §12.2
       ├─ extractTweetId → "1790637656616943991"（15~20 位 + int64 校验）
       ├─ phase=parsing → 骨架屏
       ├─ tweetParserProvider → SyndicationParser（当前端点配置）
       │    ├─ getToken(id)  ← core：V8 位级移植的 36 进制算法      §8.2
       │    ├─ SyndicationClient GET cdn.syndication.twimg.com    §9.2
       │    └─ parseResponse 七分类 → ResolveResult               §9.3
       │         （E02→退避重试 / E07→配置热更重试一次，均失败才透出）
       └─ phase=resolved → 自动弹 QualitySheet
[用户] 选 720p，点"开始下载"
  └─ HomeScreen._startDownload → 快照 tweetJson
       └─ downloadCommandsProvider.enqueue(...)                   §12.4
            ├─ 业务键去重检查
            ├─ HistoryRepository.createTask → INSERT 行（rowId=42）
            ├─ DownloadEngine.enqueue(id='rec_42') → _pump()
            └─ 首页 toast"已加入下载队列"
[引擎] _runTask('rec_42') → gate.acquire()（并发 2 内，立即放行）
  └─ _performDownload                                            §10.2.4
       ├─ .part 不存在 → bytesDone=0
       ├─ GET video.twimg.com/...（ResponseType.stream）
       ├─ await for (chunk) → raf.writeFrom → 每 64KB flush
       │    └─ 每 500ms：_apply(copyWith(bytesDone,speed,eta))
       │         ├─ RepoDownloadStore.upsert → UPDATE 行 42
       │         └─ drift 表变更 → watchAll() 推送新列表
       │              → downloadsWatchProvider → 下载 Tab 自动刷新
       ├─ ⚡ 收到 429
       │    ├─ _startCooldown：通知流广播、中断所有 running、暂停所有 queued
       │    │    └─ coolingProvider → UI 横幅"触发限速，稍后自动继续"
       │    ├─ 本任务 paused(cooldown=true)，.part 保留
       │    └─ 30s 后 _scheduleCooldownEnd：回 queued → _pump 续传
       │         （续传请求带 Range: bytes={bytesDone}-，206 追加写）
       ├─ 写满 → content-length 校验 → .part rename 为 {tweetId}_{bitrate}.mp4
       └─ _saveToGallery                                          §10.3
            ├─ 首次触发相册权限弹窗（此前 App 零权限）
            ├─ Gal.putVideo(path, album:'ClipVault') → albumSavedAt 落库
            └─ （若被拒：沙盒保留 + 历史页出"重新保存"入口）
[用户] 下载 Tab 看到 42 号任务转 completed；历史区点击进详情
  └─ HistoryScreen：播放 / 分享 / 重新入册 / 删除                   §12.5
```

**App 被杀重启**：`main.dart` 启动恢复把未完成行（含还挂在 paused 的 42 号）重新交给引擎，`.part` 文件实际长度即断点，从断点继续（§11.4）。

---

## 15. 测试与工具链

全仓库的测试纪律：**全部测试离线可跑**（`flutter test`，无网络、无模拟器、无真机）。手段就是前文反复出现的注入：夹具回放、本地 mock HttpServer、drift 内存库、假时钟（`fake_async`）、假剪贴板/假连接检查器。

```
test/
├── core/        token 位级对账（10 万条 V8 语料 CSV）、URL 提取边界、退避序列
├── parse/       夹具回放：assets/fixtures/ 七个真实/合成响应 → 断言七分类与字段映射
├── download/    引擎全行为：Range 三态、并发上限、暂停恢复、429 冷却、断点恢复
│                （mock HttpServer + 临时目录 + 假时钟）
├── data/        仓库（内存 SQLite），含缺 sqlite3.dll 时回落 WasmDatabase
└── ui/          widget 测试（假解析器/假命令层）
```

`tools/` 三个 Node 脚本是**宿主机工具**（不进 App），构成"上游接口漂移哨兵"：

| 脚本 | 作用 |
|---|---|
| `token_corpus.mjs` | 用真 V8 生成 10 万条 token 语料（seed=42 确定性），供 Dart 单测逐字符对账 |
| `fetch_fixtures.mjs` | 真实请求端点录制/刷新夹具；与旧夹具 diff，**漂移或录制失败退出码 1**（CI 哨兵） |
| `check_contract.mjs` | 夹具 ↔ `contracts/resolve.schema.json` ↔ `error_codes.md` 双端一致性校验 |

`bin/smoke.dart`：真端点 E2E 冒烟（解析 200 + 有效 token + Range 下载前 64KB 校验）。

`contracts/` 是双端（Dart 测试 + Node 校验）共享的单一事实源：`resolve.schema.json` 约束 ResolveResult 信封（variants 排序与 mp4-only 由两个契约测试程序化断言，schema 表达不了）；`error_codes.md` 是 E01~E07 + DownloadError 的语义表。

CI（`.github/workflows/ci.yml`）：main 分支每次推送 → 分析 + 测试 + 构建 Android APK / iOS IPA → 滚动发布到 GitHub Releases `continuous` 标签。

---

## 16. 已知限制与未完成项

读代码时你会遇到这些"刻意的未完成"，都有注释或 README 申报，不是疏漏：

1. **HLS/m3u8 不支持**（DESIGN §12.9）：只暴露 progressive MP4 直链。PRD 3.3 的"FFmpeg TS 合成"被裁剪——X 的视频推文绝大多数同时带 MP4 变体，HLS-only 极罕见；引入 FFmpeg 的体积成本不值。
2. **t.co 短链不解**（P1）：需要 HEAD 跟随重定向，P0 阶段短链不命中 E01。
3. **iOS Share Extension**：需 Xcode 添加 target，P1 交付代码 + 配置文档（README 回归清单 #5）。
4. **真机回归项**：开发机无 JDK/Android SDK/macOS，gal 入册、权限弹窗时序、前台服务通知、PiP、后台保活等 8 项留待补装环境后回归（README 第三节完整清单）。
5. **两套同名 `DownloadStatus` 枚举**（§11.2）：并行开发产物，按 name 字符串桥接，属已申报的技术债。
6. **引擎内 `BackoffPolicy` 与 core `ExponentialBackoff` 是孪生实现**：集成时可委托合一（`download_engine.dart:41-45` 注释）。

---

# 附录 A：Dart 语法糖速查表

读代码卡住时查这里：

| 看到的写法 | 含义 |
|---|---|
| `Future<T> f() async { ... }` | 异步函数；内部可 `await`，返回值自动包 Future |
| `await expr` | 挂起等结果（≈ Rust `.await`） |
| `x?.field` / `x?.method()` | 空安全成员访问（x 为 null 则整体为 null） |
| `x ?? y` | 空合并默认值（`unwrap_or`） |
| `x!` | 断言非空（`unwrap()`，可能抛） |
| `as T` / `is T` | 强转（失败抛异常）/ 类型判断（`as?` 无，用 `is` + 自动提升） |
| `(a, b)` / `(x: 1)` | record 元组 / 带字段 record（Dart 3 积类型） |
| `=> expr` | 函数体简写 `=> { return expr; }` |
| `..method()` | 级联：对同一对象连续操作 |
| `...list` / `...?nullableList` | spread 展开进集合 |
| `for (final x in xs) ...` | 迭代（集合元素语法里也可用） |
| `@(注解)` | 元数据（生成器/工具读取） |
| `part 'x.g.dart'` | 声明"本库的生成代码在 x.g.dart"（≈ include 生成物） |
| `library;` | 文件级文档注释的挂载点（无实义） |
| `late final x = ...` | 延迟初始化的字段（首访问才赋值） |
| `required` | 命名参数必填 |
| `Object?` / `dynamic` | 任意类型（前者仍做空安全检查，后者完全动态） |
| `sealed` / `final class` | 封闭继承层级（穷尽 switch 的前提）/ 禁止继承 |
| `abstract final class` | 仅供静态成员命名的工具类（≈ 命名空间） |
| `unawaited(future)` | 显式声明"故意不等这个 Future" |
| `Completer<T>` | 手工完成 Future 的句柄（one-shot 信号量） |

# 附录 B：术语表

| 术语 | 一句话解释 |
|---|---|
| **pub / 依赖** | Dart 的包管理器与包仓库（≈ cargo/crates.io），依赖声明在 pubspec.yaml |
| **Provider（Riverpod）** | 全局懒单例工厂 + 订阅刷新；read=取实例，watch=订阅变化重建 |
| **组合根** | main.dart 里统一装配生产实现（数据库、引擎、仓库）的地方 |
| **isolate** | Dart 的并行单元，不共享内存的消息传递模型（≈ 轻量进程） |
| **Widget / build** | 不可变 UI 配置对象 / 状态→界面树的纯函数；框架 diff 后渲染 |
| **setState** | 标记"状态变了"，请求重跑 build |
| **Future / Stream** | 一次性异步结果 / 异步事件序列（≈ promise / channel） |
| **CancelToken** | dio 的请求取消句柄（引擎用来中断下载流） |
| **RandomAccessFile** | dart:io 的文件句柄（≈ C 的 FILE*，可定位读写） |
| **drift** | 类型安全 SQLite ORM；`.g.dart` 为生成代码 |
| **shared_preferences** | 平台键值存储（≈ ini 文件），存设置 |
| **沙盒** | App 只能写自己的目录（documents/tmp），系统相册需经权限 API |
| **MethodChannel** | Dart ↔ 原生（Kotlin/Swift）代码的桥接通道 |
| **syndication 端点** | X 为嵌入组件提供的公开推文数据接口，带 token 校验 |
| **dogpage** | X 的 404 错误页（页面有只狗的插画），本 App 用它判 E04 |
| **断点续传 / .part** | HTTP Range 请求按字节偏移续传；未完成的临时文件 |
| **转正** | 下载完成后 `.part` 原子 rename 为 `.mp4` 的动作 |
| **夹具（fixture）** | 录制的真实 API 响应样本，用于离线回放测试 |
| **契约（contract）** | `contracts/` 下跨端共享的数据结构/错误码定义，单一事实源 |
| **E01~E07** | 解析域七类错误码（见 §8.3 表） |
| **429 冷却** | 被限速后全队列暂停 30s 再自动恢复的机制 |
