// Build this separate entry point with flutter build windows --release --target
// test/native_windows/paper_collection_probe.dart. It never mounts a Flutter
// root widget, so the native runner stays hidden while real WebView2 runs.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/service/book.dart' as books;
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/service/db_operation_lock.dart';
import 'package:anx_reader/service/database_sync_manager.dart';
import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:anx_reader/service/sync/webdav_client.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/get_path/storage_migration.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/webView/anx_headless_webview.dart';
import 'package:anx_reader/utils/webView/epub_webview_controller.dart';
import 'package:anx_reader/utils/webView/gererate_url.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class NativePaperTestPaths extends PathProviderWindows {
  NativePaperTestPaths(this.root);
  final String root;
  @override
  Future<String> getApplicationSupportPath() async => p.join(root, 'storage');
  @override
  Future<String> getApplicationDocumentsPath() async => p.join(root, 'storage');
  @override
  Future<String> getApplicationCachePath() async => p.join(root, 'cache');
  @override
  Future<String> getTemporaryPath() async => p.join(root, 'temp');
}

void installNativePaperTestPaths(String root) {
  final paths = NativePaperTestPaths(root);
  PathProviderPlatform.instance = paths;
  SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
    ..pathProvider = paths;
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Never finishNativeProcess(int code) {
  if (!Platform.isWindows) exit(code);
  // Owned probes close their stores explicitly; early guard failures also
  // terminate without waiting for the hidden runner's DLL shutdown locks.
  final kernel = DynamicLibrary.open('kernel32.dll');
  final current =
      kernel.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentProcess');
  final finish = kernel.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)>('TerminateProcess');
  finish(current(), code);
  throw StateError('Native process termination returned unexpectedly');
}

