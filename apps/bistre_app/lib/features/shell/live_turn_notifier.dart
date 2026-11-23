import 'dart:async';

import 'package:flutter/foundation.dart';

/// Immutable snapshot of the reply currently streaming into one thread.
@immutable
class LiveTurn {
  const LiveTurn({
    required this.threadId,
    required this.nodeId,
    this.text = '',
    this.thinking = '',
  });

  final String threadId;
  final String nodeId;
  final String text;
  final String thinking;

  LiveTurn copyWith({String? text, String? thinking}) => LiveTurn(
    threadId: threadId,
    nodeId: nodeId,
    text: text ?? this.text,
    thinking: thinking ?? this.thinking,
  );
}

/// Leaf-only streaming state (`docs/design/DESIGN.md` §8).
///
/// The Rust bridge coalesces deltas every 16 ms; each batch updates ONLY this notifier, which is
/// read by the single streaming message widget. The shell, header, sidebar, and the rest of the
/// feed listen to `FolioController` and therefore rebuild zero times per delta.
class LiveTurnNotifier extends ValueNotifier<LiveTurn?> {
  LiveTurnNotifier() : super(null);

  /// Minimum time between leaf redraws (`33 ms` = 30 fps in low-memory mode, else none).
  Duration minInterval = Duration.zero;

  String _pendingText = '';
  String _pendingThinking = '';
  Timer? _flushTimer;

  /// Starts a fresh live turn for `threadId` / `nodeId`.
  void start(String threadId, String nodeId) {
    _dropPending();
    value = LiveTurn(threadId: threadId, nodeId: nodeId);
  }

  /// Appends a text delta when it belongs to the live turn.
  void appendText(String threadId, String delta) {
    final turn = value;
    if (turn == null || turn.threadId != threadId || delta.isEmpty) return;
    _pendingText = '$_pendingText$delta';
    _schedule();
  }

  /// Appends a thinking delta when it belongs to the live turn.
  void appendThinking(String threadId, String delta) {
    final turn = value;
    if (turn == null || turn.threadId != threadId || delta.isEmpty) return;
    _pendingThinking = '$_pendingThinking$delta';
    _schedule();
  }

  void _schedule() {
    if (minInterval == Duration.zero) {
      flush();
      return;
    }
    _flushTimer ??= Timer(minInterval, flush);
  }

  /// Publishes buffered deltas now.
  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final turn = value;
    if (turn == null || (_pendingText.isEmpty && _pendingThinking.isEmpty)) {
      return;
    }
    value = turn.copyWith(
      text: '${turn.text}$_pendingText',
      thinking: '${turn.thinking}$_pendingThinking',
    );
    _pendingText = '';
    _pendingThinking = '';
  }

  void _dropPending() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingText = '';
    _pendingThinking = '';
  }

  /// Ends the live turn (the committed node replaces it in the feed).
  void clear() {
    _dropPending();
    if (value != null) value = null;
  }

  @override
  void dispose() {
    _dropPending();
    super.dispose();
  }
}
