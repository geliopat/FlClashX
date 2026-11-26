import 'dart:io';

import 'file.dart';
import 'path.dart';
import 'print.dart';

/// Separate from the settings JSON, but stored alongside it in the app home.
/// Portable and installed stable builds resolve the same home directory.
class WindowsDisclaimerConsent {
  WindowsDisclaimerConsent({required this.markerPath});

  final Future<String> Function() markerPath;
  static const _accepted = '1\n';

  Future<bool> ensure({
    required bool legacyAccepted,
    required bool environmentAccepted,
    required Future<bool> Function() request,
  }) async {
    File? marker;
    try {
      marker = File(await markerPath());
      if (await marker.exists() &&
          (await marker.readAsString()).trim() == '1') {
        return true;
      }
    } catch (error) {
      commonPrint.log('Disclaimer consent read failed: $error');
    }
    if (!legacyAccepted && !environmentAccepted && !await request()) {
      return false;
    }
    // Flush the independent marker before allowing startup to proceed.
    try {
      await (marker ?? File(await markerPath())).writeAsStringAtomically(
        _accepted,
      );
    } catch (error) {
      // The caller also persists the accepted version in settings.
      commonPrint.log('Disclaimer consent write failed: $error');
    }
    return true;
  }
}

final windowsDisclaimerConsent = WindowsDisclaimerConsent(
  markerPath: () => appPath.disclaimerConsentPath,
);
