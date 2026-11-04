import 'package:flutter/material.dart';

/// Brand seed: a cool teal that stays legible on near-black video surfaces.
const Color _seed = Color(0xFF0FB5A8);

/// Semantic status colours (connected / warning / error) that adapt to the
/// current brightness. Access with `StatusColors.of(context)`.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.success,
    required this.warning,
    required this.danger,
    required this.neutral,
  });

  final Color success;
  final Color warning;
  final Color danger;
  final Color neutral;

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>()!;

  static const dark = StatusColors(
    success: Color(0xFF4ADE80),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFF87171),
    neutral: Color(0xFF94A3B8),
  );

  static const light = StatusColors(
    success: Color(0xFF15803D),
    warning: Color(0xFFB45309),
    danger: Color(0xFFB91C1C),
    neutral: Color(0xFF64748B),
  );

  @override
  StatusColors copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? neutral,
  }) => StatusColors(
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    neutral: neutral ?? this.neutral,
  );

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  var scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  if (isDark) {
    // Slightly deeper surfaces so the UI recedes behind live video.
    scheme = scheme.copyWith(
      surface: const Color(0xFF0E1415),
      surfaceContainerLowest: const Color(0xFF090E0F),
      surfaceContainerLow: const Color(0xFF141B1C),
      surfaceContainer: const Color(0xFF182021),
      surfaceContainerHigh: const Color(0xFF1F2829),
      surfaceContainerHighest: const Color(0xFF283233),
    );
  }

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
  );

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    extensions: [isDark ? StatusColors.dark : StatusColors.light],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 2,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainer,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
