import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import 'plain_preview.dart';
import 'tool_timeline_view.dart';

/// What a committed node carries for the feed's tool steps, parsed once per node.
class _StepMeta {
  const _StepMeta({
    this.calls = const <_Call>[],
    this.resultCallId = '',
    this.resultName = '',
    this.isError = false,
    this.riskTier = 'tier0_read_only',
    this.diffText,
    this.checkpointId,
    this.durationMs = 0,
  });

  final List<_Call> calls;
  final String resultCallId;
  final String resultName;
  final bool isError;
  final String riskTier;
  final String? diffText;
  final String? checkpointId;
  final int durationMs;

  static const empty = _StepMeta();

  static _StepMeta parse(String? json) {
    if (json == null || json.isEmpty) return empty;
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return empty;
    }
    if (decoded is! Map<String, Object?>) return empty;
    final calls = <_Call>[];
    final rawCalls = decoded['tool_calls'];
    if (rawCalls is List) {
      for (final c in rawCalls) {
        if (c is! Map<String, Object?>) continue;
        final id = c['call_id'];
        final name = c['name'];
        if (id is! String || name is! String) continue;
        final args = c['arguments_json'];
        calls.add(_Call(id, name, args is String ? args : ''));
      }
    }
    final result = decoded['tool_result'];
    final r = result is Map<String, Object?>
        ? result
        : const <String, Object?>{};
    final tier = decoded['risk_tier'];
    final diff = decoded['diff_text'];
    final cp = decoded['checkpoint_id'];
    final ms = decoded['duration_ms'];
    return _StepMeta(
      calls: calls,
      resultCallId: r['call_id'] is String ? r['call_id']! as String : '',
      resultName: r['name'] is String ? r['name']! as String : '',
      isError: r['is_error'] == true,
      riskTier: tier is String ? tier : 'tier0_read_only',
      diffText: diff is String && diff.isNotEmpty ? diff : null,
      checkpointId: cp is String && cp.isNotEmpty ? cp : null,
      durationMs: ms is int ? ms : 0,
    );
  }
}

class _Call {
  _Call(this.id, this.name, this.argumentsJson);
  final String id;
  final String name;
  final String argumentsJson;

