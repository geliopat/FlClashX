import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Mask only the scrolling content, leaving the already-painted page
/// backdrop and native window material untouched. The title itself is outside
/// this shader layer. A null anchor gives an identity mask.
class TitleContentMask extends StatelessWidget {
  const TitleContentMask({super.key, required this.title, required this.child});

  final Rect? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    return ShaderMask(
      blendMode: BlendMode.dstOut,
      shaderCallback: (bounds) => titleContentShader(bounds, title, direction),
      child: child,
    );
  }
}

Rect titleMaskExtent(Rect bounds, Rect title, TextDirection direction) {
  final distance = direction == TextDirection.ltr
      ? title.right - bounds.left : bounds.right - title.left;
  final width = math.min(bounds.width, math.max(0.0, distance + 26));
  final height = math.min(bounds.height, math.max(65.0, title.bottom - bounds.top + 14));
  return direction == TextDirection.ltr
      ? Rect.fromLTWH(bounds.left, bounds.top, width, height)
      : Rect.fromLTWH(bounds.right - width, bounds.top, width, height);
}

ui.Shader titleContentShader(Rect bounds, Rect? title, TextDirection direction) {
  if (title == null || bounds.isEmpty || title.isEmpty) {
    return const LinearGradient(colors: [Colors.transparent, Colors.transparent])
        .createShader(bounds);
  }
  final area = titleMaskExtent(bounds, title, direction);
  if (area.isEmpty) {
    return const LinearGradient(colors: [Colors.transparent, Colors.transparent])
        .createShader(bounds);
  }
  // Ellipse anchored at the leading edge, centred vertically on the text.
  // The solid part protects the title; the outer ring eases into content.
  final cy = title.center.dy.clamp(area.top, area.bottom).toDouble();
  final cx = direction == TextDirection.ltr ? area.left : area.right;
  final ry = math.max(cy - area.top, area.bottom - cy) + 6;
  final matrix = Float64List.fromList([
    area.width, 0, 0, 0,
    0, ry, 0, 0,
    0, 0, 1, 0,
    cx, cy, 0, 1,
  ]);
  return ui.Gradient.radial(
    Offset.zero, 1,
    const [Color(0xFF000000), Color(0xFF000000), Color(0xB8000000),
      Color(0x40000000), Colors.transparent],
    const [0, .73, .83, .94, 1],
    TileMode.clamp, matrix,
  );
}
