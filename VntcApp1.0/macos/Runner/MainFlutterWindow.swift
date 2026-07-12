import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var closeRequestChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 使用标准 macOS 窗口样式，保留关闭、最小化和缩放按钮。
    self.styleMask = [
      .titled,
      .closable,
      .miniaturizable,
      .resizable
    ]

    // 设置最小尺寸
    self.minSize = NSSize(width: 800, height: 600)

    // 设置窗口的初始位置和大小
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    closeRequestChannel = FlutterMethodChannel(
      name: "top.wherewego.vnt/window_close",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    if let closeButton = standardWindowButton(.closeButton) {
      closeButton.target = self
      closeButton.action = #selector(handleCloseButton(_:))
    }

    super.awakeFromNib()
  }

  @objc private func handleCloseButton(_ sender: Any?) {
    closeRequestChannel?.invokeMethod("onCloseRequested", arguments: nil)
  }

  // 确保窗口可以成为主窗口
  override var canBecomeMain: Bool {
    return true
  }

  // 确保窗口可以成为关键窗口
  override var canBecomeKey: Bool {
    return true
  }

  // 允许窗口接受鼠标事件
  override var acceptsFirstResponder: Bool {
    return true
  }
}