  /// The arguments as a map, or empty when the model sent something else. Decoded once:
  /// calls are cached per node, and row labels read this on every build.
  late final Map<String, Object?> args = () {
    try {
      final v = jsonDecode(argumentsJson);
      return v is Map<String, Object?> ? v : const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }();
}

final Expando<_StepMeta> _stepCache = Expando<_StepMeta>('toolStepMeta');

_StepMeta _metaOf(EngineNode node) =>
    _stepCache[node] ??= _StepMeta.parse(node.providerMetaJson);

/// True for a tool result, or a reply that holds only tool calls (no words).
bool isToolStepNode(EngineNode node) =>
    node.role == 'tool' ||
    (node.role == 'assistant' &&
        node.content.trim().isEmpty &&
        _metaOf(node).calls.isNotEmpty);

/// The question an `ask_user` tool result holds, or null for any other node.
AskUserQuestion? askUserQuestionOf(List<EngineNode> nodes, int index) {
  final node = nodes[index];
  if (node.role != 'tool') return null;
  final meta = _metaOf(node);
  if (meta.resultName != 'ask_user' || meta.isError) return null;
  final call = _callFor(nodes, index, meta.resultCallId);
  if (call == null) return null;
  final args = call.args;
  final question = args['question'];
  if (question is! String || question.trim().isEmpty) return null;
  final options = args['options'];
  return AskUserQuestion(
    question: question.trim(),
    options: <String>[
      if (options is List)
        for (final o in options)
          if (o is String && o.trim().isNotEmpty) o.trim(),
    ],
  );
}

/// Whether [index] starts a run of tool steps (an asked question splits runs).
bool startsToolSteps(List<EngineNode> nodes, int index) =>
    _isStep(nodes, index) && (index == 0 || !_isStep(nodes, index - 1));

bool _isStep(List<EngineNode> nodes, int i) =>
    isToolStepNode(nodes[i]) && askUserQuestionOf(nodes, i) == null;

/// One finished row per tool result in the run that starts at [start], each step's
/// thinking ([withThinking]) as its own row before that step's tools, in the order they
/// happened.
List<ToolActivityEntry> committedToolEntries(
  List<EngineNode> nodes,
  int start, {
  bool withThinking = true,
}) {
  final entries = <ToolActivityEntry>[];
  for (var i = start; i < nodes.length && _isStep(nodes, i); i++) {
    final node = nodes[i];
    if (node.role != 'tool') {
      final usage = node.usageMeta;
      if (withThinking && usage != null && usage.hasThinking) {
        final text = usage.thinkingText.trim();
        final firstLine = text.split('\n').first.trim();
        entries.add(
          ToolActivityEntry(
            id: '${node.id}:thinking',
            toolName: kThinkingRow,
            summary: firstLine.length > 120
                ? '${firstLine.substring(0, wholeUnits(firstLine, 120))}…'
                : firstLine,
            status: 'completed',
            outputText: text,
            durationMs: usage.thinkingDurationMs,
            threadId: node.threadId,
          ),
        );
      }
      continue;
    }
    final meta = _metaOf(node);
    final call = _callFor(nodes, i, meta.resultCallId);
    entries.add(
      ToolActivityEntry(
        id: node.id,
        toolName: meta.resultName,
        summary: call == null ? meta.resultName : _summaryOf(call),
        status: meta.isError ? 'failed' : 'completed',
        riskTier: meta.riskTier,
        outputText: node.content,
        diffText: meta.diffText,
        checkpointId: meta.checkpointId,
        durationMs: meta.durationMs,
        threadId: node.threadId,
      ),
    );
  }
  return entries;
}

/// The live tool rows still running or waiting: a row whose result is already in [nodes]
/// shows in the feed's checklist instead. Returns [rows] itself when none are.
List<ToolActivityEntry> uncommittedToolRows(
  List<ToolActivityEntry> rows,
  List<EngineNode> nodes,
) {
  if (rows.isEmpty) return rows;
  final done = <String>{
    for (final n in nodes)
      if (n.role == 'tool') _metaOf(n).resultCallId,
  };
  if (!rows.any((e) => done.contains(e.id))) return rows;
  return <ToolActivityEntry>[
    for (final e in rows)
      if (!done.contains(e.id)) e,
  ];
}

/// The call a tool result answers: the nearest earlier reply that made it.
_Call? _callFor(List<EngineNode> nodes, int index, String callId) {
  for (var i = index - 1; i >= 0; i--) {
    final n = nodes[i];
    if (n.role == 'tool') continue;
    if (n.role != 'assistant') return null;
    for (final c in _metaOf(n).calls) {
      if (c.id == callId) return c;
    }
    return null;
  }
  return null;
}

/// A short row label from the call's own arguments (the target it acted on).
String _summaryOf(_Call call) {
  final args = call.args;
  for (final key in const <String>[
    'path',
    'from',
    'pattern',
    'command',
    'url',
    'query',
  ]) {
    final v = args[key];
    if (v is String && v.trim().isNotEmpty) {
      final s = v.trim().replaceAll('\n', ' ');
      return '${call.name} ${clipText(s, 120)}';
    }
  }
  return call.name;
}

/// A question the assistant asked, with optional short answers.
class AskUserQuestion {
  const AskUserQuestion({required this.question, required this.options});
  final String question;
  final List<String> options;
}

/// The assistant's question in the feed. [onAnswer] is null once it was answered.
class AskUserCard extends StatelessWidget {
  const AskUserCard({super.key, required this.question, this.onAnswer});

  final AskUserQuestion question;
  final ValueChanged<String>? onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final answer = onAnswer;
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: BistreSpacing.s12),
      child: FolioSurface(
        tone: FolioTone.elevated,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkText(question.question, color: theme.inkPrimary),
            if (question.options.isNotEmpty) ...[
              const SizedBox(height: BistreSpacing.s8),
              Wrap(
                spacing: BistreSpacing.s8,
                runSpacing: BistreSpacing.s8,
                children: [
                  for (final option in question.options)
                    EngravedButton(
                      label: option,
                      compact: true,
                      onPressed: answer == null ? null : () => answer(option),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