Future<Book> synchronizeIsolatedLibrary(Directory root, Book book) async {
  final local = await DBHelper().database;
  final original =
      (await local.query('tb_books', where: 'id = ?', whereArgs: [book.id]))
          .single;
  final mainPath = local.path;
  await DBHelper.close();
  final remoteFile =
      await File(mainPath).copy(p.join(root.path, 'native-sync.db'));
  final remote = await databaseFactoryFfi.openDatabase(remoteFile.path,
      options: OpenDatabaseOptions(singleInstance: false));
  try {
    await remote.transaction((txn) async {
      await txn.update('tb_books', {'id': 11},
          where: 'id = ?', whereArgs: [book.id]);
      await txn.update('tb_notes', {'book_id': 11},
          where: 'book_id = ?', whereArgs: [book.id]);
      await txn.insert('tb_books', {
        ...original,
        'id': book.id,
        'title': 'ID collision fixture',
        'file_md5': 'different-content',
      });
    });
  } finally {
    await remote.close();
  }
  await DBHelper.reopen();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final paths = <String>[];
  final subscription = server.listen((request) async {
    paths.add('${request.method} ${request.uri.path}');
    File(p.join(root.path, 'sync-http-requests.json'))
        .writeAsStringSync(jsonEncode(paths));
    if (request.method == 'OPTIONS') {
      request.response.headers.set('DAV', '1');
      request.response.headers.set('Allow', 'OPTIONS, GET');
    } else if (request.method == 'GET' &&
        request.uri.path == '/anx/native-sync.db') {
      request.response.contentLength = await remoteFile.length();
      await request.response.addStream(remoteFile.openRead());
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  try {
    final client = WebdavClient(
        url: 'http://127.0.0.1:${server.port}',
        username: 'fixture',
        password: 'fixture');
    final result = await DbOperationLock.instance.runLocked(
        DbOperationScope.sync,
        () => DatabaseSyncManager.safeDownloadDatabase(
            client: client, remoteDbFileName: 'native-sync.db'));
    require(result.isSuccess,
        'Native library synchronization failed: ${result.message}');
    require(paths.contains('GET /anx/native-sync.db'),
        'Sync did not use the production HTTP client');
    final record = (await PaperImportDao().selectById('1706.03762'))!;
    final target = (await PaperImportService().resolveOpenTarget(record))!;
    require(target.id == 11 && target.md5 == book.md5,
        'Library replacement opened the colliding ID');
    require(
        (await bookNoteDao.selectBookNotesByBookId(target.id)).length == 1 &&
            target.lastReadPosition == book.lastReadPosition,
        'Library synchronization lost the bookmark or progress');
    return target;
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}

Future<void> migrateIsolatedLibrary(Directory root) async {
  final source = Directory(documentPath);
  final target = Directory(p.join(root.path, 'storage-migrated'));
  final resolvedRoot = root.resolveSymbolicLinksSync();
  require(
      p.isWithin(resolvedRoot, source.resolveSymbolicLinksSync()) &&
          p.isWithin(resolvedRoot, target.absolute.path),
      'Migration must remain in the owned test root');
  require(!target.existsSync(), 'Migration target already exists');
  final inventory = <String>[];
  for (final entry in source.listSync(recursive: true, followLinks: false)) {
    require(entry is! Link, 'Test migration cannot traverse links');
    if (entry is File) inventory.add(p.relative(entry.path, from: source.path));
  }
  File(p.join(root.path, 'migration-preview.json')).writeAsStringSync(
      jsonEncode(
          {'source': source.path, 'target': target.path, 'files': inventory}));
  DbOperationLock.instance.suspendNewWork();
  try {
    await DbOperationLock.instance.runLocked(DbOperationScope.migration,
        () async {
      DBHelper.inMaintenance = true;
      PaperDatabase.instance.inMaintenance = true;
      try {
        require(
            await migrateStorageStores(
              sourcePath: source.path,
              destinationPath: target.path,
              closeStores: () async {
                await PaperDatabase.instance.close();
                await DBHelper.close();
              },
              publishPath: (path) async {
                Prefs().customStoragePath = path;
                await initBasePath();
              },
              verifyStores: (path) async {
                for (final db in [
                  await DBHelper.reopen(),
                  await PaperDatabase.instance.open()
                ]) {
                  require(p.isWithin(path, db.path),
                      'Reopened store used the old path');
                  require(
                      (await db.rawQuery('PRAGMA quick_check'))
                              .single
                              .values
                              .single ==
                          'ok',
                      'Migrated database integrity check failed');
                }
              },
            ),
            'Isolated native migration failed');
      } finally {
        DBHelper.inMaintenance = false;
        PaperDatabase.instance.inMaintenance = false;
      }
    });
  } finally {
    DbOperationLock.instance.resumeNewWork();
  }
  require(!Directory(p.join(source.path, 'databases')).existsSync(),
      'Old test stores were not cleaned after verification');
}

Future<Map<String, dynamic>> readPdf(Book book) async {
  final loaded = Completer<void>();
  final relocated = Completer<Map<String, dynamic>>();
  EpubWebViewController? controller;
  final view = AnxHeadlessWebView(
    webViewEnvironment: webViewEnvironment,
    initialUrl: generateUrl(
        'http://127.0.0.1:${Server().port}/book/${Uri.encodeComponent(book.fileFullPath)}',
        book.lastReadPosition),
    onWebViewCreated: (created) {
      controller = created;
      created.addJavaScriptHandler(
          handlerName: 'onLoadEnd',
          callback: (_) {
            if (!loaded.isCompleted) loaded.complete();
          });
      created.addJavaScriptHandler(
          handlerName: 'onRelocated',
          callback: (args) {
            final location = Map<String, dynamic>.from(args.first as Map);
            if (!relocated.isCompleted &&
                (location['cfi'] as String? ?? '').isNotEmpty) {
              relocated.complete(location);
            }
            return null;
          });
      for (final name in [
        'onSetToc',
        'renderAnnotations',
        'onClick',
        'onAnnotationClick',
        'onExternalLink',
        'handleBookmark',
        'onImageClick',
        'onPullUp',
        'onPushState',
        'onSearch',
        'onSelectionCleared',
        'onSelectionEnd',
      ]) {
        created.addJavaScriptHandler(handlerName: name, callback: (_) => null);
      }
    },
    onLoadError: (_, __, code, message) {
      if (!loaded.isCompleted) {
        loaded.completeError(StateError('$code $message'));
      }
    },
  );
  try {
    await view.run();
    await loaded.future.timeout(const Duration(seconds: 45));
    final location =
        await relocated.future.timeout(const Duration(seconds: 45));
    final result = await controller!.evaluate('''
      JSON.stringify({
        title: reader.view.book.metadata.title,
        sections: reader.view.book.sections.length,
        cfi: reader.view.lastLocation?.cfi,
        fraction: reader.view.lastLocation?.fraction
      })
    ''');
    final data = Map<String, dynamic>.from(jsonDecode(result as String) as Map);
    data['cfi'] = location['cfi'];
    data['fraction'] = location['percentage'];
    require((data['sections'] as num) > 0, 'PDF has no sections');
    require((data['cfi'] as String? ?? '').isNotEmpty, 'PDF has no real CFI');
    return data;
  } finally {
    await view.dispose();
  }
}

Future<void> main() async {
  final rawRoot = Platform.environment['PAPER_NATIVE_TEST_ROOT'];
  final mode = Platform.environment['PAPER_NATIVE_TEST_MODE'] ?? 'seed';
  if (!Platform.isWindows ||
      rawRoot == null ||
      !['seed', 'resume'].contains(mode)) {
    stderr.writeln(
        'Requires Windows, PAPER_NATIVE_TEST_ROOT and seed/resume mode');
    finishNativeProcess(2);
  }
  final root = Directory(rawRoot).absolute;
  final allowed =
      Directory('D:/Develop/Misc Workspace/archive').resolveSymbolicLinksSync();
  require(root.existsSync(), 'Test root must already exist');
  require(p.isWithin(allowed, root.resolveSymbolicLinksSync()),
      'Root must be in the task archive');
  final marker = File(p.join(root.path, 'native-test-owner.json'));
  if (mode == 'seed') {
    require(
        root.listSync().isEmpty, 'Seed requires an empty isolated directory');
    marker.writeAsStringSync(
        jsonEncode({'kind': 'anx-paper-native-test', 'root': root.path}));
  } else {
    require(marker.existsSync(), 'Resume requires the isolated test marker');
    final owner = jsonDecode(marker.readAsStringSync()) as Map;
    require(
        owner['kind'] == 'anx-paper-native-test' && owner['root'] == root.path,
        'Test ownership mismatch');
  }
  final diagnostic = Platform.environment['PAPER_NATIVE_DIAGNOSTIC_DLL'];
  if (diagnostic != null) {
    require(p.isWithin(allowed, File(diagnostic).resolveSymbolicLinksSync()),
        'Diagnostic library must be task-local');
    DynamicLibrary.open(diagnostic);
  }
  final report = <String, dynamic>{
    'mode': mode,
    'root': root.path,
    'passed': false
  };
  final resultFile = File(p.join(root.path, '$mode-result.json'));
  final deadline = Timer(const Duration(minutes: 4), () {
    report['error'] = 'Native probe deadline exceeded';
    resultFile.writeAsStringSync(jsonEncode(report));
    finishNativeProcess(3);
  });
  var code = 1;
  try {
    WidgetsFlutterBinding.ensureInitialized();
    installNativePaperTestPaths(root.path);
    for (final dir in ['storage', 'cache', 'temp']) {
      await Directory(p.join(root.path, dir)).create();
    }
    await Prefs().initPrefs();
    if (mode == 'seed') {
      Prefs().customStoragePath = p.join(root.path, 'storage');
    }
    await initBasePath();
    require(
        File(p.join(root.path, 'storage', 'shared_preferences.json'))
            .existsSync(),
        'Native preferences did not use the owned root');
    await AnxLog.init();
    report['stage'] = 'main_schema';
    await DBHelper.reopen();
    final mainDb = await DBHelper().database;
    require(
        (await mainDb.rawQuery('PRAGMA user_version')).single['user_version'] ==
            7,
        'Main schema changed');
    final columns = await mainDb.rawQuery('PRAGMA table_info(tb_books)');
    require(columns.any((row) => row['name'] == 'file_md5'),
        'Main schema not fully initialized');
    await PaperDatabase.instance.open();
    await Server().start();
    report['stage'] = 'webview_environment';
    report['webviewVersion'] = await WebViewEnvironment.getAvailableVersion();
    webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
            userDataFolder: p.join(root.path, 'temp', 'webview')));
    final importer = PaperImportService();
    Book book;
    if (mode == 'seed') {
      report['stage'] = 'live_discovery';
      final page = await ArxivClient().fetchPage(
          searchQuery: 'ti:"Attention Is All You Need" AND au:Vaswani',
          start: 0,
          maxResults: 5);
      final entry =
          page.entries.firstWhere((item) => item.arxivId == '1706.03762');
      final now = DateTime.now().toUtc();
      final paper = Paper(
          arxivId: entry.arxivId,
          latestVersion: entry.version,
          title: entry.title,
          authors: entry.authors,
          abstractText: entry.abstractText,
          categories: entry.categories,
          publishedAt: entry.publishedAt,
          updatedAt: entry.updatedAt,
          contentHash: Paper.contentHashOf(
              title: entry.title,
              abstractText: entry.abstractText,
              authors: entry.authors,
              categories: entry.categories),
          firstSeenAt: now,
          lastSeenAt: now,
          absUrl: entry.absUrl,
          pdfUrl: entry.pdfUrl);
      await PaperDatabase.instance
          .txn((txn) => txn.insert('papers', paper.toDb()));
      final record = (await importer.startImport(
          paper: paper,
          downloadVersion: paper.latestVersion,
          requestId: 'native-selected-paper',
          nowUtc: now))!;
      report['stage'] = 'live_download';
      final pdf = await importer.downloadPdf(paper: paper, record: record);
      report['pdfBytes'] = await pdf.length();
      await importer.recordMd5(record: record, file: pdf, nowUtc: now);
      report['stage'] = 'webview_import';
      book = await importer.importDownloadedPdf(
          paper: paper, record: record, pdfFile: pdf);
      require(await importer.resolveOpenTarget(record) != null,
          'Import has no readable association');
      require(File(book.coverFullPath).existsSync(),
          'Native PDF cover was not saved');
      report['stage'] = 'native_pdf_read';
      final location = await readPdf(book);
      report['read'] = location;
      book.lastReadPosition = location['cfi'] as String;
      book.readingPercentage = (location['fraction'] as num?)?.toDouble() ?? 0;
      await bookDao.updateBook(book);
      await bookNoteDao.save(BookNote(
          bookId: book.id,
          content: 'Native PDF bookmark',
          cfi: book.lastReadPosition,
          chapter: 'First page',
          type: 'bookmark',
          color: 'ffff00',
          updateTime: now));
      report['stage'] = 'cover_rebuild';
      final pathBeforeCover = book.filePath;
      await books.resetBookCover(book);
      require((await bookDao.selectBooks()).length == 1,
          'Cover rebuild duplicated the book');
      book = await bookDao.selectBookById(book.id);
      require(
          book.filePath == pathBeforeCover &&
              File(book.fileFullPath).existsSync(),
          'Cover rebuild changed the PDF');
      report['stage'] = 'concurrent_shared_import';
      final ordinarySource = await File(book.fileFullPath)
          .copy(p.join(root.path, 'cache', 'ordinary-import.pdf'));
      await Future.wait<dynamic>([
        books.resetBookCover(book),
        DbOperationLock.instance.runLocked(
            DbOperationScope.import,
            () => books.getBookMetadata(ordinarySource,
                md5: book.md5, lockHeld: true)),
      ]);
      book = await bookDao.selectBookById(book.id);
      require((await bookDao.selectBooks()).length == 1,
          'Shared import and cover rebuild duplicated the book');
      require(
          book.lastReadPosition == location['cfi'] &&
              (await bookNoteDao.selectBookNotesByBookId(book.id)).length == 1,
          'Shared import changed the existing reading state');
      report['stage'] = 'metadata_failure';
      final invalid = File(p.join(root.path, 'cache', 'invalid.pdf'));
      await invalid.writeAsString('This is not a PDF');
      var rejected = false;
      try {
        await books.getBookMetadata(invalid);
      } catch (_) {
        rejected = true;
      }
      require(
          rejected &&
              invalid.existsSync() &&
              (await bookDao.selectBooks()).length == 1,
          'Metadata failure lost its source or committed a book');
      // Leave the second DB step unfinished to exercise recovery in a new OS process.
      record.status = PaperImportStatus.importing;
      record.bookId = null;
      await PaperImportDao().upsert(record);
    } else {
      report['stage'] = 'process_recovery';
      await PaperImportDao().markOpenInterrupted();
      final record = (await PaperImportDao().selectById('1706.03762'))!;
      require(
          await importer.repairMissingAssociation(
              record: record, nowUtc: DateTime.now().toUtc()),
          'New process failed to repair association');
      book = (await importer.resolveOpenTarget(record))!;
      require((await bookNoteDao.selectBookNotesByBookId(book.id)).length == 1,
          'Bookmark was lost across process restart');
      final location = await readPdf(book);
      report['read'] = location;
      require(location['cfi'] == book.lastReadPosition,
          'Native PDF location failed to restore');
      report['stage'] = 'native_sync_fixture';
      book = await synchronizeIsolatedLibrary(root, book);
      report['syncFixture'] = {
        'transport': 'loopback HTTP',
        'bookIdAfter': book.id,
        'bookmarkPreserved': true
      };
      final syncLocation = await readPdf(book);
      require(syncLocation['cfi'] == book.lastReadPosition,
          'Reading location changed after native sync');
      report['stage'] = 'native_storage_migration';
      await migrateIsolatedLibrary(root);
      final recordAfterMigration =
          (await PaperImportDao().selectById('1706.03762'))!;
      book = (await importer.resolveOpenTarget(recordAfterMigration))!;
      require(
          (await bookNoteDao.selectBookNotesByBookId(book.id)).length == 1 &&
              File(book.fileFullPath).existsSync(),
          'Migration lost book assets or bookmarks');
      final migratedLocation = await readPdf(book);
      require(migratedLocation['cfi'] == book.lastReadPosition,
          'Reading location changed after native migration');
      report['migration'] = {
        'path': documentPath,
        'bookId': book.id,
        'bookmarkPreserved': true,
        'read': migratedLocation
      };
    }
    report['bookId'] = book.id;
    report['bookMd5'] = book.md5;
    report['passed'] = true;
    code = 0;
  } catch (error, stack) {
    report['error'] = error.toString();
    report['stack'] = stack.toString();
    resultFile.writeAsStringSync(jsonEncode(report));
  } finally {
    try {
      await Server().stop();
      await books.headlessInAppWebView?.dispose();
      await webViewEnvironment?.dispose();
      await PaperDatabase.instance.close();
      await DBHelper.close();
    } catch (error) {
      report['cleanupError'] = error.toString();
      report['passed'] = false;
      code = 1;
    }
    deadline.cancel();
    resultFile
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    finishNativeProcess(code);
  }
}
