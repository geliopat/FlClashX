import 'package:fl_clash/ui/hover_glow.dart';
import 'package:fl_clash/ui/context.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

/// A compact page switcher in the title slot. Use the application's own
/// buttons and theme, not Flutter Material's unrelated TabBar scopes.
class PageTitleTabs extends StatelessWidget {
  const PageTitleTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final glow = HoverGlowTheme.of(context);
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        primary: false,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < labels.length; index++)
              Semantics(
                selected: index == selectedIndex,
                child: TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    overlayColor: Colors.transparent,
                    foregroundColor: index == selectedIndex
                        ? colors.primary : colors.onSurfaceVariant,
                    padding: EdgeInsetsDirectional.only(
                      start: index == 0 ? 0 : 10, end: 10,
                    ),
                    minimumSize: const Size(0, 40),
                    elevation: 0,
                  ).copyWith(
                    textStyle: WidgetStateProperty.resolveWith((states) {
                      final color = index == selectedIndex
                          ? colors.primary : colors.onSurfaceVariant;
                      return AppTextStyle.headline.of(
                        context, emphasized: index == selectedIndex,
                      ).copyWith(
                        color: color,
                        shadows: glow.shadows(colors.primary,
                          hovered: states.contains(WidgetState.hovered)),
                      );
                    }),
                  ),
                  onPressed: () => onSelected(index),
                  child: Text(labels[index], maxLines: 1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
