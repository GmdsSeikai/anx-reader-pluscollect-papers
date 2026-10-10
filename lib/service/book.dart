import 'dart:async';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/theme.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/current_reading_state.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/iap_page.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/providers/chapter_content_bridge.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/providers/iap.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/toc_search.dart';
import 'package:anx_reader/service/convert_to_epub/txt/convert_from_txt.dart';
import 'package:anx_reader/service/db_operation_lock.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/utils/webView/anx_headless_webview.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/utils/import_book.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/utils/webView/gererate_url.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import 'book_player/book_player_server.dart';

AnxHeadlessWebView? headlessInAppWebView;
final allowBookExtensions = ["epub", "mobi", "azw3", "fb2", "txt", "pdf"];

/// import book list and **delete file**
void importBookList(List<File> fileList, BuildContext context, WidgetRef ref) {
  AnxLog.info('importBook fileList: ${fileList.toString()}');

  List<File> supportedFiles = fileList.where((file) {
    return allowBookExtensions
        .contains(file.path.split('.').last.toLowerCase());
  }).toList();

  List<File> unsupportedFiles = fileList.where((file) {
    return !allowBookExtensions
        .contains(file.path.split('.').last.toLowerCase());
  }).toList();

  _checkDuplicatesAndShowDialog(
    supportedFiles,
    unsupportedFiles,
    fileList,
    context,
    ref,
  );
}

void _checkDuplicatesAndShowDialog(
    List<File> supportedFiles,
    List<File> unsupportedFiles,
    List<File> fileList,
    BuildContext context,
    WidgetRef ref) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(L10n.of(context).md5Calculating),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(L10n.of(context).md5Calculating),
        ],
      ),
    ),
  );

  try {
    final filePaths = supportedFiles.map((f) => f.path).toList();
    final checkResults = await MD5Service.checkImportFiles(filePaths);

    if (!context.mounted) return;
    Navigator.of(context).pop();

    List<File> duplicateFiles = [];
    List<File> uniqueFiles = [];
    Map<String, Book> duplicateInfo = {};

    for (int i = 0; i < supportedFiles.length; i++) {
      final file = supportedFiles[i];
      final result = checkResults[i];

      if (result.isDuplicate && result.duplicateBook != null) {
        duplicateFiles.add(file);
        duplicateInfo[file.path] = result.duplicateBook!;
      } else {
        uniqueFiles.add(file);
      }
    }

    _showImportDialog(
      uniqueFiles,
      duplicateFiles,
      duplicateInfo,
      unsupportedFiles,
      fileList,
      ref,
    );
  } catch (e) {
    Navigator.of(navigatorKey.currentContext!).pop();
    AnxLog.severe('MD5 check failed: $e');
    _showImportDialog(
      supportedFiles,
      [],
      {},
      unsupportedFiles,
      fileList,
      ref,
    );
  }
}

