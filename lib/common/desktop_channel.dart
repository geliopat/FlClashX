import 'dart:io';

import 'package:path/path.dart' as p;

/// The name setup.dart gives a Windows or Linux pre-release's executable.
const preExecutableName = 'FlClashXPre';

bool isPreExecutable(String executable) {
  final context = executable.contains(r'\') ? p.windows : p.posix;
  final name = context.basenameWithoutExtension(executable);
  return name == preExecutableName || name == 'FlClashZPre';
}

final bool isPreDesktopApp =
    (Platform.isWindows || Platform.isLinux) &&
    isPreExecutable(Platform.resolvedExecutable);

String helperServiceFor({required bool pre, bool? isWindows}) {
  // Windows has one machine-wide Helper. A pre-release replaces the stable
  // service instead of registering a second listener on another port.
  if (isWindows ?? Platform.isWindows) return 'FlClashZHelperService';
  return pre ? 'FlClashXPreHelperService' : 'FlClashXHelperService';
}

String helperPortKeyFor(String service) =>
    'SYSTEM\\CurrentControlSet\\Services\\$service\\Runtime';

String helperSocketPathFor({required bool pre}) =>
    '/run/${pre ? 'flclashx-pre' : 'flclashx'}/helper.sock';

String helperUnitPathFor({required bool pre}) =>
    '/etc/systemd/system/${pre ? 'flclashx-pre-helper' : 'flclashx-helper'}.service';
