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
    final base = ThemeData.dark(useMaterial3: true);
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
