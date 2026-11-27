import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/title_tabs.dart';
import 'package:material_ui/material_ui.dart';

import 'connections.dart';
import 'requests.dart';

class ConnectionFeedsView extends StatefulWidget {
  const ConnectionFeedsView({super.key});

  @override
  State<ConnectionFeedsView> createState() =>
      _ConnectionFeedsViewState();
}

class _ConnectionFeedsViewState extends State<ConnectionFeedsView> {
  final _shown = <RequestFeed>{};
  RequestFeed _feed = RequestFeed.live;
  bool _pageActive = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = PageActivityScope.isActiveOf(context);
    if (active && !_pageActive) {
      _feed = RequestFeed.live;
    }
    _pageActive = active;
  }

  Widget _titleTabs(RequestFeed feed) {
    final l = context.appLocalizations;
    return PageTitleTabs(
      labels: [l.liveConnections, l.recentRequests],
      selectedIndex: feed == RequestFeed.live ? 0 : 1,
      onSelected: (index) => setState(() {
        _feed = index == 0 ? RequestFeed.live : RequestFeed.recent;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed;
    _shown.add(feed);
    final pageActive = _pageActive;
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
