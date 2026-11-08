/// Windows 通知区域图标。
///
/// 只用 `dart:ffi` 直调 user32/shell32，不依赖 package:ffi，保证服务端仍然
/// 是一个零第三方依赖的单文件可执行程序。
///
/// 关键设计：窗口必须在一个**独立的 isolate** 里创建，并由该 isolate 自己
/// 阻塞在 `GetMessageW` 上。原因是 Dart 的 `Timer` 回调会被调度到线程池里
/// 不同的操作系统线程上（日志里能看到 `thread=` 来回变化），而 Win32 窗口
/// 归属创建它的线程，那个线程一旦空闲被回收，窗口就被系统连带销毁，且不会
/// 给窗口过程发 WM_DESTROY。放在独立 isolate 里、创建后立刻进入阻塞消息
/// 循环，线程不会回到线程池，窗口就能一直存活。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

// ---------------------------------------------------------------------------
// 公开 API（主 isolate）
// ---------------------------------------------------------------------------

/// 托盘菜单命令。
abstract final class TrayCommand {
  static const int copyPin = 1001;
  static const int openDataDir = 1002;
  static const int regeneratePin = 1003;
  static const int openBrowser = 1004;
  static const int exit = 1099;
}

/// 托盘菜单项。
class TrayMenuItem {
  const TrayMenuItem(this.id, this.label);

  /// 分隔线。
  const TrayMenuItem.separator()
      : id = 0,
        label = '';

  /// 灰色不可点的信息行。
  const TrayMenuItem.info(this.label) : id = -1;

  final int id;
  final String label;
}

/// 通知区域图标。
class TrayIcon {
  TrayIcon({
    required this.tooltip,
    required List<TrayMenuItem> Function() onMenu,
    required void Function(int id) onCommand,
    required void Function() onDoubleClick,
    void Function()? onClosed,
  })  : _onMenu = onMenu,
        _onCommand = onCommand,
        _onDoubleClick = onDoubleClick,
        _onClosed = onClosed;

  final String tooltip;
  final List<TrayMenuItem> Function() _onMenu;
  final void Function(int id) _onCommand;
  final void Function() _onDoubleClick;

  /// 托盘窗口被销毁时回调（比如用户从任务管理器关掉窗口）。
  final void Function()? _onClosed;

  Isolate? _isolate;
  ReceivePort? _port;
  Pointer<Uint16> _shared = nullptr;
  int _hwnd = 0;
  bool _running = false;
  String _tooltip = '';

  static bool get available => Platform.isWindows;

  bool get running => _running;

