/// 应用根组件与全局主题。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'store/app_store.dart';
import 'ui/home_screen.dart';

/// 全局色板。
///
/// 深色为主：影视内容在深色背景下观感更好，且播放页不需要切换主题。
class PavlColors {
  static const Color background = Color(0xFF101114);
  static const Color surface = Color(0xFF1A1C21);
  static const Color surfaceHigh = Color(0xFF23262D);
  static const Color border = Color(0xFF2E323A);
  static const Color accent = Color(0xFF4C8DFF);
  static const Color accentDim = Color(0xFF2C5282);
  static const Color text = Color(0xFFE8EAED);
  static const Color textDim = Color(0xFF9AA0A6);
  static const Color danger = Color(0xFFE05B5B);
  static const Color success = Color(0xFF4CAF7D);
}

/// 全局字体。
///
/// 界面使用随包分发的 MiSans（见 pubspec.yaml 的 fonts 段）。系统默认字体族
/// 在部分平台上没有完整中文字形，中文会落到 fallback 链上，同一句里的中文
/// 与数字因此来自两套字，字面大小与笔画粗细对不齐，自带一份覆盖 CJK 的字体
/// 即消除差异。
///
/// 该文件是可变字体，只取默认实例，粗体由引擎合成；因此不按字重拆 asset。
/// 播放页字幕由 libass 按字幕文件自带的字体绘制，不走这里。
class PavlFonts {
  static const String ui = 'MiSans';

  /// 兜底链仅在字体缺字（如生僻符号、彩色 emoji）时生效，避免落到随机字体。
  ///
  /// 各平台的系统字体族名字不通用：把 Windows 的名字写死在 macOS 上不会报错，
  /// 只是静默地一个都匹配不到，最后仍落到引擎默认字体。因此按平台各给一份。
  static List<String> get fallback {
    if (Platform.isWindows) {
      return const <String>['Microsoft YaHei', 'Segoe UI', 'Arial'];
    }
    if (Platform.isMacOS) {
      return const <String>['PingFang SC', 'Helvetica Neue', 'Helvetica'];
    }
    if (Platform.isAndroid) {
      return const <String>['Noto Sans CJK SC', 'Roboto'];
    }
    if (Platform.isIOS) {
      return const <String>['PingFang SC', 'Helvetica Neue'];
    }
    return const <String>['Noto Sans CJK SC', 'DejaVu Sans'];
  }
}

/// 应用根组件。
class PavlApp extends StatelessWidget {
  const PavlApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PAVL',
      debugShowCheckedModeBanner: false,
      theme: buildPavlTheme(),
      home: HomeScreen(store: store),
    );
  }
}

/// 构建应用主题。
///
/// 独立成函数而不是塞在 [PavlApp.build] 里，是为了让测试能拿到和真实运行
/// 完全一样的主题——端到端测试里如果自己另写一份 ThemeData，测的就不是
/// 用户看到的那套颜色与字体了。
ThemeData buildPavlTheme() {
  // 字体必须在构造函数里给：copyWith 没有 fontFamily 参数，而组件主题
  // （按钮、对话框标题等）的默认文字样式是在构造 ThemeData 时由 textTheme
  // 派生的，事后替换 textTheme 不会回溯到这些派生值。
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: PavlFonts.ui,
    fontFamilyFallback: PavlFonts.fallback,
  );
  return base.copyWith(
    scaffoldBackgroundColor: PavlColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: PavlColors.accent,
      surface: PavlColors.surface,
      error: PavlColors.danger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: PavlColors.text,
      displayColor: PavlColors.text,
    ),
    dividerColor: PavlColors.border,
    splashFactory: InkSparkle.splashFactory,
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