void _showImportDialog(
  List<File> uniqueFiles,
  List<File> duplicateFiles,
  Map<String, Book> duplicateInfo,
  List<File> unsupportedFiles,
  List<File> fileList,
  WidgetRef ref,
) {
  // delete unsupported files
  for (var file in unsupportedFiles) {
    file.deleteSync();
  }

  BuildContext context = navigatorKey.currentContext!;

  Widget bookItem(
    String filePath,
    Widget icon, {
    bool isDuplicate = false,
    String? duplicateTitle,
    String? errorMessage,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: icon,
            ),
            Expanded(
              child: Text(
                path.basename(filePath),
                style: TextStyle(
                  fontWeight: FontWeight.w300,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (errorMessage != null)
              IconButton(
                icon: const Icon(Icons.info_outline, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(L10n.of(context).commonError),
                      content: SelectableText(errorMessage),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(L10n.of(context).commonOk),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        if (isDuplicate && duplicateTitle != null)
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text(
              L10n.of(context).duplicateOf(duplicateTitle),
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ),
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text(
              'Error: ${errorMessage.length > 50 ? "${errorMessage.substring(0, 50)}..." : errorMessage}',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.red,
              ),
            ),
          ),
      ],
    );
  }

  final supportedFiles = [...uniqueFiles, ...duplicateFiles];
  bool skipDuplicates = true;

  showDialog(
      context: context,
      builder: (BuildContext context) {
        String currentHandlingFile = '';
        List<String> errorFiles = [];
        bool finished = false;
        Map<String, String> errorMessages = {};

        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: Text(L10n.of(context).importNBooksSelected(fileList.length)),
            contentPadding: const EdgeInsets.all(16),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.of(context)
                      .importSupportTypes(allowBookExtensions.join(' / '))),

                  const SizedBox(height: 10),

                  // show unique files
                  for (var file in uniqueFiles)
                    file.path == currentHandlingFile
                        ? bookItem(
                            file.path,
                            Container(
                              padding: const EdgeInsets.all(3),
                              width: 20,
                              height: 20,
                              child: const CircularProgressIndicator(),
                            ))
                        : bookItem(
                            file.path,
                            errorFiles.contains(file.path)
                                ? const Icon(Icons.error)
                                : const Icon(Icons.done),
                            errorMessage: errorFiles.contains(file.path)
                                ? errorMessages[file.path]
                                : null,
                          ),

                  // show unsupported files
                  if (unsupportedFiles.isNotEmpty) ...[
                    Divider(),
                    SizedBox(height: 10),
                    Text(L10n.of(context)
                        .importNBooksNotSupport(unsupportedFiles.length))
                  ],
                  for (var file in unsupportedFiles)
                    bookItem(file.path, const Icon(Icons.error)),

                  // show duplicate files
                  if (duplicateFiles.isNotEmpty) ...[
                    Divider(),
                    const SizedBox(height: 10),
                    Text(L10n.of(context).duplicateFile),
                  ],
                  for (var file in duplicateFiles)
                    if (skipDuplicates)
                      bookItem(
                        file.path,
                        const Icon(Icons.double_arrow_rounded),
                        isDuplicate: true,
                        duplicateTitle: duplicateInfo[file.path]?.title,
                      )
                    else
                      file.path == currentHandlingFile
                          ? bookItem(
                              file.path,
                              Container(
                                padding: const EdgeInsets.all(3),
                                width: 20,
                                height: 20,
                                child: const CircularProgressIndicator(),
                              ),
                              isDuplicate: true,
                              duplicateTitle: duplicateInfo[file.path]?.title,
                            )
                          : bookItem(
                              file.path,
                              errorFiles.contains(file.path)
                                  ? const Icon(Icons.error)
                                  : const Icon(Icons.done),
                              isDuplicate: true,
                              duplicateTitle: duplicateInfo[file.path]?.title,
                              errorMessage: errorFiles.contains(file.path)
                                  ? errorMessages[file.path]
                                  : null,
                            ),

                  // select skip duplicates
                  if (duplicateFiles.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Checkbox(
                          value: skipDuplicates,
                          onChanged: (value) {
                            setState(() {
                              skipDuplicates = value ?? true;
                            });
                          },
                        ),
                        Expanded(
                          child: Text(L10n.of(context).skipDuplicateFiles),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  for (var file in supportedFiles) {
                    file.deleteSync();
                  }
                },
                child: Text(L10n.of(context).commonCancel),
              ),
              if (uniqueFiles.isNotEmpty ||
                  (duplicateFiles.isNotEmpty && !skipDuplicates))
                TextButton(
                    onPressed: () async {
                      if (finished) {
                        Navigator.of(context).pop('dialog');
                        return;
                      }

                      List<File> filesToImport = [...uniqueFiles];
                      if (!skipDuplicates) {
                        filesToImport.addAll(duplicateFiles);
                      }

                      for (var file in filesToImport) {
                        AnxToast.show(path.basename(file.path));
                        setState(() {
                          currentHandlingFile = file.path;
                        });
                        try {
                          await importBook(file, ref);
                          setState(() {
                            currentHandlingFile = '';
                          });
                        } catch (e, stackTrace) {
                          AnxLog.severe('Failed to import ${file.path}: $e');
                          AnxLog.severe('Stack trace: $stackTrace');
                          setState(() {
                            errorFiles.add(file.path);
                            errorMessages[file.path] = e.toString();
                          });
                        }
                      }

                      // dumplicateFiles will be deleted if skipDuplicates is true
                      // if skipDuplicates is false, they will be imported
                      // and then deleted in the importBook function
                      if (skipDuplicates) {
                        for (var file in duplicateFiles) {
                          file.deleteSync();
                        }
                      }

                      setState(() {
                        finished = true;
                      });
                      ref.read(syncProvider.notifier).syncData(
                          SyncDirection.upload, ref,
                          trigger: SyncTrigger.auto);
                    },
                    child: Text(finished
                        ? L10n.of(context).commonOk
                        : L10n.of(context).importImportNBooks(
                            uniqueFiles.length +
                                (skipDuplicates ? 0 : duplicateFiles.length) -
                                errorFiles.length))),
            ],
          );
        });
      });
}

