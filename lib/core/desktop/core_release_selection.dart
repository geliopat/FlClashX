import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/file.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/features/update/core_release_manifest.dart';
import 'package:path/path.dart' as p;

final _hashPattern = RegExp(r'^[0-9a-f]{64}$');

final class CoreReleaseRef {
  final String hash;
  final CoreReleaseVersion version;

  CoreReleaseRef.fromManifest(CoreReleaseManifest manifest)
    : hash = manifest.hash,
      version = manifest.version;

  CoreReleaseRef._(this.hash, this.version);

  factory CoreReleaseRef.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['hash'] is! String || value['version'] is! String) {
      throw const FormatException('Invalid selected core release');
    }
    final hash = value['hash'] as String;
    if (hash.length != 64 || !_hashPattern.hasMatch(hash)) {
      throw const FormatException('Invalid selected core hash');
    }
    return CoreReleaseRef._(
      hash, CoreReleaseVersion.parse(value['version'] as String),
    );
  }

  Map<String, String> toJson() => {'hash': hash, 'version': version.value};
}

final class CoreReleaseState {
  /// null represents the immutable bundled core, never an arbitrary path.
  final CoreReleaseRef? current;
  final CoreReleaseRef? previous;
  final bool hasPrevious;
  final bool pending;

  const CoreReleaseState({
    this.current,
    this.previous,
    this.hasPrevious = false,
    this.pending = false,
  });

  factory CoreReleaseState.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['schema'] != 1 ||
        value['hasPrevious'] is! bool || value['pending'] is! bool) {
      throw const FormatException('Invalid core selection journal');
    }
    return CoreReleaseState(
      current: value['current'] == null ? null : CoreReleaseRef.fromJson(value['current']),
      previous: value['previous'] == null ? null : CoreReleaseRef.fromJson(value['previous']),
      hasPrevious: value['hasPrevious'] as bool,
      pending: value['pending'] as bool,
    );
  }

  Map<String, Object?> toJson() => {
    'schema': 1,
    'current': current?.toJson(),
    'previous': previous?.toJson(),
    'hasPrevious': hasPrevious,
    'pending': pending,
  };
}

final class CoreReleaseActivationException implements Exception {
  final Object cause;
  final bool restored;
  final Object? rollbackError;

  const CoreReleaseActivationException(this.cause, {
    required this.restored, this.rollbackError,
  });

  @override
  String toString() => 'Core activation failed: $cause; '
      'previous core restored: $restored'
      '${rollbackError == null ? '' : '; rollback failed: $rollbackError'}';
}

/// Only the existing restart worker may call the supplied restart callback.
/// The durable file always names the last committed selection during trial;
/// a process crash or power loss cannot commit an untested candidate.
final class CoreReleaseSelectionStore {
  final Future<File> Function() _file;
  bool _trial = false;
  bool _busy = false;
  CoreReleaseRef? _trialSelection;

  CoreReleaseSelectionStore(this._file);

  Future<CoreReleaseState> read() async {
    final file = await _file();
    if (!await file.exists()) return const CoreReleaseState();
    if (await file.length() > 4096) {
      throw const FormatException('Oversized core selection journal');
    }
    return CoreReleaseState.fromJson(jsonDecode(await file.readAsString()));
  }

  Future<CoreReleaseRef?> selectedForLaunch() async {
    if (_trial) return _trialSelection;
    try {
      // A pending entry is an interrupted trial. Its current field still
      // points to the last committed selection, so never retry the candidate.
      return (await read()).current;
    } on FormatException {
      // Corrupt user data must not authorize an arbitrary executable.
      return null;
    }
  }

  Future<void> _write(CoreReleaseState state) async {
    final file = await _file();
    await file.writeAsStringAtomically(jsonEncode(state.toJson()));
  }

  Future<bool> activate(
    CoreReleaseManifest manifest, {
    required String bundledVersion,
    required Future<bool> Function() restart,
  }) => _change(
    target: CoreReleaseRef.fromManifest(manifest),
    bundledVersion: bundledVersion,
    restart: restart,
  );

  Future<bool> restorePrevious({
    required Future<bool> Function() restart,
  }) => _change(restore: true, restart: restart);

  Future<bool> _change({
    CoreReleaseRef? target,
    String? bundledVersion,
    bool restore = false,
    required Future<bool> Function() restart,
  }) async {
    if (_busy) throw StateError('Core release activation already running');
    _busy = true;
    try {
      final state = await read();
      if (restore) {
        if (!state.hasPrevious) throw StateError('No previous core release');
        target = state.previous;
      } else {
        final next = target!;
        final current = state.current;
        final base = bundledVersion!;
        final normalized = base.startsWith('v') ? base : 'v$base';
        final firstIndependent = CoreReleaseVersion.parse('$normalized-z.1');
        if (next.version.compareTo(firstIndependent) < 0 ||
            (current != null && next.version.compareTo(current.version) <= 0)) {
          throw StateError('Core release is not newer than the installed version');
        }
      }

      // Pending retains the last known good selection; old and new EXEs are
      // independent immutable slots, not two partially replaced files.
      await _write(CoreReleaseState(
        current: state.current, previous: state.previous,
        hasPrevious: state.hasPrevious, pending: true,
      ));
      _trialSelection = target;
      _trial = true;
      try {
        if (!await restart()) throw StateError('Core restart did not restore the requested configuration');
        await _write(CoreReleaseState(
          current: target, previous: state.current, hasPrevious: true,
        ));
        return true;
      } catch (error) {
        // Override in memory even if rewriting the journal fails: pending
        // already contains the old committed selection.
        _trialSelection = state.current;
        Object? rollbackError;
        var restored = false;
        try {
          restored = await restart();
          if (!restored) rollbackError = StateError('Previous core did not start');
        } catch (failure) {
          rollbackError = failure;
        }
        try {
          await _write(CoreReleaseState(
            current: state.current, previous: state.previous,
            hasPrevious: state.hasPrevious,
          ));
        } catch (failure) {
          rollbackError ??= failure;
        }
        throw CoreReleaseActivationException(
          error, restored: restored, rollbackError: rollbackError,
        );
      } finally {
        _trial = false;
        _trialSelection = null;
      }
    } finally {
      _busy = false;
    }
  }
}

final coreReleaseSelection = CoreReleaseSelectionStore(
  () async => File(p.join(await appPath.homeDirPath, 'core-release-selection.json')),
);
