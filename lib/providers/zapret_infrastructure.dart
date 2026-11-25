import 'dart:io';
import 'dart:typed_data';

import 'package:yaml/yaml.dart';

/// Read-only projection of the effective Mihomo profile. No system DNS
/// lookups and no mutations of the subscription or its DNS settings.
class ZapretInfrastructure {
  const ZapretInfrastructure(this.domains, this.ips);

  final List<String> domains;
  final List<String> ips;

  Map<String, List<String>> toJson() => {'domains': domains, 'ips': ips};

  String get fingerprint => [domains.join('\n'), ips.join('\n')].join('\u0000');

  static ZapretInfrastructure fromYaml(String yaml) {
    final config = loadYaml(yaml);
    if (config != null && config is! Map) {
      throw const FormatException('Mihomo profile is not a mapping');
    }
    final root = config is Map ? config : const <String, Object?>{};
    final domains = <String>{};
    final ips = <String>{};

    void addIp(String value) {
      final parts = value.split('/');
      if (parts.length > 2) return;
      final address = InternetAddress.tryParse(parts.first);
      if (address == null) return;
      if (parts.length == 1) {
        ips.add(address.address);
        return;
      }
      final prefix = int.tryParse(parts.last);
      final bytes = Uint8List.fromList(address.rawAddress);
      if (prefix == null || prefix < 0 || prefix > bytes.length * 8) return;
      // Normalize a host/prefix to its network address.
      for (var i = 0; i < bytes.length; i++) {
        final remaining = prefix - i * 8;
        if (remaining <= 0) {
          bytes[i] = 0;
        } else if (remaining < 8) {
          bytes[i] &= (0xff << (8 - remaining)) & 0xff;
        }
      }
      final network = InternetAddress.fromRawAddress(bytes);
      ips.add([network.address, prefix.toString()].join('/'));
    }

    void addHost(Object? raw) {
      if (raw is Iterable) {
        for (final item in raw) {
          addHost(item);
        }
        return;
      }
      if (raw is! String) return;
      var value = raw.trim().toLowerCase();
      if (value.isEmpty) return;
      if (InternetAddress.tryParse(value.split('/').first) != null) {
        addIp(value);
        return;
      }
      if (value.startsWith('+.') || value.startsWith('*.')) {
        value = value.substring(2);
      }
      if (value.endsWith('.')) value = value.substring(0, value.length - 1);
      if (value.length > 253 || value.isEmpty) return;
      final labels = value.split('.');
      final valid = labels.every((label) =>
          label.isNotEmpty &&
          label.length <= 63 &&
          RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label));
      if (valid) domains.add(value);
    }

    void addEndpoint(Object? raw) {
      if (raw is Iterable) {
        for (final item in raw) {
          addEndpoint(item);
        }
        return;
      }
      if (raw is! String) return;
      final value = raw.split('#').first.trim();
      if (value.isEmpty || value == 'system') return;
      if (InternetAddress.tryParse(value) != null) {
        addIp(value);
        return;
      }
      final hasScheme = value.contains('://');
      final uri = Uri.tryParse(hasScheme ? value : 'tcp://$value');
      if (uri == null) return;
      if (hasScheme &&
          !const {'http', 'https', 'h3', 'tls', 'quic', 'tcp', 'udp'}
              .contains(uri.scheme.toLowerCase())) {
        return;
      }
      addHost(uri.host);
    }

    final hosts = root['hosts'];
    if (hosts is Map) {
      for (final entry in hosts.entries) {
        addHost(entry.key);
        addHost(entry.value);
      }
    }
    final tun = root['tun'];
    if (tun is Map && tun['route-exclude-address'] is Iterable) {
      for (final address in tun['route-exclude-address'] as Iterable) {
        if (address is String) addIp(address.trim());
      }
    }
    final dns = root['dns'];
    if (dns is Map) {
      for (final key in const ['fake-ip-range', 'fake-ip-range6']) {
        final value = dns[key];
        if (value is String) addIp(value.trim());
      }
      for (final key in const [
        'nameserver',
        'default-nameserver',
        'fallback',
        'proxy-server-nameserver',
        'direct-nameserver',
      ]) {
        addEndpoint(dns[key]);
      }
      for (final key in const [
        'nameserver-policy',
        'proxy-server-nameserver-policy',
      ]) {
        final policy = dns[key];
        if (policy is Map) {
          for (final value in policy.values) {
            addEndpoint(value);
          }
        }
      }
    }
    final proxies = root['proxies'];
    if (proxies is Iterable) {
      for (final proxy in proxies) {
        if (proxy is Map) addEndpoint(proxy['server']);
      }
    }
    return ZapretInfrastructure(
      List.unmodifiable(domains.toList()..sort()),
      List.unmodifiable(ips.toList()..sort()),
    );
  }
}