/// Serial gate shared by every caller that extracts book metadata through
/// the global headless WebView (file import, cover rebuild, paper import).
class _MetadataWebViewQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final Future<void> previous = _tail;
    final Future<T> task = previous.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (_) {});
    return task;
  }
}

final _MetadataWebViewQueue _metadataWebViewQueue = _MetadataWebViewQueue();

/// Monotonic token used to reject metadata callbacks that arrive after a
/// timeout or failure already released the queue slot.
int _metadataRunToken = 0;

/// How many metadata extractions are queued or running. The papers
/// controller uses this to drain imports before releasing shared resources.
int get metadataQueueDepth => _metadataQueueDepth;
int _metadataQueueDepth = 0;

/// How many full import flows (MD5/convert/lock-wait/extract/save) are in
/// flight, counted from entry — including ones still waiting for the
/// operation lock. Shutdown/migration must drain these too.
int get importWorkDepth => _importWorkDepth;
int _importWorkDepth = 0;

/// Import a book file into the bookshelf and return the resulting [Book].
///
/// The whole flow — MD5 duplicate check through database commit — runs
/// inside the main-library operation lock so sync and storage migration
/// cannot interleave with an import commit. Counted as owned work from
/// entry so closing the window cannot release shared resources underneath.
Future<Book> importBook(File file, WidgetRef ref) async {
  DbOperationLock.instance.requireAdmission();
  _importWorkDepth++;
  try {
    final String? md5 = await MD5Service.calculateFileMd5(file.path);

    if (file.path.split('.').last == 'txt') {
      final tempFile = await convertFromTxt(file);
      file.deleteSync();
      file = tempFile;
    }

    final Book book = await DbOperationLock.instance
        .runLocked(DbOperationScope.import, () async {
      final Book saved =
          await getBookMetadata(file, md5: md5, ref: ref, lockHeld: true);
      return saved;
    });
    ref.read(bookListProvider.notifier).refresh();
    return book;
  } finally {
    _importWorkDepth--;
  }
}

