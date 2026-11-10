/// 客户端版本号。
///
/// `pubspec.yaml` 是版本的唯一来源，但 Flutter 不会把它编进代码里：Dart 侧
/// 读不到 package 的 version 字段，而为了显示一行字就引入 package_info
/// 这类插件也不划算。
///
/// 所以构建时用 `--dart-define=PAVL_VERSION=x.y.z` 传进来；直接 `flutter run`
/// 或跑测试时没有这个 define，落回下面的默认值。**发版时这里要跟着
/// `pubspec.yaml` 一起改**，否则「关于」页会显示旧版本号。
library;

const String appVersion = String.fromEnvironment(
  'PAVL_VERSION',
  defaultValue: '0.2.3',
);
