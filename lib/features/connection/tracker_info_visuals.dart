import 'package:fl_clash/ui/network_palette.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

typedef OutboundTone = ({Color color, Color foreground});

OutboundTone _neutralTone(BuildContext context) => (
  color: Colors.transparent,
  foreground: NetworkTone.inactive.of(context),
);

OutboundTone outboundTone(BuildContext context, String name) {
  final upper = name.toUpperCase();
  final tone = upper == 'DIRECT'
      ? NetworkTone.direct
      : upper.startsWith('REJECT') || upper == 'BLOCK'
          ? NetworkTone.reject
          : upper == 'PASS' || upper == 'COMPATIBLE'
              ? NetworkTone.inactive
              : NetworkTone.proxy;
  return (color: Colors.transparent, foreground: tone.of(context));
}

class _ColoredLabel extends StatelessWidget {
  const _ColoredLabel(this.label, this.color, {this.onPressed});
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyle.caption1.of(context).copyWith(color: color);
    if (onPressed == null) {
      return Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: color,
        backgroundColor: Colors.transparent,
        overlayColor: Colors.transparent,
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: style,
      ).copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) => style.copyWith(
          shadows: states.contains(WidgetState.hovered)
              ? [Shadow(color: color, blurRadius: 6)]
              : const [],
        )),
      ),
      onPressed: onPressed,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class OutboundChip extends StatelessWidget {
  final String label;
  final bool exit;
  final VoidCallback? onPressed;

  const OutboundChip({super.key, required this.label, this.exit = true, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final tone = exit ? outboundTone(context, label) : _neutralTone(context);
    return _ColoredLabel(label, tone.foreground, onPressed: onPressed);
  }
}

class NetworkLabel extends StatelessWidget {
  final String network;

  const NetworkLabel(this.network, {super.key});

  @override
  Widget build(BuildContext context) {
    final tone = switch (network.toLowerCase()) {
      'tcp' => NetworkTone.tcp,
      'udp' => NetworkTone.udp,
      'icmp' || 'icmpv6' => NetworkTone.icmp,
      _ => NetworkTone.inactive,
    };
    return _ColoredLabel(network.toUpperCase(), tone.of(context));
  }
}

String? destinationCountryOf(TrackerInfo trackerInfo) {
  for (final code in trackerInfo.metadata.destinationGeoIP) {
    if (CountryFlag.has(code)) {
      return code.toLowerCase();
    }
  }
  return null;
}

class CountryMark extends StatelessWidget {
  final String countryCode;
  final double size;

  const CountryMark({super.key, required this.countryCode, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return ClipRSuperellipse(
      borderRadius: AppRadius.all(size / 4),
      child: SizedBox.square(
        dimension: size,
        child: CountryFlag(countryCode: countryCode),
      ),
    );
  }
}

class LetterAvatar extends StatelessWidget {
  final String text;
  final double size;

  const LetterAvatar(this.text, {super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final trimmed = text.trim();
    final letter = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colorScheme.secondaryContainer,
        shape: AppShape.all(size / 4),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: Text(
            letter,
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(color: colorScheme.onSecondaryContainer),
          ),
        ),
      ),
    );
  }
}

/// The app's icon where the platform knows it, else the destination's flag,
/// else the first letter of the host.
class TrackerAvatar extends StatelessWidget {
  final TrackerInfo trackerInfo;
  final double size;
  final bool packageIcon;
  final VoidCallback? onTap;

  const TrackerAvatar({
    super.key,
    required this.trackerInfo,
    this.size = 28,
    this.packageIcon = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final process = trackerInfo.metadata.process;
    final country = destinationCountryOf(trackerInfo);
    final Widget avatar;
    if (packageIcon && process.isNotEmpty) {
      avatar = ClipRSuperellipse(
        borderRadius: AppRadius.all(size / 4),
        child: PackageIcon(packageName: process, size: size),
      );
    } else if (country != null) {
      avatar = CountryMark(countryCode: country, size: size);
    } else {
      avatar = LetterAvatar(trackerInfo.title, size: size);
    }
    final onTap = this.onTap;
    if (onTap == null) {
      return avatar;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: avatar),
    );
  }
}

class RuleLabel extends StatelessWidget {
  final TrackerInfo trackerInfo;
  final VoidCallback? onPressed;

  const RuleLabel(this.trackerInfo, {super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final payload = trackerInfo.rulePayload;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Flexible(
          child: _ColoredLabel(
            trackerInfo.rule,
            NetworkTone.rule.of(context),
            onPressed: onPressed,
          ),
        ),
        if (payload.isNotEmpty)
          Flexible(
            child: Text(
              payload,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class SpeedText extends StatelessWidget {
  final int upload;
  final int download;

  const SpeedText({super.key, required this.upload, required this.download});

  @override
  Widget build(BuildContext context) {
    final muted = NetworkTone.inactive.of(context);
    InlineSpan part(Glyph glyph, int amount, Color active) {
      final color = amount > 0 ? active : muted;
      return TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: GlyphIcon(glyph, size: 12, color: color),
          ),
          TextSpan(
            text: ' ${amount.traffic.show}/s',
            style: TextStyle(color: color),
          ),
        ],
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          part(AppGlyphs.arrowUp, upload, NetworkTone.upload.of(context)),
          const TextSpan(text: '   '),
          part(AppGlyphs.arrowDown, download, NetworkTone.download.of(context)),
        ],
      ),
    );
  }
}
