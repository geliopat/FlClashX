import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/title_tabs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'connections.dart';
import 'requests.dart';

class ConnectionFeedsView extends ConsumerStatefulWidget {
  const ConnectionFeedsView({super.key});

  @override
  ConsumerState<ConnectionFeedsView> createState() =>
      _ConnectionFeedsViewState();
}

class _ConnectionFeedsViewState extends ConsumerState<ConnectionFeedsView> {
  final _shown = <RequestFeed>{};

  Widget _titleTabs(RequestFeed feed) {
    final l = context.appLocalizations;
    return PageTitleTabs(
      labels: [l.liveConnections, l.recentRequests],
      selectedIndex: feed == RequestFeed.live ? 0 : 1,
      onSelected: (index) => ref.read(appSettingProvider.notifier).update(
        (state) => state.copyWith(requestFeed:
            index == 0 ? RequestFeed.live : RequestFeed.recent),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(
      appSettingProvider.select((state) => state.requestFeed),
    );
    _shown.add(feed);
    final pageActive = PageActivityScope.isActiveOf(context);
    final titleTabs = _titleTabs(feed);
    return IndexedStack(
      index: feed.index,
      children: [
        for (final option in RequestFeed.values)
          if (!_shown.contains(option))
            const SizedBox.shrink()
          else
            PageActivityScope(
              isActive: pageActive && option == feed,
              child: TickerMode(
                enabled: option == feed,
                child: ExcludeFocus(
                  excluding: option != feed,
                  child: switch (option) {
                    RequestFeed.recent => RequestsView(
                      titleWidget: titleTabs,
                    ),
                    RequestFeed.live => ConnectionsView(
                      titleWidget: titleTabs,
                    ),
                  },
                ),
              ),
            ),
      ],
    );
  }
}
