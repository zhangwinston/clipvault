# ClipVault UI 视觉评审报告与改进建议

> **评审方法**：本次让评审代理**看真实界面**而非读代码想象——先用 Flutter golden 渲染管线（`test/ui/ui_capture_test.dart`，@Skip 不进 CI）截取 11 张真实屏幕 PNG（412×916@2x、中文字体、M3 亮暗双主题），再由 workflow（5 个维度评审代理 + 5 个对抗核验代理，共 10 代理、299 次工具调用）对截图做视觉分析并与源码逐行交叉验证。
> **核验强度**：核验代理不只看图——对关键断言做了**像素级采样**（色值、占比、间距、连通域），量化数据写进每条判定。25 条发现：**20 CONFIRMED / 5 ADJUSTED / 0 驳回**；另修正了 3 处建议本身的缺陷。
> **已知噪声**：① 图片传输管线会给截图叠加"右上角红白角标"水印（像素采样证实不在真实 PNG 内），已在所有代理提示中声明忽略；② `disclaimer_gate.png` 是坏图（采集 harness 渲染异常，93% 纯黑），相关发现已按真机样式修正后保留核心。

---

## 一、总体诊断："朴素感"的三个量化根源

| # | 根源 | 像素实测证据 |
|---|---|---|
| 1 | **主色几乎不用** | 下载页 94.8% 为单一背景色，主色 #00696F 仅占 **0.2%**；设置页 0.4%；首页是唯一达到 2.5% 的页面——且几乎全部来自唯一的"解析"实心按钮（`app.dart:47-60` 两主题仅 `fromSeed`，零组件层定制） |
| 2 | **零品牌视觉资产** | 全项目不存在任何 logo/插画/图片资产（`pubspec.yaml` 仅声明 config）；AppBar 纯文字标题、空态=小图标+两行灰字、"视频 App 的界面上没有任何视频/封面/播放视觉符号" |
| 3 | **无容器层次** | 列表无卡片无分隔线，深色模式 94.8% 单一近黑背景、最大容器色块 <1.1%；进度条轨道对背景对比度仅 **1.99:1**（低于 3:1 图形组件下限） |

一句话：**这是一个"Material 3 默认模板 + 灰度文本"的界面，品牌色、媒体感、层级容器三样都缺。**

## 二、跨维度主题（25 条发现归并为 7 个改进主题）

### 主题 A：全局主题定制层（根因修复，一次改动全局受益）
`color-type-1`(P1✓) + `impression-3`(P1◐) + `layout-2`(P1✓) + `color-type-5`(P1✓)

在 `app.dart` 补最小品牌主题：
- `cardTheme`：elevation 0、12px 圆角、`surfaceContainerLow` 底 → 任务行/设置分组包 `Card.filled`，亮暗同时获得分组层次（深色实测卡片容器有效：首页引导卡的 Card 占 16% 是唯一有层次的区域）
- `inputDecorationTheme`：filled + `surfaceContainerHighest` 底、聚焦 primary 2px → 替换当前"工程原型感"的黑灰细描边
- 深色显式提亮主色：`primary: Color(0xFF4CD9DE)`（核验注：fromSeed 显式 primary 参数可用）
- AppBar 双色字标（Clip=onSurface + Vault=primary）+ `surfaceContainer` 滚动着色（核验注：headlineLarge 需配套 toolbarHeight）
- 目标：主色+容器色覆盖率从 <1% 提到 10-15%

### 主题 B：状态色彩语义（最高频页面的扫视性）
`layout-1`(P1✓) + `color-type-2`(P1✓)

任务行四种状态长得一样（状态词埋在灰文本里、暂停进度条与进行中同色）：
- 状态→颜色映射：running=primary / paused=**primary 35% 透明**（核验修正：勿用 tertiary，会引入被主题 C 批评的蓝紫）/ queued=灰 / failed=error；状态词拆独立小标签（11px w600）或 8px 圆点
- 遥测行拆两级：速率+ETA 用 13px w500 onSurface、字节数/已用降级；ETA 可用 primary 强调
- 进度条：`minHeight 4→8` + 圆角 4；百分比升 13-14sp w600 + `FontFeature.tabularFigures()`（500ms 刷新防抖动——核验实测雅黑比例数字"11.7"46px vs "23.4"68px，尾部持续横移）
- 深色轨道色：核验修正——`onSurface.opacity 0.14` 复合后仅 1.4:1 比现状更差，需 **≥0.24** 或直接用 surfaceContainerHigh

### 主题 C：横幅组件统一（两处通栏色带，两种色相）
`color-type-3`(P1✓) + `layout-4`(P2◐) + `components-3`(P1✓)