Future<void> pushToReadingPage(
  WidgetRef ref,
  BuildContext context,
  Book book, {
  String? cfi,
  String? heroTag,
}) async {
  if (book.isDeleted) {
    AnxToast.show(L10n.of(context).bookDeleted);
    return;
  }

  if (!File(book.fileFullPath).existsSync()) {
    ref.read(syncProvider.notifier).downloadBook(book);
    return;
  }

  if (EnvVar.enableInAppPurchase) {
    final iapAsync = ref.read(iapProvider);
    final isFeatureAvailable = iapAsync.maybeWhen(
      data: (state) => state.isFeatureAvailable,
      orElse: () => ref.read(iapProvider.notifier).cachedFeatureAvailable(),
    );

    if (!isFeatureAvailable) {
      Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (context) => const IAPPage(),
        ),
      );
      return;
    }
  }
  ref.read(aiChatProvider.notifier).clear();
  final initialThemes = await themeDao.selectThemes();
  ref.read(currentReadingProvider.notifier).start(
        CurrentReadingState(
          book: book,
          cfi: cfi,
        ),
      );

  final currentReading = ref.read(currentReadingProvider.notifier);
  final chapterContentBridge = ref.read(chapterContentBridgeProvider.notifier);
  final tocSearch = ref.read(tocSearchProvider.notifier);

  await Navigator.push(
    navigatorKey.currentContext!,
    CupertinoPageRoute(
      builder: (c) => ReadingPage(
        key: readingPageKey,
        book: book,
        cfi: cfi,
        initialThemes: initialThemes,
        heroTag: heroTag,
      ),
    ),
  ).then((_) {
    AnxLog.info('ReadingPage: poped: ${book.title}');
    currentReading.finish();
    chapterContentBridge.state = null;
    tocSearch.clear();
    AnxLog.info('Pop successfully ReadingPage: ${book.title}');
  });
}

void updateBookRating(Book book, double rating) {
  book.rating = rating;
  bookDao.updateBook(book);
}

Future<void> resetBookCover(Book book) async {
  DbOperationLock.instance.requireAdmission();
  File file = File(book.fileFullPath);
  // Cover rebuild is a shared WebView consumer and a main-library write:
  // it runs under the same import lock as file imports and counts as owned
  // work from entry.
  _importWorkDepth++;
  try {
    await DbOperationLock.instance.runLocked(
        DbOperationScope.import,
        () =>
            getBookMetadata(file, book: book, coverOnly: true, lockHeld: true));
  } catch (e) {
    AnxLog.severe('resetBookCover failed: $e');
    rethrow;
  } finally {
    _importWorkDepth--;
  }
}

/// Copy the file into the bookshelf layout and commit it to the main library.
///
/// Returns the committed [Book]. Failures are thrown, never reported as
/// success. When [lockHeld] is false the commit acquires the import scope
/// of [DbOperationLock] itself; callers already inside that scope pass
/// `lockHeld: true` to avoid deadlock.
Future<Book> saveBook(
  File file,
  String title,
  String author,
  String description,
  String? md5,
  String cover, {
  Book? provideBook,
  bool lockHeld = false,
}) {
  Future<Book> action() => _saveBookLocked(
      file, title, author, description, md5, cover, provideBook);
  if (lockHeld) return action();
  return DbOperationLock.instance.runLocked(DbOperationScope.import, action);
}

Future<Book> _saveBookLocked(
  File file,
  String title,
  String author,
  String description,
  String? md5,
  String cover,
  Book? provideBook,
) async {
  // Extract original filename (without extension)
  final fileNameWithoutExt = path.basenameWithoutExtension(file.path);

  // Use original filename if title is invalid
  final effectiveTitle =
      (title == 'Unknown' || title.trim().isEmpty) ? fileNameWithoutExt : title;

  final newBookName =
      '${effectiveTitle.length > 20 ? effectiveTitle.substring(0, 20) : effectiveTitle}-${DateTime.now().millisecondsSinceEpoch}'
          // Strip characters that some WebDAV servers (e.g. Jianguoyun) reject (#989)
          .replaceAll(RegExp(r'[<>:"/\\|?*#%&@$^+=\[\]{}`~;!]'), '_')
          .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
          .trim();

  final extension = file.path.split('.').last;

  final dbFilePath = 'file/$newBookName.$extension';
  final filePath = getBasePath(dbFilePath);
  String? dbCoverPath = 'cover/$newBookName';

  await file.copy(filePath);

  dbCoverPath = await saveImageToLocal(cover, dbCoverPath);
  if (cover.isNotEmpty && !File(getBasePath(dbCoverPath)).existsSync()) {
    throw StateError('Book cover could not be saved');
  }
  if (md5 != null) {
    provideBook ??= await bookDao.getBookByMd5(md5);
  }

  Book book = Book(
      id: provideBook != null ? provideBook.id : -1,
      title: provideBook?.title ?? effectiveTitle,
      coverPath: dbCoverPath,
      filePath: dbFilePath,
      lastReadPosition: provideBook?.lastReadPosition ?? '',
      readingPercentage: provideBook?.readingPercentage ?? 0,
      author: provideBook?.author ?? author,
      description: provideBook?.description ?? description,
      isDeleted: false,
      rating: provideBook?.rating ?? 0.0,
      groupId: provideBook?.groupId ?? 0,
      md5: md5,
      createTime: provideBook?.createTime ?? DateTime.now(),
      updateTime: DateTime.now());

  book.id = await bookDao.insertBook(book);
  // Preserve the source until all assets and the main-library row commit.
  try {
    if (!path.equals(file.path, filePath)) await file.delete();
  } catch (error) {
    AnxLog.warning('Import: committed book retained its source file', error);
  }
  final context = navigatorKey.currentContext;
  if (context != null && context.mounted) {
    AnxToast.show(L10n.of(context).serviceImportSuccess);
  }
  return book;
}

