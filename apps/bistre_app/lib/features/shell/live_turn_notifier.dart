import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../chat/plain_preview.dart';

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

/// Leaf-only streaming state (`docs/design/design.md` §8).
///
/// The Rust bridge coalesces deltas every 16 ms; each batch updates ONLY this notifier, which is
/// read by the single streaming message widget. The shell, header, sidebar, and the rest of the
/// feed listen to `FolioController` and therefore rebuild zero times per delta.
class LiveTurnNotifier extends ValueNotifier<LiveTurn?> {
  LiveTurnNotifier() : super(null);

  /// Minimum time between leaf redraws (`33 ms` = 30 fps in low-memory mode, else none).
  Duration minInterval = Duration.zero;

  /// Whether text reveals at a reading pace (DESIGN §6); asked on every delta so a settings
  /// change applies at once. Unpaced turns publish each batch as it arrives.
  bool Function() shouldPace = _never;

  /// Reading pace while little text is waiting.
  static const double paceCharsPerSecond = 92;

  /// Above this many waiting characters the reveal catches up elastically.
  static const int elasticThreshold = 28;

  /// Time constant of the catch-up: the excess over [elasticThreshold] shrinks by ~63% per
  /// 80 ms, so a fast stream trails by a fraction of a second, never more.
  static const double catchUpSeconds = 0.08;

  String _pendingText = '';
  String _pendingThinking = '';
  int? _frameCallbackId;
  Duration? _lastFrame;
  Duration? _lastPublishFrame;
  double _carryText = 0;
  double _carryThinking = 0;

  static bool _never() => false;

  /// Starts a fresh live turn for `threadId` / `nodeId`.
  void start(String threadId, String nodeId) {
    _dropPending();
    value = LiveTurn(threadId: threadId, nodeId: nodeId);
  }

  /// Shows text a turn already has (a chat opened mid-reply), at once and unpaced.
  void seed({required String text, required String thinking}) {
    final turn = value;
    if (turn == null || (text.isEmpty && thinking.isEmpty)) return;
    value = turn.copyWith(text: text, thinking: thinking);
  }

  /// Appends a text delta when it belongs to the active live turn (`threadId` and optional `nodeId`).
  void appendText(String threadId, String delta, {String? nodeId}) {
    final turn = value;
    if (turn == null || turn.threadId != threadId || delta.isEmpty) return;
    if (nodeId != null && nodeId.isNotEmpty && turn.nodeId != nodeId) return;
    _pendingText = '$_pendingText$delta';
    _schedule();
  }

  /// Appends a thinking delta when it belongs to the active live turn (`threadId` and optional `nodeId`).
  void appendThinking(String threadId, String delta, {String? nodeId}) {
    final turn = value;
    if (turn == null || turn.threadId != threadId || delta.isEmpty) return;
    if (nodeId != null && nodeId.isNotEmpty && turn.nodeId != nodeId) return;
    _pendingThinking = '$_pendingThinking$delta';
    _schedule();
  }

  bool get _pacingActive =>
      shouldPace() &&
      !SchedulerBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .disableAnimations;

  void _schedule() {
    if (!_pacingActive && minInterval == Duration.zero) {
      // Unpaced mode (Reduce motion / instant): Rust FFI already coalesces deltas per 16 ms
      // frame, so publish immediately when no reading pace or low-memory throttle is active.
      flush();
      return;
    }
    // Paced and low-memory 30 fps modes both lock strictly to Flutter's VSync frame callback
    // (zero raw `Timer` beat-frequency drift against display refresh).
    _frameCallbackId ??= SchedulerBinding.instance.scheduleFrameCallback(
      _onVsyncFrame,
    );
  }

  /// Publishes buffered deltas now.
  void flush() {
    _stopFrameCallback();
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

  void _onVsyncFrame(Duration timestamp) {
    _frameCallbackId = null;
    final turn = value;
    if (turn == null || (_pendingText.isEmpty && _pendingThinking.isEmpty)) {
      _lastFrame = null;
      return;
    }
    if (minInterval > Duration.zero && _lastPublishFrame != null) {
      if (timestamp - _lastPublishFrame! < minInterval) {
        _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
          _onVsyncFrame,
        );
        return;
      }
    }
    if (_pacingActive) {
      _revealFrame(timestamp, turn);
      return;
    }
    _lastFrame = null;
    _lastPublishFrame = timestamp;
    value = turn.copyWith(
      text: '${turn.text}$_pendingText',
      thinking: '${turn.thinking}$_pendingThinking',
    );
    _pendingText = '';
    _pendingThinking = '';
  }

  void _revealFrame(Duration timestamp, LiveTurn turn) {
    final last = _lastFrame;
    final seconds = last == null
        ? 1 / 60
        : ((timestamp - last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastFrame = timestamp;
    final (paced, textCarry) = _paced(_pendingText, _carryText, seconds);
    final (pacedThinking, thinkCarry) = _paced(
      _pendingThinking,
      _carryThinking,
      seconds,
    );
    final textCount = wholeUnits(_pendingText, paced);
    final thinkCount = wholeUnits(_pendingThinking, pacedThinking);
    _carryText = textCarry;
    _carryThinking = thinkCarry;
    if (textCount > 0 || thinkCount > 0) {
      _lastPublishFrame = timestamp;
      value = turn.copyWith(
        text: '${turn.text}${_pendingText.substring(0, textCount)}',
        thinking:
            '${turn.thinking}${_pendingThinking.substring(0, thinkCount)}',
      );
      _pendingText = _pendingText.substring(textCount);
      _pendingThinking = _pendingThinking.substring(thinkCount);
    }
    if (_pendingText.isEmpty && _pendingThinking.isEmpty) {
      _lastFrame = null;
      return;
    }
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
      _onVsyncFrame,
    );
  }

  /// How many waiting UTF-16 units to reveal this frame, and the fractional carry: a steady
  /// [paceCharsPerSecond], plus an elastic share of anything beyond [elasticThreshold].
  static (int, double) _paced(String pending, double carry, double seconds) {
    if (pending.isEmpty) return (0, 0);
    final excess = pending.length > elasticThreshold
        ? pending.length - elasticThreshold
        : 0;
    final exact =
        carry +
        paceCharsPerSecond * seconds +
        excess * (seconds / catchUpSeconds).clamp(0.0, 1.0);
    var count = exact.floor().clamp(0, pending.length);
    // Never split a surrogate pair.
    if (count > 0 &&
        count < pending.length &&
        _isHighSurrogate(pending.codeUnitAt(count - 1))) {
      count += 1;
    }
    return (count, count >= pending.length ? 0 : exact - exact.floor());
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  void _stopFrameCallback() {
    final id = _frameCallbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    }
    _frameCallbackId = null;
    _lastFrame = null;
    _lastPublishFrame = null;
    _carryText = 0;
    _carryThinking = 0;
  }

  void _dropPending() {
    _stopFrameCallback();
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