冷却横幅是**蓝紫 #D6E3FF**（fromSeed 的 tertiary 落在蓝紫域），剪贴板横幅是**青绿 #CCE8EA**——同类提示两种色相，且都通栏贴边无圆角无外边距：
- 统一横幅组件：`secondaryContainer` 底（保持品牌青绿）+ margin(16,8,16,0) + 12px 圆角 + 左侧 4dp accent 竖条 + 前景显式 `onSecondaryContainer`
- 冷却警示图标换琥珀色（亮 #B26A00 / 暗 #FFB95C）形成 warning 语义；倒计时数字 tabularFigures + w600

### 主题 D：行操作可辨识与防误触
`components-2`(P1✓) + `usability-1`(P1✓)

行尾裸图标按钮（‖ 与 × 热区 48dp **零间隙贴邻**、取消无 error 色与暂停同权重、触屏 tooltip 不可见、Icons.close 惯例读作"关闭"而非"取消任务"）：
- 失败/取消行：裸 refresh 图标 → `FilledButton.tonal` 文字按钮"重试"（36 高，图标 18 + 13sp 文字）
- 进行中/暂停行：取消图标染 error 或换 `Icons.cancel_outlined`，按钮间加 4-8dp 间距
- 进阶：取消收进右滑 Dismissible（errorContainer 底 + delete 图标），行尾保持单图标干净度

### 主题 E：历史详情页重排（层级倒挂）
`layout-3`(P1✓) + `usability-2`(P1✓)

"视频 App 的详情页里没有视频"：纯文字卡 + 下 60% 空白 + 破坏性删除按钮全宽独占底部（比主 CTA 播放权重更高）；`TaskItem.thumbUrl` 已存在但详情页没用：
- 卡片头部加 16:9 封面（复用列表行 `_thumb` 模式 + 时长徽标）；元数据改 AssistChip 行
- 播放升全宽 FilledButton(48) 主 CTA；分享/保存并排次级行；删除移 AppBar 右上 error 色 IconButton（确认弹窗已有）

### 主题 F：加载与反馈质感
`impression-5`(P2✓) + `components-5`(P2✓) + `components-4`(P1✓) + `impression-4`(P2✓)

- 骨架卡：升级为零依赖**扫光 shimmer**（ShaderMask 渐变条 900ms），且骨架结构与结果卡**上下相反**（骨架=头像在上媒体块在下；PreviewCard=封面在上头像在下）→ 改同构，消除解析完成瞬间布局跳变
- 解析中：16dp 迷你转圈放大到 24dp 移到文字左侧组成标准加载行；"取消解析"从右下角小文字链改**全宽 O outlinedButton**（31s 最坏等待的唯一出口）
- 错误卡：`errorContainer` 底 + `onErrorContainer` 标题 + 图标 40dp 圆形底座；主文案升 titleMedium（核验注：E04 已有 hint 行，补引导文案只需针对无 hint 的 E05/E06）
- 空态：48→72dp 图标置于 120px primaryContainer 圆底（或插画）；CTA 宽度收 60%

### 主题 G：首页动线与品牌首屏
`usability-4`(P1✓) + `layout-5`(P2✓) + `impression-2`(P1✓) + `impression-1`(P1◐)

- **合并双按钮为单一 CTA"粘贴并解析"**（有链接直接解析，为空读剪贴板再解析——`_parseInput`/`_pasteFromClipboard` 积木都在）；空输入且剪贴板无链接给 SnackBar 反馈（当前静默回 idle）
- 引导卡：三步加 ①②③ 编号圆标（24px primaryContainer 底）；零资产替代方案=层叠 16:9 渐变视频帧插画（#00696F→#4DD0D9，alpha 0.9/0.6/0.3）+ 白色播放圆钮
- 首启页：barrier 改 transparent 或 scrim 32%；品牌页加 primaryContainer 打底/渐变 + 64px 圆角 logo（#00696F 底白色 ▶）；弹窗延后 400-600ms（核验修正：坏图导致的"黑屏"描述不成立于真机——真机是白底中灰遮罩，但"首帧弹模态+品牌页零设计"核心成立）

### 主题 H：设置页信息架构
`usability-3`(P1✓) + `usability-5`(P2◐)

- "诊断"对普通用户是天书 → 并入"关于"，"端点配置版本"改"解析服务配置"；免责副标题版本相等时显示"已同意 v1"
- 五分组各包 Card（surfaceContainerLow、圆角 16）+ 组内 Divider
- 并发数滑条（嵌副标题、轨道窄）→ `SegmentedButton<int>` 三段
- 下载页分区计数"(N)"灰字 → primaryContainer 胶囊徽章；"历史"区改 `ExpansionTile` 默认收起（核验修正：历史区在最后，"顶出首屏"不成立，实际代价是页面无限增长）