  /// 启动托盘。失败返回 false，调用方应退回控制台模式。
  Future<bool> start() async {
    if (!available) return false;
    _tooltip = tooltip;
    // 共享文本缓冲区：本身放 UTF-16，改提示或菜单时主 isolate 直接写进去，
    // 再往托盘窗口发一条 WM_APP 消息让它重读。
    _shared = _calloc(_sharedCapacity, 2).cast<Uint16>();
    if (_shared == nullptr) return false;
    _writeShared();

    final port = ReceivePort();
    final ready = Completer<int>();
    port.listen((Object? message) {
      if (message is! int) return;
      if (message == _msgReady) return;
      if (!ready.isCompleted) {
        ready.complete(message);
        return;
      }
      switch (message) {
        case _msgClosed:
          _running = false;
          _onClosed?.call();
        case _msgDoubleClick:
          _onDoubleClick();
        default:
          _onCommand(message);
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _trayIsolateMain,
        <Object>[
          port.sendPort,
          _shared.address,
          _tooltip,
        ],
        debugName: 'pavl-tray',
      );
    } catch (error) {
      _log('spawn failed: $error');
      port.close();
      return false;
    }

    _port = port;
    final hwnd = await ready.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
    if (hwnd <= 0) {
      _log('tray did not report a window handle');
      _port?.close();
      _port = null;
      _running = false;
      return false;
    }
    _hwnd = hwnd;
    _running = true;
    return true;
  }

  /// 更新悬停提示。
  void setTooltip(String text) {
    _tooltip = text;
    _refresh();
  }

  /// 重新读取菜单并刷新（PIN 变了之后要调一次）。
  void refresh() => _refresh();

  void _refresh() {
    if (_hwnd == 0) return;
    _writeShared();
    _postMessage(_hwnd, _wmAppRefresh, 0, 0);
  }

  void dispose() {
    if (_hwnd != 0) {
      _postMessage(_hwnd, _wmClose, 0, 0);
    }
    _hwnd = 0;
    _running = false;
    _port?.close();
    _port = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    if (_shared != nullptr) {
      _free(_shared.cast());
      _shared = nullptr;
    }
  }

  /// 把提示与菜单写进共享缓冲区。
  void _writeShared() {
    var index = 0;
    void put(String text, {bool terminator = true}) {
      for (final unit in text.codeUnits) {
        if (index >= _sharedCapacity - 1) return;
        _shared[index++] = unit;
      }
      if (terminator && index < _sharedCapacity) _shared[index++] = 0;
    }

    put(_tooltip.isEmpty ? 'PAVL' : _tooltip);
    for (final item in _onMenu()) {
      // 分隔线用单个 '-' 表示；其余每项是 "id<TAB>label" 一段，
      // 托盘 isolate 按 NUL 切开逐段解析。
      if (item.id == 0) {
        put('-');
      } else {
        put('${item.id}\t${item.label}');
      }
    }
    if (index < _sharedCapacity) _shared[index] = 0;
  }

  void _log(String message) => trayLog(message);
}

/// 解绑控制台。
///
/// `dart compile exe` 产出的是控制台子系统程序，没有链接器开关可改，
/// 只能在运行时调用 `FreeConsole` 把窗口收掉。
void detachConsole() {
  if (!Platform.isWindows) return;
  try {
    _freeConsole();
  } catch (_) {
    // 没有控制台时会失败，忽略即可。
  }
}

// ---------------------------------------------------------------------------
// 托盘 isolate
// ---------------------------------------------------------------------------

const int _msgReady = -1;
const int _msgClosed = -3;
const int _msgDoubleClick = -2;

const int _sharedCapacity = 8192;

const int _wmNull = 0;
const int _wmDestroy = 0x0002;
const int _wmClose = 0x0010;
const int _wmCommand = 0x0111;
const int _wmContextMenu = 0x007B;
const int _wmRButtonUp = 0x0205;
const int _wmLButtonDblClk = 0x0203;
const int _wmAppRefresh = 0x8000 + 1;
const int _wmUserTray = 0x0400 + 1;

const int _nifMessage = 0x1;
const int _nifIcon = 0x2;
const int _nifTip = 0x4;
const int _nimAdd = 0x0;
const int _nimModify = 0x1;
const int _nimDelete = 0x2;

const int _mfString = 0x0;
const int _mfGrayed = 0x1;
const int _mfSeparator = 0x800;

const int _tpmRightButton = 0x0002;
const int _tpmBottomAlign = 0x0020;
const int _tpmReturnCmd = 0x0100;

const int _idiApplication = 32512;
const int _wsPopup = 0x80000000;

void _trayIsolateMain(List<Object> args) {
  final reply = args[0] as SendPort;
  final shared = Pointer<Uint16>.fromAddress(args[1] as int);
  final tooltip = args[2] as String;

  final instance = _getModuleHandle(nullptr);
  final className = _toWide('PavlTrayWnd');
  final windowName = _toWide('PAVL');
  final icon = _loadIcon(0, Pointer<Uint16>.fromAddress(_idiApplication));

  final wndProc = NativeCallable<_WndProcNative>.isolateLocal(
    (int hwnd, int message, int wParam, int lParam) =>
        _trayWndProc(hwnd, message, wParam, lParam, shared, reply, tooltip),
    exceptionalReturn: 0,
  );

  final wc = _alloc<_WndClassEx>(sizeOf<_WndClassEx>());
  Pointer<Uint16>? tipText;
  var hwnd = 0;
  try {
    final style = wc.ref;
    style.cbSize = sizeOf<_WndClassEx>();
    style.style = 0;
    style.lpfnWndProc = wndProc.nativeFunction;
    style.cbClsExtra = 0;
    style.cbWndExtra = 0;
    style.hInstance = instance;
    style.hIcon = icon;
    style.hCursor = 0;
    style.hbrBackground = 0;
    style.lpszMenuName = nullptr;
    style.lpszClassName = className;
    style.hIconSm = icon;
    _registerClassEx(wc);
    _free(wc.cast());

    hwnd = _createWindowEx(
      0,
      className,
      windowName,
      _wsPopup,
      0,
      0,
      0,
      0,
      0,
      0,
      instance,
      0,
    );
    if (hwnd == 0) {
      reply.send(0);
      return;
    }

    final data = _alloc<_NotifyIconData>(sizeOf<_NotifyIconData>());
    final ref = data.ref;
    ref.cbSize = sizeOf<_NotifyIconData>();
    ref.hWnd = hwnd;
    ref.uID = 1;
    ref.uFlags = _nifMessage | _nifIcon | _nifTip;
    ref.uCallbackMessage = _wmUserTray;
    ref.hIcon = icon;
    tipText = _toWide(tooltip.isEmpty ? 'PAVL' : tooltip);
    _copyWide(ref.szTip, 128, tipText);
    _shellNotifyIcon(_nimAdd, data);

    _trayNotify = data;
    reply.send(hwnd);

    // 阻塞消息循环：绝不能返回事件循环，否则线程会被回收、窗口随之消失。
    final msg = _alloc<_Msg>(sizeOf<_Msg>());
    try {
      var result = _getMessage(msg, 0, 0, 0);
      while (result > 0) {
        _translateMessage(msg);
        _dispatchMessage(msg);
        result = _getMessage(msg, 0, 0, 0);
      }
    } finally {
      _free(msg.cast());
    }
  } finally {
    final data = _trayNotify;
    if (data != nullptr) {
      _shellNotifyIcon(_nimDelete, data);
      _free(data.cast());
      _trayNotify = nullptr;
    }
    if (hwnd != 0) _destroyWindow(hwnd);
    if (tipText != null) _free(tipText.cast());
    _free(className.cast());
    _free(windowName.cast());
    wndProc.close();
    reply.send(_msgClosed);
  }
}

Pointer<_NotifyIconData> _trayNotify = nullptr;

int _trayWndProc(
  int hwnd,
  int message,
  int wParam,
  int lParam,
  Pointer<Uint16> shared,
  SendPort reply,
  String initialTooltip,
) {
  switch (message) {
    case _wmAppRefresh:
      _refreshTooltip(hwnd, shared);
      return 0;
    case _wmUserTray:
      if (lParam == _wmRButtonUp || lParam == _wmContextMenu) {
        _showMenu(hwnd, shared, reply);
        return 0;
      }
      if (lParam == _wmLButtonDblClk) {
        reply.send(_msgDoubleClick);
        return 0;
      }
      return 0;
    case _wmCommand:
      final id = wParam & 0xFFFF;
      if (id > 0) reply.send(id);
      return 0;
    case _wmClose:
      _destroyWindow(hwnd);
      _postQuitMessage(0);
      return 0;
    case _wmDestroy:
      _postQuitMessage(0);
      return 0;
  }
  return _defWindowProc(hwnd, message, wParam, lParam);
}

void _refreshTooltip(int hwnd, Pointer<Uint16> shared) {
  final data = _trayNotify;
  if (data == nullptr) return;
  final text = _readWide(shared, 128);
  _copyWide(data.ref.szTip, 128, _toWide(text.isEmpty ? 'PAVL' : text));
  data.ref.uFlags = _nifMessage | _nifIcon | _nifTip;
  _shellNotifyIcon(_nimModify, data);
}

void _showMenu(int hwnd, Pointer<Uint16> shared, SendPort reply) {
  final menu = _createPopupMenu();
  if (menu == 0) return;
  final strings = <Pointer<Uint16>>[];
  try {
    var offset = _skipWide(shared, 0);
    while (true) {
      final text = _readWide(shared, 256, from: offset);
      if (text.isEmpty) break;
      offset += text.length + 1;
      if (text == '-') {
        _appendMenu(menu, _mfSeparator, 0, nullptr);
        continue;
      }
      final tab = text.indexOf('\t');
      final id = int.tryParse(tab < 0 ? text : text.substring(0, tab)) ?? 0;
      final label = tab < 0 ? '' : text.substring(tab + 1);
      final wide = _toWide(label);
      strings.add(wide);
      if (id < 0) {
        _appendMenu(menu, _mfString | _mfGrayed, 0, wide);
      } else {
        _appendMenu(menu, _mfString, id, wide);
      }
    }

    final point = _alloc<_Point>(sizeOf<_Point>());
    final command = () {
      try {
        _getCursorPos(point);
        // 不抢前台的话点菜单外面不会关闭，这是 TrackPopupMenu 的老规矩。
        _setForegroundWindow(hwnd);
        return _trackPopupMenu(
          menu,
          _tpmRightButton | _tpmBottomAlign | _tpmReturnCmd,
          point.ref.x,
          point.ref.y,
          0,
          hwnd,
          nullptr,
        );
      } finally {
        _free(point.cast());
      }
    }();
    _postMessage(hwnd, _wmNull, 0, 0);
    if (command > 0) reply.send(command);
  } finally {
    for (final s in strings) {
      _free(s.cast());
    }
    _destroyMenu(menu);
  }
}

int _skipWide(Pointer<Uint16> buffer, int from) {
  var i = from;
  while (buffer[i] != 0) {
    i++;
  }
  return i + 1;
}

String _readWide(Pointer<Uint16> buffer, int capacity, {int from = 0}) {
  final units = <int>[];
  for (var i = from; i < from + capacity; i++) {
    final unit = buffer[i];
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------

/// 把一行诊断写进 `PAVL_TRAY_LOG` 指定的文件。
void trayLog(String message) {
  if (!Platform.isWindows) return;
  final path = Platform.environment['PAVL_TRAY_LOG'];
  if (path == null || path.isEmpty) return;
  try {
    File(path).writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 日志失败不能影响托盘本身。
  }
}

// ---------------------------------------------------------------------------
// Win32 绑定
// ---------------------------------------------------------------------------

typedef _WndProcNative = IntPtr Function(IntPtr, Uint32, Uint64, Int64);

final class _WndClassEx extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int style;

  external Pointer<NativeFunction<_WndProcNative>> lpfnWndProc;

  @Int32()
  external int cbClsExtra;

  @Int32()
  external int cbWndExtra;

  @IntPtr()
  external int hInstance;

  @IntPtr()
  external int hIcon;

  @IntPtr()
  external int hCursor;

  @IntPtr()
  external int hbrBackground;

  external Pointer<Uint16> lpszMenuName;

  external Pointer<Uint16> lpszClassName;

  @IntPtr()
  external int hIconSm;
}

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final class _Msg extends Struct {
  @IntPtr()
  external int hwnd;

  @Uint32()
  external int message;

  @UintPtr()
  external int wParam;

  @IntPtr()
  external int lParam;

  @Uint32()
  external int time;

  external _Point pt;

  @Uint32()
  external int lPrivate;
}

final class _NotifyIconData extends Struct {
  @Uint32()
  external int cbSize;

  @IntPtr()
  external int hWnd;

  @Uint32()
  external int uID;

  @Uint32()
  external int uFlags;

  @Uint32()
  external int uCallbackMessage;

  @IntPtr()
  external int hIcon;

  @Array(128)
  external Array<Uint16> szTip;

  @Uint32()
  external int dwState;

  @Uint32()
  external int dwStateMask;

  @Array(256)
  external Array<Uint16> szInfo;

  @Uint32()
  external int uTimeout;

  @Array(64)
  external Array<Uint16> szInfoTitle;

  @Uint32()
  external int dwInfoFlags;

  @Array(16)
  external Array<Uint8> guidItem;

  @IntPtr()
  external int hBalloonIcon;
}

final DynamicLibrary _msvcrt = DynamicLibrary.open('msvcrt.dll');
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final _callocNative =
    _msvcrt.lookupFunction<Pointer<Void> Function(UintPtr, UintPtr), Pointer<Void> Function(int, int)>('calloc');
final _freeNative =
    _msvcrt.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');

final _registerClassEx = _user32.lookupFunction<
    Uint16 Function(Pointer<_WndClassEx>),
    int Function(Pointer<_WndClassEx>)>('RegisterClassExW');

final _createWindowEx = _user32.lookupFunction<
    IntPtr Function(Uint32, Pointer<Uint16>, Pointer<Uint16>, Uint32, Int32,
        Int32, Int32, Int32, IntPtr, IntPtr, IntPtr, IntPtr),
    int Function(int, Pointer<Uint16>, Pointer<Uint16>, int, int, int, int, int,
        int, int, int, int)>('CreateWindowExW');

final _defWindowProc = _user32.lookupFunction<
    IntPtr Function(IntPtr, Uint32, Uint64, Int64),
    int Function(int, int, int, int)>('DefWindowProcW');

final _destroyWindow =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'DestroyWindow');

final _getMessage = _user32.lookupFunction<
    Int32 Function(Pointer<_Msg>, IntPtr, Uint32, Uint32),
    int Function(Pointer<_Msg>, int, int, int)>('GetMessageW');

final _translateMessage =
    _user32.lookupFunction<Int32 Function(Pointer<_Msg>), int Function(Pointer<_Msg>)>(
        'TranslateMessage');

final _dispatchMessage =
    _user32.lookupFunction<IntPtr Function(Pointer<_Msg>), int Function(Pointer<_Msg>)>(
        'DispatchMessageW');

final _postMessage = _user32.lookupFunction<
    Int32 Function(IntPtr, Uint32, UintPtr, IntPtr),
    int Function(int, int, int, int)>('PostMessageW');

final _postQuitMessage =
    _user32.lookupFunction<Void Function(Int32), void Function(int)>(
        'PostQuitMessage');

final _createPopupMenu =
    _user32.lookupFunction<IntPtr Function(), int Function()>('CreatePopupMenu');

final _appendMenu = _user32.lookupFunction<
    Int32 Function(IntPtr, Uint32, UintPtr, Pointer<Uint16>),
    int Function(int, int, int, Pointer<Uint16>)>('AppendMenuW');

final _trackPopupMenu = _user32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Int32, Int32, Int32, IntPtr, Pointer<Void>),
    int Function(int, int, int, int, int, int, Pointer<Void>)>('TrackPopupMenu');

