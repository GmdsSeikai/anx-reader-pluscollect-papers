import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('concurrent path checks keep the accessible custom storage selected',
      () async {
    final root = await Directory.systemTemp.createTemp('anx-path-check');
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    Prefs().customStoragePath = root.path;
    try {
      final paths =
          await Future.wait(List.generate(40, (_) => getAnxDocumentsPath()));
      expect(paths, everyElement(root.path));
      expect(Prefs().customStoragePath, root.path);
      expect(await root.list().toList(), isEmpty);
    } finally {
      Prefs().customStoragePath = null;
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('opening a fresh main library awaits the complete schema 7', () async {
    final root = await Directory.systemTemp.createTemp('anx-fresh-library');
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    expect(Prefs().font.name, 'book');
    Prefs().customStoragePath = root.path;
    await initBasePath();
    try {
      final db = await DBHelper.reopen();
      final books = await db.rawQuery('PRAGMA table_info(tb_books)');
      expect(books.map((row) => row['name']),
          containsAll(['file_md5', 'group_id', 'rating']));
      final notes = await db.rawQuery('PRAGMA table_info(tb_notes)');
      expect(notes.map((row) => row['name']), contains('reader_note'));
      final groups = await db.rawQuery('SELECT id FROM tb_groups WHERE id = 0');
      expect(groups, hasLength(1));
      expect(await db.rawQuery('PRAGMA user_version'), [
        {'user_version': 7}
      ]);
    } finally {
      await DBHelper.close();
      Prefs().customStoragePath = null;
      documentPath = '';
      await root.delete(recursive: true);
    }
  });
}
