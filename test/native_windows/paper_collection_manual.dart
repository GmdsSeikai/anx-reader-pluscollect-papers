// Separate entry for the human-operated Windows acceptance run. Every path
// provider directory and persistent preference belongs to the marked archive.
import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/main.dart' as app;
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'paper_collection_probe.dart'
    show installNativePaperTestPaths, require, finishNativeProcess;

Future<void> main() async {
  final rawRoot = Platform.environment['PAPER_MANUAL_TEST_ROOT'];
  if (!Platform.isWindows || rawRoot == null) {
    stderr.writeln('Requires Windows and PAPER_MANUAL_TEST_ROOT');
    finishNativeProcess(2);
  }
  final root = Directory(rawRoot).absolute;
  final allowed =
      Directory('D:/Develop/Misc Workspace/archive').resolveSymbolicLinksSync();
  require(root.existsSync(), 'Create the isolated directory before launching');
  require(p.isWithin(allowed, root.resolveSymbolicLinksSync()),
      'Manual data must be in the task archive');
  final marker = File(p.join(root.path, 'manual-test-owner.json'));
  if (marker.existsSync()) {
    final owner = jsonDecode(marker.readAsStringSync()) as Map;
    require(
        owner['kind'] == 'anx-paper-manual-test' && owner['root'] == root.path,
        'Manual test ownership mismatch');
  } else {
    require(
        root.listSync().isEmpty, 'Initial manual data directory must be empty');
    marker.writeAsStringSync(
        jsonEncode({'kind': 'anx-paper-manual-test', 'root': root.path}));
  }
  WidgetsFlutterBinding.ensureInitialized();
  installNativePaperTestPaths(root.path);
  for (final name in ['storage', 'cache', 'temp']) {
    await Directory(p.join(root.path, name)).create(recursive: true);
  }
  await app.main();
}
