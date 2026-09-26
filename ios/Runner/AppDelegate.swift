import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 剪贴板变化检测通道（P1-2 根治：iOS 16+ 每次程序化读取粘贴板都会弹
  /// 「已粘贴自…」系统横幅。读取 UIPasteboard.general.changeCount 不触发
  /// 该提示——Dart 侧先比对计数，仅内容真的变化时才读取文本，
  /// 把系统提示频次从「每次切回前台」降到「每次真的复制了新内容」。）
  private static let clipboardChannelName = "clipvault/clipboard"

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
  }
}
