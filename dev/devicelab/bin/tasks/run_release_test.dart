// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:flutter_devicelab/framework/adb.dart';
import 'package:flutter_devicelab/framework/framework.dart';
import 'package:flutter_devicelab/framework/utils.dart';

void main() {
  task(() async {
    final Device device = await devices.workingDevice;
    await device.unlock();
    final Directory appDir = dir(path.join(flutterDirectory.path, 'dev/integration_tests/ui'));
    await inDirectory(appDir, () async {
      final Completer<void> ready = Completer<void>();
      print('run: starting...');
      final Process run = await startProcess(
        path.join(flutterDirectory.path, 'bin', 'flutter'),
        <String>['--suppress-analytics', 'run', '--release', '-d', device.deviceId, 'lib/main.dart'],
        isBot: false, // we just want to test the output, not have any debugging info
      );
      final List<String> stdout = <String>[];
      final List<String> stderr = <String>[];
      int runExitCode;
      run.stdout
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) {
          print('run:stdout: $line');
          if (
            !line.startsWith('Building flutter tool...') &&
            !line.startsWith('Running "flutter pub get" in ui...') &&
            !line.startsWith('Initializing gradle...') &&
            !line.contains('settings_aar.gradle') &&
            !line.startsWith('Resolving dependencies...') &&
            // Catch engine piped output from unrelated concurrent Flutter apps
            !line.contains(RegExp(r'[A-Z]\/flutter \([0-9]+\):')) &&
            // Empty lines could be due to the progress spinner breaking up.
            line.length > 1
          ) {
            stdout.add(line);
          }
          if (line.contains('To quit, press "q".')) {
            ready.complete();
          }
        });
      run.stderr
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) {
          print('run:stderr: $line');
          stderr.add(line);
        });
      run.exitCode.then<void>((int exitCode) { runExitCode = exitCode; });
      await Future.any<dynamic>(<Future<dynamic>>[ ready.future, run.exitCode ]);
      if (runExitCode != null) {
        throw 'Failed to run test app; runner unexpected exited, with exit code $runExitCode.';
      }
      run.stdin.write('q');

      await run.exitCode;

      if (stderr.isNotEmpty) {
        throw 'flutter run --release had output on standard error.';
      }

      _findNextMatcherInList(
        stdout,
        (String line) => line.startsWith('Launching lib/main.dart on ') && line.endsWith(' in release mode...'),
        'Launching lib/main.dart on',
      );

      _findNextMatcherInList(
        stdout,
        (String line) => line.startsWith('Running Gradle task \'assembleRelease\'...'),
        'Running Gradle task \'assembleRelease\'...',
      );

      _findNextMatcherInList(
        stdout,
        (String line) => line.contains('Built build/app/outputs/apk/release/app-release.apk (') && line.contains('MB).'),
        'Built build/app/outputs/apk/release/app-release.apk',
      );

      _findNextMatcherInList(
        stdout,
        (String line) => line.startsWith('Installing build/app/outputs/apk/app.apk...'),
        'Installing build/app/outputs/apk/app.apk...',
      );

      _findNextMatcherInList(
        stdout,
        (String line) => line == 'To quit, press "q".',
        'To quit, press "q".',
      );

      _findNextMatcherInList(
        stdout,
        (String line) => line == 'Application finished.',
        'Application finished.',
      );
    });
    return TaskResult.success(null);
  });
}

void _findNextMatcherInList(
  List<String> list,
  bool Function(String testLine) matcher,
  String errorMessageExpectedLine
) {
  final List<String> copyOfListForErrorMessage = List<String>.from(list);

  while (list.isNotEmpty) {
    final String nextLine = list.first;
    list.removeAt(0);

    if (matcher(nextLine)) {
      return;
    }
  }

  throw '''
Did not find expected line

$errorMessageExpectedLine

in flutter run --release stdout

$copyOfListForErrorMessage
  ''';
}
