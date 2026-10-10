import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/service/book.dart' as book_service;
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'codex_repair_test.dart' show samplePaper;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Book book;
  late File cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('paper-library-test');
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    Prefs().customStoragePath = root.path;
    await initBasePath();
    final databases = Directory(p.join(root.path, 'databases'));
    await databases.create();
    sqfliteFfiInit();
    // An existing schema-7 library avoids exercising historical upgrade side effects.
    final fixture = await databaseFactoryFfi.openDatabase(
        p.join(databases.path, 'app_database.db'),
        options: OpenDatabaseOptions(
            version: 7,
            onCreate: (db, _) async {
              await db.execute(createBookSQL);
              await db.execute('ALTER TABLE tb_books ADD COLUMN rating REAL');
              await db
                  .execute('ALTER TABLE tb_books ADD COLUMN group_id INTEGER');
              await db.execute('ALTER TABLE tb_books ADD COLUMN file_md5 TEXT');
              await db.execute(createNoteSQL);
              await db
                  .execute('ALTER TABLE tb_notes ADD COLUMN reader_note TEXT');
            }));
    await fixture.close();
    await DBHelper.reopen();
    PaperDatabase.instance.debugDbPathOverride =
        p.join(databases.path, paperDbFileName);
    await PaperDatabase.instance.open();
    await PaperDatabase.instance.txn((txn) async {
      await txn.insert('papers', samplePaper().toDb());
    });
    cache = File(p.join(root.path, 'cached.pdf'));
    await cache.writeAsString('%PDF-1.7\nfixture');
    final md5 = (await MD5Service.calculateFileMd5(cache.path))!;
    book = Book(
        id: -1,
        title: 'Existing',
        coverPath: 'cover/a.png',
        filePath: 'file/a.pdf',
        lastReadPosition: 'annotation-cfi',
        readingPercentage: 0.61,
        author: 'Author',
        isDeleted: false,
        rating: 4,
        md5: md5,
        createTime: DateTime.utc(2026),
        updateTime: DateTime.utc(2026));
    book.id = await bookDao.insertBook(book);
    await cache.copy(book.fileFullPath);
    await (await DBHelper().database).insert('tb_notes', {
      'book_id': book.id,
      'content': 'existing annotation',
      'cfi': 'annotation-cfi',
    });
  });
  tearDown(() async {
    await PaperDatabase.instance.close();
    PaperDatabase.instance.debugDbPathOverride = null;
    await DBHelper.close();
    documentPath = '';
    Prefs().customStoragePath = null;
    await root.delete(recursive: true);
  });

  test(
      'restart repairs the paper association while preserving notes and progress',
      () async {
    final service = PaperImportService();
    final record = (await service.startImport(
        paper: samplePaper(),
        downloadVersion: 1,
        requestId: 'interrupted',
        nowUtc: DateTime.utc(2026)))!;
    record.status = PaperImportStatus.importing;
    record.pdfMd5 = book.md5;
    await PaperImportDao().upsert(record);
    expect(
        await PaperImportService().repairMissingAssociation(
            record: record, nowUtc: DateTime.utc(2026)),
        isTrue);
    expect(record.bookId, book.id);
    final preserved = await bookDao.selectBookById(book.id);
    expect(preserved.lastReadPosition, 'annotation-cfi');
    expect(preserved.readingPercentage, 0.61);
    expect(
        (await (await DBHelper().database).query('tb_notes')).single['content'],
        'existing annotation');
  });

  test(
      'missing book file is recovered from the selected PDF without replacing book state',
      () async {
    final service = PaperImportService();
    final record = (await service.startImport(
        paper: samplePaper(),
        downloadVersion: 1,
        requestId: 'missing',
        nowUtc: DateTime.utc(2026)))!;
    record.pdfMd5 = book.md5;
    await File(book.fileFullPath).delete();
    expect(
        await service.repairMissingAssociation(
            record: record, nowUtc: DateTime.utc(2026)),
        isFalse);
    await service.linkBook(
        record: record,
        book: book,
        nowUtc: DateTime.utc(2026),
        verifiedPdf: cache);
    expect(await MD5Service.calculateFileMd5(book.fileFullPath), book.md5);
    expect((await bookDao.selectBookById(book.id)).readingPercentage, 0.61);
  });

  test('an id reassigned to another MD5 never opens the wrong book', () async {
    final service = PaperImportService();
    final record = (await service.startImport(
        paper: samplePaper(),
        downloadVersion: 1,
        requestId: 'reassigned',
        nowUtc: DateTime.utc(2026)))!;
    final wrong = book.copyWith(md5: 'different', id: -1);
    wrong.id = await bookDao.insertBook(wrong);
    record.pdfMd5 = book.md5;
    record.bookId = wrong.id;
    expect((await service.resolveOpenTarget(record))?.id, book.id);
    expect(record.bookId, book.id);
  });

  test('a failed cover save preserves the import source and main rows',
      () async {
    await expectLater(
        book_service.saveBook(cache, 'New paper', 'Author', 'Description', null,
            'data:image/png;base64,!!!'),
        throwsStateError);
    expect(cache.existsSync(), isTrue);
    expect((await bookDao.selectBooks()).length, 1);
  });

  test('duplicate import preserves group, description, notes and progress',
      () async {
    book.groupId = 42;
    book.description = 'User description';
    await bookDao.updateBook(book);
    final imported = await book_service.saveBook(
        cache, 'New title', 'New author', 'New description', book.md5, '');
    expect(imported.id, book.id);
    expect(imported.groupId, 42);
    expect(imported.description, 'User description');
    expect(imported.lastReadPosition, 'annotation-cfi');
    expect(imported.readingPercentage, 0.61);
    expect((await bookDao.selectBooks()).length, 1);
    expect(await (await DBHelper().database).query('tb_notes'), hasLength(1));
  });
}
