import 'package:flutter/material.dart';

/// Стиль ASTAT: чёрный, белый, моноширинный шрифт, острые углы и линии в 1 px вместо теней.
class AstatColors extends ThemeExtension<AstatColors> {
  const AstatColors({required this.bg, required this.surface, required this.surface2, required this.border, required this.text, required this.muted});

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color border;
  final Color text;
  final Color muted;

  static const dark = AstatColors(
    bg: Color(0xFF000000),
    surface: Color(0xFF0A0A0A),
    surface2: Color(0xFF141414),
    border: Color(0xFF2C2C2C),
    text: Color(0xFFF0F0F0),
    muted: Color(0xFF969696),
  );

  static const light = AstatColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF4F4F4),
    border: Color(0xFFD6D6D6),
    text: Color(0xFF0A0A0A),
    muted: Color(0xFF646464),
  );

  @override
  AstatColors copyWith() => this;

  @override
  AstatColors lerp(ThemeExtension<AstatColors>? other, double t) => t < 0.5 || other is! AstatColors ? this : other;
}

extension AstatTheme on BuildContext {
  AstatColors get c => Theme.of(this).extension<AstatColors>()!;
}

const monoFont = 'JetBrainsMono';
const radius = 5.0;

TextStyle mono(Color color, double size, {FontWeight weight = FontWeight.w400, double? height, double spacing = 0}) =>
    TextStyle(fontFamily: monoFont, color: color, fontSize: size, fontWeight: weight, height: height, letterSpacing: spacing);

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AstatColors.dark : AstatColors.light;
  final base = ThemeData(brightness: brightness, useMaterial3: true, fontFamily: monoFont);
  return base.copyWith(
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.text.withValues(alpha: 0.05),
    colorScheme: ColorScheme.fromSeed(seedColor: c.text, brightness: brightness).copyWith(
      primary: c.text,
      onPrimary: c.bg,
      secondary: c.text,
      onSecondary: c.bg,
      surface: c.bg,
      onSurface: c.text,
      error: c.text,
      onError: c.bg,
      outline: c.border,
    ),
    textTheme: base.textTheme.apply(fontFamily: monoFont, bodyColor: c.text, displayColor: c.text),
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.text, selectionColor: c.text.withValues(alpha: 0.25), selectionHandleColor: c.text),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: mono(c.text, 15, weight: FontWeight.w800, spacing: 1.2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.surface2,
      hintStyle: mono(c.muted, 14),
      labelStyle: mono(c.muted, 14),
      floatingLabelStyle: mono(c.text, 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: c.text)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.text,
      contentTextStyle: mono(c.bg, 13, weight: FontWeight.w500),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: c.border)),
      titleTextStyle: mono(c.text, 16, weight: FontWeight.w700),
      contentTextStyle: mono(c.muted, 13, height: 1.5),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: const BorderRadius.vertical(top: Radius.circular(radius)), side: BorderSide(color: c.border)),
    ),
    extensions: [c],
  );
}
