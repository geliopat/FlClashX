import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/typography.dart';

/// A null [badge] clears one set further up, for titles nested in a marked one.
class TitleBadge extends InheritedWidget {
  const TitleBadge({super.key, required this.badge, this.caption, required super.child});

  final Widget? badge;
  final String? caption;

  static String? captionOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TitleBadge>()?.caption;

  static Widget? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TitleBadge>()?.badge;

  static Widget wrap(BuildContext context, Widget title) {
    final badge = of(context);
    final caption = captionOf(context);
    final heading = badge == null ? title : Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: title),
        const SizedBox(width: 6),
        badge,
      ],
    );
    if (caption == null) return heading;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading,
        const SizedBox(height: 2),
        Tooltip(
          message: caption,
          child: Text(caption, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote.of(context).copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )),
        ),
      ],
    );
  }

  @override
  bool updateShouldNotify(TitleBadge oldWidget) =>
      badge != oldWidget.badge || caption != oldWidget.caption;
}
