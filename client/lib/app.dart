/// 应用根组件与全局主题。
library;

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
/// 界面使用随包分发的 MiSans（见 pubspec.yaml 的 fonts 段）。Windows 的默认
/// 字体族没有中文字形，中文会落到 fallback 链上，同一句里的中文与数字因此
/// 来自两套字，字面大小与笔画粗细对不齐，自带一份覆盖 CJK 的字体即消除差异。
///
/// 该文件是可变字体，只取默认实例，粗体由引擎合成；因此不按字重拆 asset。
/// 播放页字幕由 libass 按字幕文件自带的字体绘制，不走这里。
class PavlFonts {
  static const String ui = 'MiSans';

  /// 兜底链仅在字体缺字（如生僻符号、彩色 emoji）时生效，避免落到随机字体。
  static const List<String> fallback = <String>[
    'Microsoft YaHei',
    'Segoe UI',
    'Arial',
  ];
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
      theme: _buildTheme(),
      home: HomeScreen(store: store),
    );
  }

  ThemeData _buildTheme() {
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
}
