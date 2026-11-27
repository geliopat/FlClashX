/// The speed measurement uses a named outbound without changing the selected
/// group. DIRECT is always resolved by the core using Yandex Internetometer.
class ProxySpeedRequest {
  const ProxySpeedRequest({
    required this.proxyName,
    required this.service,
    this.downloadUrl = '',
    this.uploadUrl = '',
    this.streams = 4,
    this.seconds = 8,
    this.maxMB = 100,
    this.direction = 'both',
  });
  final String proxyName;
  final String service;
  final String downloadUrl;
  final String uploadUrl;
  final int streams, seconds, maxMB;
  final String direction;
  Map<String, Object?> toJson() => {
    'proxy-name': proxyName,
    'service': service,
    'download-url': downloadUrl,
    'upload-url': uploadUrl,
    'streams': streams,
    'seconds': seconds,
    'max-mb': maxMB,
    'direction': direction,
  };
}

class ProxySpeedResult {
  const ProxySpeedResult({
    this.download,
    this.upload,
    this.downloadError = '',
    this.uploadError = '',
    this.downloadBytes = 0,
    this.uploadBytes = 0,
  });
  final double? download;
  final double? upload;
  final String downloadError;
  final String uploadError;
  final int downloadBytes, uploadBytes;
  factory ProxySpeedResult.fromJson(Map<String, dynamic> json) =>
      ProxySpeedResult(
        download: (json['download'] as num?)?.toDouble(),
        upload: (json['upload'] as num?)?.toDouble(),
        downloadError: json['download-error'] as String? ?? '',
        uploadError: json['upload-error'] as String? ?? '',
        downloadBytes: (json['download-bytes'] as num?)?.toInt() ?? 0,
        uploadBytes: (json['upload-bytes'] as num?)?.toInt() ?? 0,
      );
}
