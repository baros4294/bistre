import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Selected text across [child]'s separate text widgets (paragraphs, list items, code rows)
/// copies with a line break between them; Flutter's default joins them with nothing.
class LineSelection extends StatefulWidget {
  const LineSelection({super.key, required this.child});

  final Widget child;

  @override
  State<LineSelection> createState() => _LineSelectionState();
}

class _LineSelectionState extends State<LineSelection> {
  final _LineJoinDelegate _delegate = _LineJoinDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

class _LineJoinDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final parts = <String>[
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final SelectedContent data
            when data.plainText.isNotEmpty)
          data.plainText,
    ];
    if (parts.isEmpty) return null;
    return SelectedContent(plainText: parts.join('\n'));
  }
}