## 三、核验中被戳穿的视觉误读（流程有效性佐证）

视觉工具的 4 处幻觉均被"代码+像素"双验戳穿并拒采：home_idle 的"查看已下载按钮"（引导卡无任何按钮）、home_error 的"重试按钮"（E04 不可重试无按钮）、downloads 首轮"骨架屏"误读（实为真实数据行）、disclaimer 坏图的"鲜红色块"（渲染伪影）。**所有写进本报告的视觉断言都经过像素级或代码级复核。**

## 四、实施路线图

| 波次 | 内容 | 量级 | 预期效果 |
|---|---|---|---|
| **1. 主题与色彩基建** | 主题 A 全部 + 状态色映射（B 的颜色部分）+ 横幅统一（C）+ 进度条加粗/轨道色 | S-M（~3 天） | 主色覆盖率 <1%→10-15%；深色从"平闷"到有层次；横幅色相统一 |
| **2. 组件质感** | 任务行重排（B 剩余）+ 行操作按钮（D）+ 错误/空态强化 + 骨架扫光/同构 + 设置页卡片化（H） | M（~1 周） | 最高频页面扫视性/防误触；加载与错误态达到行业水准 |
| **3. 品牌与结构** | 品牌 logo/插画资产 + 首页 CTA 合并（G）+ 历史详情重排（E）+ 分区徽章/折叠 | M-L（~1-2 周） | "模板 demo 感"→消费级视频工具气质 |

**每波完成后可重跑截图管线对比**：`flutter test --update-goldens test/ui/ui_capture_test.dart`（先注释 @Skip）→ goldens/ 目录出图，用同一套视觉评审验证改进效果——这是本次建立的可复用闭环。

## 五、明细索引（25 条原始发现）

| id | 级别 | 一句话 | 核验 |
|---|---|---|---|
| impression-1 | P1 | 首启品牌页被默认 black54 遮罩压暗、弹窗无延后 | ◐（坏图修正后核心成立） |
| impression-2 | P1 | 全 App 零品牌视觉资产，无媒体感 | ✓ |
| impression-3 | P1 | 主色占比 2.5% 以下，近全灰度 | ◐（量化证实，细节修正） |
| impression-4 | P2 | 错误卡无 errorContainer、图标 24px 裸放 | ✓ |
| impression-5 | P2 | 骨架仅透明度呼吸无扫光，与结果卡形态相反 | ✓ |
| layout-1 | P1 | 任务行 5 行灰文本堆叠，状态无色彩层级 | ✓ |
| layout-2 | P1 | 四分区无容器无分隔，标题像多出来的文字行 | ✓ |
| layout-3 | P1 | 历史详情层级倒挂：删除全宽独占、无封面 | ✓ |
| layout-4 | P2 | 冷却横幅通栏无圆角与 AppBar 硬切 | ◐（色相/对比度描述修正） |
| layout-5 | P2 | 引导卡无编号层级，下 55% 空白无重心 | ✓ |
| color-type-1 | P1 | 全局主题零定制，94.8% 单一背景 | ✓ |
| color-type-2 | P1 | 状态无色彩语义，暂停/进行中进度条同色 | ✓ |
| color-type-3 | P1 | 冷却横幅蓝紫脱离品牌色系 | ✓ |
| color-type-4 | P1 | 遥测行 12px 单灰、无等宽数字、刷新抖动 | ◐（对比度实为 8.9-10:1 充足，抖动机理证实） |
| color-type-5 | P1 | 深色 94.8% 单一近黑，轨道对背景 2:1 | ✓（子建议 2 已修正为无效） |
| components-1 | P1 | 进度条 4dp 太轻，深色轨道 1.99:1 | ✓（轨道色建议已修正） |
| components-2 | P1 | 行尾双图标热区零间隙，取消无破坏性暗示 | ✓ |
| components-3 | P1 | 两类横幅无圆角不统一 | ✓ |
| components-4 | P1 | 空态/错误态单薄，无视觉锚点 | ✓ |
| components-5 | P2 | 16dp 迷你转圈、取消入口不显眼 | ✓ |
| usability-1 | P1 | 行操作裸图标无标签，新手不可辨识 | ✓ |
| usability-2 | P1 | 详情页无封面，下 60% 空白 | ✓ |
| usability-3 | P1 | 设置页术语天书、控件裸排无分组容器 | ✓ |
| usability-4 | P1 | 双按钮动线冗余，空输入零反馈 | ✓ |
| usability-5 | P2 | 分区裸标题平铺、历史区无折叠 | ◐（"顶出首屏"方向修正） |

（✓=CONFIRMED，◐=ADJUSTED；完整证据链含像素实测数据见 workflow 产出 `wt6d02pkg.output`）
