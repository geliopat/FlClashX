/// The speed measurement uses a named outbound without changing the selected
/// group. DIRECT is always resolved by the core using Yandex Internetometer.
class ProxySpeedRequest {
  const ProxySpeedRequest({
    required this.proxyName,
    required this.service,
    this.downloadUrl = '',
    this.uploadUrl = '',
  });
  final String proxyName;
  final String service;
  final String downloadUrl;
  final String uploadUrl;
  Map<String, Object?> toJson() => {
    'proxy-name': proxyName,
    'service': service,
    'download-url': downloadUrl,
    'upload-url': uploadUrl,
  };
}

class ProxySpeedResult {
  const ProxySpeedResult({
    this.download,
    this.upload,
    this.downloadError = '',
    this.uploadError = '',
  });
  final double? download;
  final double? upload;
  final String downloadError;
  final String uploadError;
  factory ProxySpeedResult.fromJson(Map<String, dynamic> json) =>
      ProxySpeedResult(
        download: (json['download'] as num?)?.toDouble(),
        upload: (json['upload'] as num?)?.toDouble(),
        downloadError: json['download-error'] as String? ?? '',
        uploadError: json['upload-error'] as String? ?? '',
      );
}
