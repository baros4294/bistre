import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/ink_primitives.dart';

/// The chat title in the header, renamed in place (2a-2c).
///
/// Enter, a click elsewhere, or moving focus away saves; Esc cancels and restores the title,
/// handled here before the shell's own Esc (which may stop a reply). The editor belongs to
/// one chat: the shell keys it by chat id (and Settings), so switching chats or opening
/// Settings ends an edit without saving it anywhere. The box fits the title, up to 420 px.
class InlineTitleEditor extends StatefulWidget {
  const InlineTitleEditor({
    super.key,
    required this.title,
    required this.placeholder,
    required this.onRename,
    required this.displayBuilder,
  });

  final String title;
  final String placeholder;
  final ValueChanged<String> onRename;

  /// The title at rest; calls the given callback to start editing.
  final Widget Function(BuildContext context, VoidCallback startEditing)
  displayBuilder;

  @override
  State<InlineTitleEditor> createState() => _InlineTitleEditorState();
}

class _InlineTitleEditorState extends State<InlineTitleEditor> {
  static const double _maxWidth = 420;

  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'title-rename');
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    _ctrl.value = TextEditingValue(
      text: widget.title,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: widget.title.length,
      ),
    );
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focus.requestFocus();
    });
  }

  void _onFocusChange() {
    if (_editing && !_focus.hasFocus) _commit();
  }

  void _commit() {
    if (!_editing) return;
    final next = _ctrl.text.trim();
    setState(() => _editing = false);
    if (next.isNotEmpty && next != widget.title) widget.onRename(next);
  }

  void _cancel() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) return widget.displayBuilder(context, _start);
    return Flexible(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: IntrinsicWidth(
          child: Focus(
            // Esc never reaches the shell from here.
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape &&
                  !_ctrl.value.composing.isValid) {
                _cancel();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: QuillInput(
              controller: _ctrl,
              focusNode: _focus,
              placeholder: widget.placeholder,
              maxLines: 1,
              compact: true,
              onSubmitted: _commit,
              onTapOutside: (_) => _commit(),
            ),
          ),
        ),
      ),
    );
  }
}
