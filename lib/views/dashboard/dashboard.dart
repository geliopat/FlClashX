import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'edit.dart';
import 'provider_mode.dart';
import 'layout.dart';
import 'style.dart';
import 'wide.dart';
import 'widget_registry.dart';
import 'widgets/core_status_button.dart';
import 'widgets/engine_controls.dart';
import 'widgets/zapret_status_button.dart';
import 'widgets/profile_detail.dart';

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key, this.platform});

  /// The host's platform when null.
  final SupportPlatform? platform;

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  var _editing = false;
  var _wide = false;

  /// What editing started from, kept across resizes until the cards are picked.
  List<DashboardWidget>? _editedArrangement;
  final _cardKeys = <DashboardWidget, GlobalKey>{};

  void _setEditing(bool editing, SupportPlatform platform) {
    final chosen = ref.read(appSettingProvider).dashboardWidgetsChosen;
    setState(() {
      _editing = editing;
      _editedArrangement = editing && _wide && !chosen
          ? wideDashboardWidgetsOf(platform)
          : null;
    });
  }

  GlobalKey _cardKeyOf(DashboardWidget widget) =>
      _cardKeys.putIfAbsent(widget, GlobalKey.new);

  @override
  Widget build(BuildContext context) {
    final platform = widget.platform ?? SupportPlatform.currentPlatform;
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    final providerMode = ref.watch(providerModeProvider);
    final zapretWidgetEnabled = ref.watch(
      currentProfileProvider.select(
        (profile) =>
            profile?.headers.dashboardWidgets?.contains(DashboardWidget.zapret) ??
            false,
      ),
    );
    final editable = !ref.watch(widgetEditingDeniedProvider);
    final widgetsReleasable = ref.watch(
      settingReleasableProvider(dashboardWidgetsSetting),
    );
    final chosen = ref.watch(
      appSettingProvider.select((state) => state.dashboardWidgetsChosen),
    );
    if (!editable) {
      _editing = false;
    }
    final editing = _editing;
    final gap = cardSpacingOf(context, ref.watch(viewModeProvider));
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      backgroundColor: DashboardColors.of(context).page,
      title: editing
          ? appLocalizations.editDashboard
          : appLocalizations.dashboard,
      actions: [
        if (!editing && IntegratedWindowHeaderScope.maybeOf(context)?.hasStatusActions != true)
          const CoreStatusButton(),
        if (editable && !editing && widgetsReleasable)
          ManagedSetting(
            settingKey: dashboardWidgetsSetting,
            dimsWhenLocked: false,
            showsLock: false,
            child: AppBarActionButton(
              data: IconButtonData(
                glyph: AppGlyphs.edit,
                tooltip: appLocalizations.editDashboard,
                onPressed: () => _setEditing(true, platform),
              ),
            ),
          ),
      ],
      confirmationAction: editing
          ? IconButtonData(
              glyph: AppGlyphs.check,
              tooltip: appLocalizations.done,
              onPressed: () => _setEditing(false, platform),
            )
          : null,
      iconActions: [
        if (editable && !editing && !widgetsReleasable)
          IconButtonData(
            glyph: AppGlyphs.edit,
            tooltip: appLocalizations.editDashboard,
            onPressed: () => _setEditing(true, platform),
          ),
      ],
      // The providers learn a resize a frame late, too late for the cards.
      body: LayoutBuilder(
        builder: (context, constraints) {
          final room = constraints.biggest / scale;
          final layout = DashboardDensity.of(room);
          // The provider's few cards stay a column at any width: the grid
          // would stretch each over a row sized for the standard cards.
          final grid = layout.isDesktop && !providerMode;
          _wide = grid;
          final arranged = editing
              ? (chosen ? null : _editedArrangement)
              : grid && !chosen
              ? wideDashboardWidgetsOf(platform)
              : null;
          if (grid && !editing) {
            return DashboardDensityScope(
              density: layout,
              scale: scale,
              child: platform == SupportPlatform.Windows
                  ? Column(children: [
                      Expanded(child: _WideCards(platform: platform, arranged: arranged,
                        columns: dashboardColumnsOf(room.width), gap: gap)),
                      Padding(
                        padding: EdgeInsets.only(bottom: 16 + context.bottomInset),
                        child: const EngineControlsLayout(vpn: ProviderConnectButton(), zapret: ProviderZapretButton()),
                      ),
                    ])
                  : _WideCards(platform: platform, arranged: arranged,
                    columns: dashboardColumnsOf(room.width), gap: gap),
            );
          }
          return DashboardDensityScope(
            density: DashboardDensity.mobile,
            scale: scale,
            child: _MobileDashboard(
              platform: platform,
              arranged: arranged,
              gap: gap,
              editing: editing,
              providerMode: providerMode,
              zapretWidgetEnabled: zapretWidgetEnabled,
              cardKeyOf: _cardKeyOf,
              onDone: () => _setEditing(false, platform),
            ),
          );
        },
      ),
    );
  }
}