final _destroyMenu =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DestroyMenu');

final _getCursorPos =
    _user32.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>(
        'GetCursorPos');

final _setForegroundWindow =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow');

final _loadIcon = _user32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Uint16>),
    int Function(int, Pointer<Uint16>)>('LoadIconW');

final _shellNotifyIcon = _shell32.lookupFunction<
    Int32 Function(Uint32, Pointer<_NotifyIconData>),
    int Function(int, Pointer<_NotifyIconData>)>('Shell_NotifyIconW');

final _freeConsole =
    _kernel32.lookupFunction<Int32 Function(), int Function()>('FreeConsole');

final _getModuleHandle =
    _kernel32.lookupFunction<IntPtr Function(Pointer<Uint16>), int Function(Pointer<Uint16>)>(
        'GetModuleHandleW');

Pointer<T> _alloc<T extends NativeType>(int bytes) =>
    _calloc(1, bytes).cast<T>();

Pointer<Void> _calloc(int count, int size) => _callocNative(count, size);

void _free(Pointer<NativeType> pointer) => _freeNative(pointer.cast());

Pointer<Uint16> _toWide(String value) {
  final units = value.codeUnits;
  final pointer = _alloc<Uint16>((units.length + 1) * 2);
  if (pointer == nullptr) return pointer;
  for (var i = 0; i < units.length; i++) {
    pointer[i] = units[i];
  }
  pointer[units.length] = 0;
  return pointer;
}

void _copyWide(Array<Uint16> target, int capacity, Pointer<Uint16> source) {
  var i = 0;
  while (i < capacity - 1) {
    final unit = source[i];
    if (unit == 0) break;
    target[i] = unit;
    i++;
  }
  target[i] = 0;
}
