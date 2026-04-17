import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Avatar utente riutilizzabile con fallback a iniziale.
///
/// Supporta:
/// - Immagine da URL con cache (CachedNetworkImage)
/// - Fallback a iniziale del nome
/// - Badge overlay opzionale (es. indicatore online)
/// - Dimensioni configurabili
class UserAvatar extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final double size;
  final Color? borderColor;
  final double borderWidth;
  final Widget? badge;

  const UserAvatar({
    super.key,
    this.imageUrl,
    required this.name,
    this.size = 48,
    this.borderColor,
    this.borderWidth = 0,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;

    Widget avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        shape: BoxShape.circle,
        border: borderWidth > 0
            ? Border.all(
                color: borderColor ?? theme.colorScheme.primary,
                width: borderWidth,
              )
            : null,
      ),
      child: hasImage
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: imageUrl!,
                fit: BoxFit.cover,
                width: size,
                height: size,
                placeholder: (_, __) => _InitialFallback(
                  initial: initial,
                  size: size,
                  theme: theme,
                ),
                errorWidget: (_, __, ___) => _InitialFallback(
                  initial: initial,
                  size: size,
                  theme: theme,
                ),
              ),
            )
          : _InitialFallback(initial: initial, size: size, theme: theme),
    );

    if (badge != null) {
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(bottom: 0, right: 0, child: badge!),
        ],
      );
    }

    return avatar;
  }
}

class _InitialFallback extends StatelessWidget {
  final String initial;
  final double size;
  final ThemeData theme;

  const _InitialFallback({
    required this.initial,
    required this.size,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