class _WideCards extends ConsumerWidget {
  const _WideCards({
    required this.platform,
    required this.arranged,
    required this.columns,
    required this.gap,
  });

  final SupportPlatform platform;
  final List<DashboardWidget>? arranged;
  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<DashboardWidget> saved =
        arranged ??
        ref.watch(
          dashboardStateProvider.select((state) => state.dashboardWidgets),
        );
    final announcement = ref.watch(announcementProvider) != null;
    return WideDashboard(
      cards: withFixedCards([
        for (final widget in saved)
          if (widget.platforms.contains(platform)) widget,
      ], announcement: announcement, platform: platform),
      columns: columns,
      gap: gap,
    );
  }
}

class _MobileDashboard extends ConsumerWidget {
  const _MobileDashboard({
    required this.platform,
    required this.arranged,
    required this.gap,
    required this.editing,
    required this.providerMode,
    required this.zapretWidgetEnabled,
    required this.cardKeyOf,
    required this.onDone,
  });

  final SupportPlatform platform;

  /// The wide arrangement a wide window edits until someone picks the cards.
  final List<DashboardWidget>? arranged;
  final double gap;
  final bool editing;
  final bool providerMode;
  final bool zapretWidgetEnabled;
  final GlobalKey Function(DashboardWidget widget) cardKeyOf;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<DashboardWidget> saved =
        arranged ??
        ref.watch(
          dashboardStateProvider.select((state) => state.dashboardWidgets),
        );
    final announcement = ref.watch(announcementProvider) != null;
    final top = MediaQuery.paddingOf(context).top + 4;
    final footed = !editing && (providerMode || platform == SupportPlatform.Windows);
    // The start button takes the bottom inset when it holds the foot.
    final bottom = footed ? 12.0 : 16 + context.bottomInset;
    final pullable =
        !editing &&
        platform == SupportPlatform.Android &&
        ref.watch(
          currentProfileProvider.select(
            (profile) => profile?.type == ProfileType.url,
          ),
        );
    final Widget scroll = CustomScrollView(
      // A viewport per card lays them all out and holds the scroll end still.
      scrollCacheExtent: editing
          ? ScrollCacheExtent.viewport(DashboardWidget.values.length.toDouble())
          : null,
      slivers: [
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final side = dashboardMobileSideOf(constraints.crossAxisExtent);
            final widgets = withFixedCards(
              [
                for (final widget in saved)
                  if (widget.platforms.contains(platform)) widget,
              ],
              announcement: announcement,
              providerMode: providerMode,
              platform: platform,
            );
            if (editing) {
              return DashboardEditor(
                platform: platform,
                widgets: widgets,
                cardKeyOf: cardKeyOf,
                padding: EdgeInsets.fromLTRB(side, top, side, bottom),
                gap: gap,
                onDone: onDone,
              );
            }
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(side, top, side, bottom),
              // A lazy list estimates the cards it has not laid out from the
              // ones it has; cards this uneven move the scroll end as it goes.
              sliver: SliverToBoxAdapter(
                child: Column(
                  spacing: gap,
                  children: [
                    if (providerMode)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: ProviderHeader(),
                      ),
                    for (final widget in widgets)
                      RepaintBoundary(
                        key: cardKeyOf(widget),
                        child: widget.card,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
    final appLocalizations = context.appLocalizations;
    final content = pullable
        ? PullAction(
            labels: (
              pull: appLocalizations.pullToUpdateSubscription,
              release: appLocalizations.releaseToUpdateSubscription,
              running: appLocalizations.updatingSubscription,
              done: appLocalizations.subscriptionUpdated,
            ),
            onPull: () async {
              final profile = ref.read(currentProfileProvider);
              if (profile == null || profile.type != ProfileType.url) {
                return false;
              }
              return syncProfile(ref, profile);
            },
            child: scroll,
          )
        : scroll;
    if (!footed) {
      return content;
    }
    final side = dashboardMobileSideOf(MediaQuery.sizeOf(context).width);
    return Column(
      children: [
        Expanded(child: content),
        Padding(
          padding: EdgeInsets.fromLTRB(platform == SupportPlatform.Windows ? 0 : side,
            0, platform == SupportPlatform.Windows ? 0 : side, 16 + context.bottomInset),
          child: platform == SupportPlatform.Windows
              ? EngineControlsLayout(vpn: const ProviderConnectButton(),
                  zapret: !providerMode || zapretWidgetEnabled ? const ProviderZapretButton() : null)
              : const ProviderConnectButton(),
        ),
      ],
    );
  }
}
