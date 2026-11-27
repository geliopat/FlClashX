import 'package:material_ui/material_ui.dart';

const defaultGlowIntensity = 1.0;

double normalizeGlowIntensity(double? value) =>
    value == null || !value.isFinite
        ? defaultGlowIntensity
        : value.clamp(0.0, 1.0).toDouble();

/// The same hover treatment for all consumers, with independent keyboard focus.
class HoverGlowTheme extends ThemeExtension<HoverGlowTheme> {
  const HoverGlowTheme(this.intensity);

  final double intensity;

  static HoverGlowTheme of(BuildContext context) =>
      Theme.of(context).extension<HoverGlowTheme>() ??
      const HoverGlowTheme(defaultGlowIntensity);

  List<Shadow> shadows(Color color, {required bool hovered}) {
    final strength = normalizeGlowIntensity(intensity);
    if (!hovered || strength == 0) return const [];
    return [
      Shadow(
        color: color.withValues(alpha: color.a * .75 * strength),
        blurRadius: 6 * strength,
      ),
    ];
  }

  @override
  HoverGlowTheme copyWith({double? intensity}) =>
      HoverGlowTheme(intensity ?? this.intensity);

  @override
  HoverGlowTheme lerp(HoverGlowTheme? other, double t) =>
      other == null ? this : HoverGlowTheme(intensity + (other.intensity - intensity) * t);

  @override
  bool operator ==(Object other) =>
      other is HoverGlowTheme && other.intensity == intensity;

  @override
  int get hashCode => intensity.hashCode;
}
