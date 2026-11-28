import 'dart:io';

import 'package:flutter/widgets.dart';

import 'bistre_icons.dart';
import 'bistre_theme.dart';

/// Circular local profile avatar thumbnail decoded at bounded display pixels via [ResizeImage].
/// Performs zero synchronous filesystem existence checks during build and falls back cleanly
/// to [fallbackIcon] when [path] is empty or unreadable.
class UserAvatarThumb extends StatelessWidget {
  const UserAvatarThumb({
    super.key,
    required this.path,
    required this.size,
    this.fallbackIcon = BistreUiIcon.assistant,
    this.fallbackColor,
  });

  final String path;
  final double size;
  final BistreUiIcon fallbackIcon;
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final decodePx = (size * dpr).round().clamp(16, 256);
    final iconColor = fallbackColor ?? theme.inkMuted;
    final fallback = BistreIcon(
      fallbackIcon,
      size: (size * 0.52).clamp(11.0, 20.0),
      color: iconColor,
    );

    final trimmed = path.trim();
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: theme.bgSurface,
        alignment: Alignment.center,
        child: trimmed.isEmpty
            ? fallback
            : Image(
                image: ResizeImage(
                  FileImage(File(trimmed)),
                  width: decodePx,
                  height: decodePx,
                ),
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
