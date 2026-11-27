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
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: index == selectedIndex
                        ? colors.onSurface
                        : colors.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 40),
                    elevation: 0,
                  ),
                  onPressed: () => onSelected(index),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color: index == selectedIndex
                              ? colors.primary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        labels[index],
                        maxLines: 1,
                        style: AppTextStyle.headline.of(
                          context,
                          emphasized: index == selectedIndex,
                        ).copyWith(
                          color: index == selectedIndex
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