Future<Book> _saveBookCoverLocked(Book original, String cover) async {
  final current = await bookDao.selectBookById(original.id);
  if (current.filePath != original.filePath || current.md5 != original.md5) {
    throw StateError('Book changed before its cover could be rebuilt');
  }
  if (cover.isEmpty) throw StateError('Book metadata has no cover');
  final coverPath = await saveImageToLocal(cover,
      'cover/cover-${current.id}-${DateTime.now().microsecondsSinceEpoch}');
  if (!File(getBasePath(coverPath)).existsSync()) {
    throw StateError('Book cover could not be saved');
  }
  current.coverPath = coverPath;
  await bookDao.updateBook(current);
  return current;
}

/// Extract book metadata through the shared headless WebView and save the
/// book. Completes with the committed [Book] only after the metadata
/// callback finished [saveBook]; the 30s metadata budget only bounds the
/// waiting phase — once saving starts, the queue slot and any lock are
/// held until the real write finishes or fails. Late, duplicate and
/// post-failure callbacks are rejected.
///
/// [lockHeld] must be true when the caller already holds the import scope
/// of [DbOperationLock]; otherwise the save acquires it itself.
Future<Book> getBookMetadata(
  File file, {
  Book? book,
  String? md5,
  WidgetRef? ref,
  bool lockHeld = false,
  bool coverOnly = false,
}) {
  return _metadataWebViewQueue.run(() async {
    _metadataQueueDepth++;
    try {
      return await _getBookMetadataQueued(file,
          book: book,
          md5: md5,
          ref: ref,
          lockHeld: lockHeld,
          coverOnly: coverOnly);
    } finally {
      _metadataQueueDepth--;
    }
  });
}

enum _MetadataPhase { waiting, saving, finished }

