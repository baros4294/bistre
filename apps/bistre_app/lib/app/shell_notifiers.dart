import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bistre_engine.dart';
import '../l10n/l10n_keys.g.dart';

/// Semantic tone for a floating pill toast.
enum ToastTone { info, ok, error }

/// One transient notice with an optional action (for example Undo) and ICU args.
@immutable
class ToastMessage {
  const ToastMessage(
    this.key, {
    this.args,
    this.tone = ToastTone.info,
    this.actionKey,
    this.onAction,
  });

  final L10nKey key;
  final Map<String, Object?>? args;
  final ToastTone tone;
  final L10nKey? actionKey;
  final VoidCallback? onAction;
}

/// The current toast. Only the toast overlay listens, so showing or dismissing a notice never
/// rebuilds the shell.
class ToastNotifier extends ValueNotifier<ToastMessage?> {
  ToastNotifier() : super(null);

  Timer? _timer;

  void show(ToastMessage message, Duration duration) {
    _timer?.cancel();
    value = message;
    _timer = Timer(duration, dismiss);
  }

  void dismiss() {
    _timer?.cancel();
    _timer = null;
    value = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Chat search query, scope, and results. Only the search bar and the feed listen, so each
/// keystroke rebuilds those two and nothing else.
class SearchNotifier extends ChangeNotifier {
  String _query = '';
  List<EngineSearchHit> _hits = const <EngineSearchHit>[];
  bool _allThreads = false;

  String get query => _query;
  List<EngineSearchHit> get hits => _hits;
  bool get allThreads => _allThreads;

  /// Sets any of the fields and notifies once when something changed.
  void update({String? query, List<EngineSearchHit>? hits, bool? allThreads}) {
    final changed =
        (query != null && query != _query) ||
        (hits != null && !identical(hits, _hits)) ||
        (allThreads != null && allThreads != _allThreads);
    if (!changed) return;
    _query = query ?? _query;
    _hits = hits ?? _hits;
    _allThreads = allThreads ?? _allThreads;
    notifyListeners();
  }

  /// Clears the query and results; the chosen scope stays.
  void clear() => update(query: '', hits: const <EngineSearchHit>[]);
}
