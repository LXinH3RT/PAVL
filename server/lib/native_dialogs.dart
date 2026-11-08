/// 启动时用的原生对话框。
///
/// 托盘模式下没有控制台，任何提示都只能靠 MessageBox 或文件夹选择框。
/// 这里用 comdlg32/shell32 的 `SHBrowseForFolderW`，比自绘窗口省事，
/// 也是 Windows 上最符合习惯的「选一个文件夹」交互。
library;

import 'dart:ffi';
import 'dart:io';

/// 弹文件夹选择框，返回选中的绝对路径；用户取消时返回 null。
String? pickFolder({String title = '选择要共享的视频文件夹'}) {
  if (!Platform.isWindows) return null;

  // SHBrowseForFolder 走 shell 的 COM 组件，必须先初始化成 STA。
  final hr = _coInitializeEx(nullptr, _coinitApartmentThreaded);
  final needsUninit = hr >= 0;
  try {
    final titleWide = _toWide(title);
    final displayName = _calloc(512, 2).cast<Uint16>();
    final browse = _calloc(1, sizeOf<_BrowseInfo>());

    final info = browse.cast<_BrowseInfo>().ref;
    info.hwndOwner = 0;
    info.pidlRoot = nullptr;
    info.pszDisplayName = displayName;
    info.lpszTitle = titleWide;
    info.ulFlags = _bifReturnOnlyFsDirs | _bifNewDialogStyle | _bifEditBox;
    info.lpfn = nullptr;
    info.lParam = 0;
    info.iImage = 0;

    final pidl = _shBrowseForFolder(browse.cast<_BrowseInfo>());
    // 无论成功与否，BROWSEINFO 与标题都要释放。
    _free(browse.cast());
    _free(displayName.cast());
    _free(titleWide.cast());
    if (pidl == nullptr) return null;

    try {
      final buffer = _calloc(1024, 2).cast<Uint16>();
      try {
        if (_shGetPathFromIdList(pidl, buffer) == 0) return null;
        return _fromWide(buffer);
      } finally {
        _free(buffer.cast());
      }
    } finally {
      _coTaskMemFree(pidl);
    }
  } finally {
    if (needsUninit) _coUninitialize();
  }
}

/// 弹一个提示框。托盘模式下这是唯一能告诉用户「哪里出错了」的手段。
void showMessage(String text, {String caption = 'PAVL', bool isError = false}) {
  if (!Platform.isWindows) return;
  final textWide = _toWide(text);
  final captionWide = _toWide(caption);
  try {
    _messageBox(
      0,
      textWide,
      captionWide,
      _mbOk | (isError ? _mbIconError : _mbIconInformation),
    );
  } finally {
    _free(textWide.cast());
    _free(captionWide.cast());
  }
}

// ---------------------------------------------------------------------------
// Win32 绑定
// ---------------------------------------------------------------------------

const int _coinitApartmentThreaded = 0x2;

const int _bifReturnOnlyFsDirs = 0x00000001;
const int _bifEditBox = 0x00000010;
const int _bifNewDialogStyle = 0x00000040;

const int _mbOk = 0x00000000;
const int _mbIconError = 0x00000010;
const int _mbIconInformation = 0x00000040;

final class _BrowseInfo extends Struct {
  @IntPtr()
  external int hwndOwner;

  external Pointer<Void> pidlRoot;

  external Pointer<Uint16> pszDisplayName;

  external Pointer<Uint16> lpszTitle;

  @Uint32()
  external int ulFlags;

  external Pointer<Void> lpfn;

  @IntPtr()
  external int lParam;

  @Int32()
  external int iImage;
}

final DynamicLibrary _msvcrt = DynamicLibrary.open('msvcrt.dll');
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

final _callocNative = _msvcrt.lookupFunction<
    Pointer<Void> Function(UintPtr, UintPtr),
    Pointer<Void> Function(int, int)>('calloc');
final _freeNative = _msvcrt.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('free');

final _coInitializeEx = _ole32.lookupFunction<
    Int32 Function(Pointer<Void>, Uint32),
    int Function(Pointer<Void>, int)>('CoInitializeEx');
final _coUninitialize =
    _ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');
final _coTaskMemFree = _ole32.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('CoTaskMemFree');

final _shBrowseForFolder = _shell32.lookupFunction<
    Pointer<Void> Function(Pointer<_BrowseInfo>),
    Pointer<Void> Function(Pointer<_BrowseInfo>)>('SHBrowseForFolderW');
final _shGetPathFromIdList = _shell32.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Uint16>),
    int Function(Pointer<Void>, Pointer<Uint16>)>('SHGetPathFromIDListW');

final _messageBox = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint16>, Pointer<Uint16>, Uint32),
    int Function(int, Pointer<Uint16>, Pointer<Uint16>, int)>('MessageBoxW');

Pointer<Void> _calloc(int count, int size) => _callocNative(count, size);

void _free(Pointer<NativeType> pointer) => _freeNative(pointer.cast());

Pointer<Uint16> _toWide(String value) {
  final units = value.codeUnits;
  final pointer = _calloc(units.length + 1, 2).cast<Uint16>();
  for (var i = 0; i < units.length; i++) {
    pointer[i] = units[i];
  }
  pointer[units.length] = 0;
  return pointer;
}

String _fromWide(Pointer<Uint16> pointer) {
  final units = <int>[];
  for (var i = 0;; i++) {
    final unit = pointer[i];
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}
