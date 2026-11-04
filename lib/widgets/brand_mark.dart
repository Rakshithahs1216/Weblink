import 'package:flutter/material.dart';

/// App logo: a gradient tile with a robot glyph.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.3),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primary, scheme.tertiary],
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.35),
              blurRadius: size * 0.4,
              offset: Offset(0, size * 0.1),
            ),
          ],
        ),
        child: Icon(
          Icons.smart_toy_outlined,
          size: size * 0.55,
          color: scheme.onPrimary,
        ),
      ),
    );
  }
}
