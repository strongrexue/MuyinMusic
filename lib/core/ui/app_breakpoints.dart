/// 全应用统一的宽度断点。页面在 build 期按可用宽度计算形态，
/// 不引入全局模式状态；窗口尺寸变化时随 build 自然重算。
abstract final class AppBreakpoints {
  /// Medium 起点：手机横屏、小平板；紧凑布局在此之下。
  static const double medium = 600;

  /// Expanded 起点：平板、桌面、车机大屏的主要扩展断点。
  static const double expanded = 840;

  /// Ultra 起点：只用于少数内容上限与密度档位，不单独形成布局。
  static const double ultra = 1200;

  static bool isMedium(double width) => width >= medium;

  static bool isExpanded(double width) => width >= expanded;

  static bool isUltra(double width) => width >= ultra;
}
