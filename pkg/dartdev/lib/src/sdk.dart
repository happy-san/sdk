// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:path/path.dart' as path;

import 'core.dart';

final Sdk sdk = Sdk();

String get _computeSdkPath {
  // The common case, and how cli_util.dart computes the Dart SDK directory,
  // path.dirname called twice on Platform.resolvedExecutable. We confirm by
  // asserting that the directory ./bin/snapshots/ exists after this directory:
  var sdkPath =
      path.absolute(path.dirname(path.dirname(Platform.resolvedExecutable)));
  var snapshotsDir = path.join(sdkPath, 'bin', 'snapshots');
  if (Directory(snapshotsDir).existsSync()) {
    return sdkPath;
  }

  // This is the less common case where the user is in the checked out Dart SDK,
  // and is executing dart via:
  // ./out/ReleaseX64/dart ...
  // We confirm in a similar manner with the snapshot directory existence and
  // then return the correct sdk path:
  snapshotsDir = path.absolute(path.dirname(Platform.resolvedExecutable),
      'dart-sdk', 'bin', 'snapshots');
  if (Directory(snapshotsDir).existsSync()) {
    return path.absolute(path.dirname(Platform.resolvedExecutable), 'dart-sdk');
  }

  // If neither returned above, we return the common case:
  return sdkPath;
}

/// A utility class for finding and referencing paths within the Dart SDK.
class Sdk {
  final String sdkPath;
  final String version;

  Sdk()
      : sdkPath = _computeSdkPath,
        version = Runtime.runtime.version;

  // Assume that we want to use the same Dart executable that we used to spawn
  // DartDev. We should be able to run programs with out/ReleaseX64/dart even
  // if the SDK isn't completely built.
  String get dart => Platform.resolvedExecutable;

  String get analysisServerSnapshot => path.absolute(
        sdkPath,
        'bin',
        'snapshots',
        'analysis_server.dart.snapshot',
      );

  String get dart2jsSnapshot => path.absolute(
        sdkPath,
        'bin',
        'snapshots',
        'dart2js.dart.snapshot',
      );

  String get ddsSnapshot => path.absolute(
        sdkPath,
        'bin',
        'snapshots',
        'dds.dart.snapshot',
      );

  String get devToolsBinaries => path.absolute(
        sdkPath,
        'bin',
        'resources',
        'devtools',
      );

  static bool checkArtifactExists(String path) {
    if (!File(path).existsSync()) {
      log.stderr('Could not find $path. Have you built the full '
          'Dart SDK?');
      return false;
    }
    return true;
  }
}

/// Return information about the current runtime.
class Runtime {
  static Runtime runtime = Runtime._();

  // Match "2.10.0-edge.0b2da6e7 (be) ...".
  static final RegExp _channelRegex = RegExp(r'.* \(([\d\w]+)\) .*');

  /// The SDK's version number (x.y.z-a.b.channel).
  final String version;

  /// The SDK's release channel (`be`, `dev`, `beta`, `stable`).
  final String channel;

  Runtime._()
      : version = _computeVersion(Platform.version),
        channel = _computeChannel(Platform.version);

  static String _computeVersion(String version) =>
      version.substring(0, version.indexOf(' '));
  static String _computeChannel(String version) =>
      _channelRegex.firstMatch(version)?.group(1);
}
