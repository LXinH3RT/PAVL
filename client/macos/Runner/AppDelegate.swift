import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 关掉最后一个窗口不结束进程。
  ///
  /// macOS 上的惯例是关窗口只是收起来，进程留着，点 Dock 图标能叫回来，只有
  /// 菜单里的「退出 PAVL」（⌘Q）才真正退出。返回 true 在这里会让每一次关窗
  /// 都结束整个程序，与系统习惯相反。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// 点 Dock 图标时把收起来的窗口放回来。
  ///
  /// 窗口被 hide 之后只是从屏幕上移走，并没有销毁，所以这里逐个 makeKey 就能
  /// 复原；没有这一步，用户点 Dock 图标会毫无反应，只能靠 ⌘Q 重开。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
