import 'package:flutter/material.dart';

/// A compact, horizontally scrollable page switcher occupying the title slot.
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
  Widget build(BuildContext context) => DefaultTabController(
    key: ValueKey(selectedIndex),
    length: labels.length,
    initialIndex: selectedIndex,
    child: TabBar(
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerColor: Colors.transparent,
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
      onTap: onSelected,
      tabs: [for (final label in labels) Tab(text: label, height: 40)],
    ),
  );
}
