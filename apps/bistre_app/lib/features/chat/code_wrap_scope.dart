import 'package:flutter/widgets.dart';

/// Per-fence wrap toggles that survive list virtualization (cards scrolled out of view are
/// disposed, so the choice lives here, keyed by the fence's content hash).
class CodeWrapOverrides extends ChangeNotifier {
  final Map<int, bool> _byFence = <int, bool>{};

  bool? overrideFor(int fenceKey) => _byFence[fenceKey];

  void set(int fenceKey, bool wrap) {
    if (_byFence[fenceKey] == wrap) return;
    _byFence[fenceKey] = wrap;
    notifyListeners();
  }

  void clear() {
    if (_byFence.isEmpty) return;
    _byFence.clear();
    notifyListeners();
  }
}

/// Provides the effective default wrap (preference + viewport width) and the per-fence
/// overrides to every code block below it.
class CodeWrapScope extends InheritedNotifier<CodeWrapOverrides> {
  const CodeWrapScope({
    super.key,
    required this.wrapByDefault,
    required CodeWrapOverrides overrides,
    required super.child,
  }) : super(notifier: overrides);

  final bool wrapByDefault;

  static CodeWrapScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CodeWrapScope>();

  /// Effective wrap for one fence (its own toggle wins over the default).
  static bool wrapFor(BuildContext context, int fenceKey) {
    final scope = maybeOf(context);
    if (scope == null) return false;
    return scope.notifier?.overrideFor(fenceKey) ?? scope.wrapByDefault;
  }

  @override
  bool updateShouldNotify(CodeWrapScope oldWidget) =>
      oldWidget.wrapByDefault != wrapByDefault ||
      super.updateShouldNotify(oldWidget);
}
