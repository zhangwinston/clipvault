/// 全局导航键：供引擎完成路径上的相册权限预解释弹窗定位页面上下文
/// （下载完成→自动入册可能发生在任何 Tab，弹窗需要一个稳定的挂载点）。
/// 独立成文件以避免 app.dart（壳）与 task_tile.dart（装配）互相导入。
library;

import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
