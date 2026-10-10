import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../native_windows/paper_collection_probe.dart'
    show installNativePaperTestPaths;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native preferences use the redirected Windows store', () async {
    final root = await Directory.systemTemp.createTemp('paper-native-paths');
    try {
      installNativePaperTestPaths(root.path);
      await Prefs().initPrefs();
      expect(Prefs().customStoragePath, isNull);
      await SharedPreferencesStorePlatform.instance.setValue(
          'String', 'flutter.customStoragePath', p.join(root.path, 'storage'));
      final file =
          File(p.join(root.path, 'storage', 'shared_preferences.json'));
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(),
          contains(root.path.replaceAll('\\', '\\\\')));
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