Future<Book> _getBookMetadataQueued(
  File file, {
  Book? book,
  String? md5,
  WidgetRef? ref,
  bool lockHeld = false,
  bool coverOnly = false,
}) async {
  final int runToken = ++_metadataRunToken;
  String serverFileName = Server().setTempFile(file);

  String bookUrl = "http://127.0.0.1:${Server().port}/$serverFileName";
  AnxLog.info("import start: book url: $bookUrl");

  final importUrl = generateUrl(bookUrl, '', importing: true);

  final Completer<Book> result = Completer<Book>();
  // Loading can invoke an error callback before run() returns and before the
  // caller awaits result. Observe that error without changing its outcome.
  result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  AnxHeadlessWebView? webview;

  // Ownership state: one callback is accepted atomically; once saving
  // starts, errors/timeouts no longer release the queue — the save owns it.
  var phase = _MetadataPhase.waiting;
  Future<Book>? saving;

  void rejectWaiting(Object error) {
    if (phase == _MetadataPhase.waiting && !result.isCompleted) {
      phase = _MetadataPhase.finished;
      result.completeError(error);
    }
  }

  webview = AnxHeadlessWebView(
    webViewEnvironment: webViewEnvironment,
    initialUrl: importUrl,
    onLoadStop: (controller, url) async {
      controller.addJavaScriptHandler(
          handlerName: 'onMetadata',
          callback: (args) async {
            if (runToken != _metadataRunToken) {
              AnxLog.warning('Import: ignoring stale metadata callback');
              return null;
            }
            if (phase != _MetadataPhase.waiting) {
              // Duplicate or late callback: a save is already owned.
              AnxLog.warning(
                  'Import: ignoring duplicate/late metadata callback');
              return null;
            }
            phase = _MetadataPhase.saving;
            try {
              Map<String, dynamic> metadata =
                  Map<String, dynamic>.from(args[0]);
              String title = metadata['title'] ?? 'Unknown';
              dynamic authorData = metadata['author'];
              String author = authorData is String
                  ? authorData
                  : authorData
                          ?.map((author) =>
                              author is String ? author : author['name'])
                          ?.join(', ') ??
                      'Unknown';

              String cover = metadata['cover'] ?? '';
              String description = metadata['description'] ?? '';
              if (coverOnly && (book == null || !lockHeld)) {
                throw StateError(
                    'Cover rebuild requires an existing book and its lock');
              }
              final Future<Book> saveFuture = coverOnly
                  ? _saveBookCoverLocked(book!, cover)
                  : saveBook(
                      file,
                      title,
                      author,
                      description,
                      md5,
                      cover,
                      provideBook: book,
                      lockHeld: lockHeld,
                    );
              saving = saveFuture;
              final saved = await saveFuture;
              phase = _MetadataPhase.finished;
              if (!result.isCompleted) {
                result.complete(saved);
              }
              ref?.read(bookListProvider.notifier).refresh();
            } catch (e, stackTrace) {
              AnxLog.severe('Import: saveBook failed: $e\n$stackTrace');
              phase = _MetadataPhase.finished;
              if (!result.isCompleted) {
                result.completeError(e);
              }
            }
            return null;
          });
    },
    onConsoleMessage: (controller, message, {required isError}) {
      if (isError) {
        AnxLog.severe('Import: Webview error: $message');
        // Errors only reject the waiting phase; a save in progress keeps
        // ownership until its real outcome.
        rejectWaiting(Exception('Webview: $message'));
        return;
      }
      AnxLog.info('Webview: $message');
    },
    onLoadError: (controller, url, code, message) {
      rejectWaiting(Exception('Webview load error $code: $message'));
    },
    onLoadHttpError: (controller, url, statusCode, description) {
      rejectWaiting(Exception('Webview HTTP error $statusCode: $description'));
    },
  );

  try {
    await webview.run();
    headlessInAppWebView = webview;
  } catch (e) {
    headlessInAppWebView = null;
    await webview.dispose();
    rethrow;
  }

  try {
    // The 30s budget bounds waiting for the metadata callback only.
    return await result.future.timeout(const Duration(seconds: 30));
  } on TimeoutException {
    if (phase == _MetadataPhase.saving && saving != null) {
      // A save already started: wait for the real outcome instead of
      // abandoning a possibly-unfinished write.
      return await saving!;
    }
    rejectWaiting(Exception('Import: Get book metadata timeout'));
    throw Exception('Import: Get book metadata timeout');
  } finally {
    // Release the WebView only after the save finished or this attempt
    // finished failing — never as a success signal. When saving is still
    // running, wait for it before disposing the resource it may use.
    final pending = saving;
    if (phase == _MetadataPhase.saving && pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    if (identical(headlessInAppWebView, webview)) {
      headlessInAppWebView = null;
    }
    await webview.dispose();
  }
}
