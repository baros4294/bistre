import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/press_feedback.dart';

/// Side of a sent picture's thumbnail, in logical pixels.
const double kSentThumbSide = 96;

/// Longest side a thumbnail is decoded at, in pixels (three times its side, for 3x screens),
/// so a large photo never decodes in full for a 96 dp tile.
const int kSentThumbDecodePx = 288;

/// A picture sent with a message, shown as a small thumbnail that opens its preview; a file
/// that cannot be read shows its type icon instead.
class SentPictureThumb extends StatelessWidget {
  const SentPictureThumb({
    super.key,
    required this.path,
    required this.name,
    required this.onOpen,
  });

  final String path;
  final String name;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return PressableArea(
      label: name,
      onPressed: onOpen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: kSentThumbSide,
          child: ColoredBox(
            color: theme.bgElevated,
            child: Image(
              image: ResizeImage(
                FileImage(File(path)),
                width: kSentThumbDecodePx,
                height: kSentThumbDecodePx,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => Center(
                child: BistreIcon(
                  BistreUiIcon.eye,
                  size: 20,
                  color: theme.inkMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
