import CFNetwork
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 剪贴板变化检测通道（P1-2 根治：iOS 16+ 每次程序化读取粘贴板都会弹
  /// 「已粘贴自…」系统横幅。读取 UIPasteboard.general.changeCount 不触发
  /// 该提示——Dart 侧先比对计数，仅内容真的变化时才读取文本，
  /// 把系统提示频次从「每次切回前台」降到「每次真的复制了新内容」。）
  private static let clipboardChannelName = "clipvault/clipboard"

  /// 系统代理读取通道（DESIGN §6.9）：dio 的 dart:io HttpClient 默认不读
  /// 系统代理（NSURLSession 会自动跟随）——Dart 侧经此通道取
  /// CFNetworkCopySystemProxySettings 的 Wi-Fi 手理代理，注入 findProxy。
  private static let networkChannelName = "clipvault/network"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ClipVaultClipboard") {
      let channel = FlutterMethodChannel(
        name: AppDelegate.clipboardChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        switch call.method {
        case "getChangeCount":
          result(UIPasteboard.general.changeCount)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ClipVaultNetwork") {
      let channel = FlutterMethodChannel(
        name: AppDelegate.networkChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        switch call.method {
        case "getSystemProxy":
          result(Self.systemProxySettings())
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  /// 读系统级代理（当前网络的 Wi-Fi 手动代理）。
  /// 优先 HTTPS 专属配置，回落 HTTP 配置（CONNECT 隧道共用）；未启用 → nil。
  private static func systemProxySettings() -> [String: Any]? {
    guard
      let settings = CFNetworkCopySystemProxySettings()?
        .takeRetainedValue() as? [String: Any]
    else {
      return nil
    }

    // HTTPS 专属（部分代理工具会分别配置）
    if let host = settings[kCFNetworkProxiesHTTPSProxy as String] as? String,
      !host.isEmpty,
      let port = settings[kCFNetworkProxiesHTTPSPort as String] as? Int,
      port > 0
    {
      return ["host": host, "port": port]
    }

    // HTTP（HTTPS 经 CONNECT 隧道同路走）
    if let enabled = settings[kCFNetworkProxiesHTTPEnable as String] as? Int,
      enabled != 0,
      let host = settings[kCFNetworkProxiesHTTPProxy as String] as? String,
      !host.isEmpty,
      let port = settings[kCFNetworkProxiesHTTPPort as String] as? Int,
      port > 0
    {
      return ["host": host, "port": port]
    }

    return nil
  }
}
