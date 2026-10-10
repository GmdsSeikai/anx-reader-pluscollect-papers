import 'dart:async';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/service/book.dart' as book_service;
import 'package:anx_reader/service/db_operation_lock.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/utils/get_path/get_cache_dir.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// Outcome of reconciling a paper against the main library before import.
enum ImportReconcileKind {
  /// An active book with this MD5 already exists: just link it.
  alreadyInLibrary,

  /// Only soft-deleted books match: the user can restore one.
  restorable,

  /// Several active books match; the user must choose one.
  multipleActive,

  /// No book matches: proceed with a fresh import.
  notInLibrary,
}

class ImportReconcileResult {
  const ImportReconcileResult(this.kind, {this.matches = const []});
  final ImportReconcileKind kind;
  final List<Book> matches;
}

/// PDF download + bookshelf import for selected papers.
///
/// Downloads go to the application cache under `paper-collection/<requestId>/`
/// and never into the synchronized bookshelf directory. The formal file is
/// placed by the existing book import flow.
class PaperImportService {
  PaperImportService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const Duration connectTimeout = Duration(seconds: 10);

  /// Max gap between received data chunks (idle timeout).
  static const Duration receiveIdleTimeout = Duration(seconds: 30);
  static const Duration totalTimeout = Duration(minutes: 5);
  static const int maxPdfBytes = 100 * 1024 * 1024; // 100 MiB
  static const int maxRedirectHops = 5;

  static const String cacheFolderName = 'paper-collection';
  static const String pdfEndpointBase = 'https://arxiv.org/pdf';

  final Set<CancelToken> _activeTokens = <CancelToken>{};

  /// Live request ownership: arxivId -> requestId token. A record is only
  /// blocked/released by its OWN request; canceling downloads never
  /// releases owners whose bookshelf commit is still running.
  final Map<String, String> _activeOwners = <String, String>{};

  /// Absolute cache directory for one download request.
  Future<Directory> requestCacheDir(String requestId) async {
    final cache = await getAnxCacheDir();
    final dir = Directory(p.join(cache.path, cacheFolderName, requestId));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cancel in-flight downloads (pause/shutdown). Import steps already
  /// inside the bookshelf commit are not hard-cancelled, and ownership
  /// entries stay until their own flow settles — a later request must not
  /// hijack a record whose commit is still running.
  void cancelActiveDownloads() {
    for (final token in _activeTokens.toList()) {
      try {
        token.cancel('cancelled');
      } catch (_) {}
    }
    _activeTokens.clear();
  }

  /// Register a user selection: fix the arXiv version and request id.
  ///
  /// Refuses a second concurrent request for the same paper so duplicate
  /// clicks cannot race two downloads into the same import record. Any
  /// recoverable terminal/stale state keeps its requestId / cache / MD5 so
  /// an interrupted download can resume without fetching again.
  Future<PaperImportRecord?> startImport({
    required Paper paper,
    required int downloadVersion,
    required String requestId,
    required DateTime nowUtc,
  }) async {
    DbOperationLock.instance.requireAdmission();
    if (_activeOwners.containsKey(paper.arxivId)) {
      return null; // a live request owns this paper
    }
    _activeOwners[paper.arxivId] = requestId;
    try {
      final existing = await PaperImportDao().selectById(paper.arxivId);
      if (existing != null && existing.status == PaperImportStatus.imported) {
        if (await resolveOpenTarget(existing) != null) {
          _activeOwners.remove(paper.arxivId);
          return existing;
        }
      }
      if (existing != null) {
        _activeOwners[paper.arxivId] = existing.requestId;
        // Recoverable state (crash, cancel, failure): keep identity fields.
        final keepDownload =
            existing.cacheRelPath != null && existing.pdfMd5 != null;
        existing.status = keepDownload
            ? PaperImportStatus.downloaded
            : PaperImportStatus.queued;
        existing.failureClass = null;
        await PaperImportDao().upsert(existing);
        return existing;
      }
      final record = PaperImportRecord(
        arxivId: paper.arxivId,
        downloadVersion: downloadVersion,
        requestId: requestId,
        status: PaperImportStatus.queued,
        startedAt: nowUtc,
      );
      await PaperImportDao().upsert(record);
      return record;
    } catch (_) {
      _activeOwners.remove(paper.arxivId);
      rethrow;
    }
  }

  /// Settle a non-imported flow as failed/cancelled so the next attempt is
  /// allowed and the state never claims progress that stopped. The cache
  /// identity (requestId / cache path / MD5) is preserved for reuse.
  Future<void> settleFailed({
    required PaperImportRecord record,
    required String failureClass,
  }) async {
    if (record.status == PaperImportStatus.imported) return;
    await _markFailed(record, failureClass);
    endRequest(record.arxivId, record.requestId);
  }

  /// Release the request slot when a flow ends (success or failure). Only
  /// the owning request may release: a stale flow finishing late must not
  /// drop a newer request's ownership.
  void endRequest(String arxivId, String requestId) {
    final owner = _activeOwners[arxivId];
    if (owner == null) return;
    if (owner == requestId) {
      _activeOwners.remove(arxivId);
    }
  }

  Future<File?> reusableCachedPdf(PaperImportRecord record) async {
    final relative = record.cacheRelPath;
    final expectedMd5 = record.pdfMd5;
    if (relative == null || expectedMd5 == null) return null;
    final cache = await getAnxCacheDir();
    final root = p.join(cache.path, cacheFolderName, record.requestId);
    final file = File(p.normalize(p.join(cache.path, relative)));
    if (!p.isWithin(root, file.path) || !file.existsSync()) return null;
    try {
      if (await file.length() > maxPdfBytes) return null;
      verifyPdfBytes(await file.readAsBytes());
      if (await MD5Service.calculateFileMd5(file.path) != expectedMd5) {
        return null;
      }
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _bookFileMatches(Book book, String md5) async =>
      await MD5Service.calculateFileMd5(book.fileFullPath) == md5;

  Future<void> _restoreMissingFile(
      Book book, File? verifiedPdf, String md5) async {
    final target = File(book.fileFullPath);
    if (target.existsSync() || verifiedPdf == null) return;
    verifyPdfBytes(await verifiedPdf.readAsBytes());
    if (await MD5Service.calculateFileMd5(verifiedPdf.path) != md5) {
      throw ImportException('Recovery PDF no longer matches its MD5',
          retriable: false);
    }
    await target.parent.create(recursive: true);
    await verifiedPdf.copy(target.path);
  }

  /// Build the download URL from the fixed arXiv id and version so the
  /// request can never silently follow a newer version.
  Uri buildPdfUrl({
    required String arxivId,
    required int downloadVersion,
  }) {
    final id = ArxivId.tryParse(arxivId);
    if (id == null) {
      throw ImportException('illegal arXiv id: $arxivId', retriable: false);
    }
    // Old-style ids keep their slash inside the arXiv pdf path.
    return Uri.parse('$pdfEndpointBase/${id.value}v$downloadVersion.pdf');
  }

  /// Download the PDF for a queued record into the cache.
  ///
  /// Redirects are followed manually so every hop is validated against the
  /// allowed arXiv host set before it is requested. The response must be a
  /// non-trivial PDF; files over [maxPdfBytes] are refused. The fixed
  /// version is part of the request URL.
  Future<File> downloadPdf({
    required Paper paper,
    required PaperImportRecord record,
  }) async {
    final CancelToken cancelToken = CancelToken();
    _activeTokens.add(cancelToken);

    final Uri startUri;
    try {
      startUri = buildPdfUrl(
        arxivId: paper.arxivId,
        downloadVersion: record.downloadVersion,
      );
    } on ImportException {
      await _markFailed(record, 'illegal_url');
      endRequest(paper.arxivId, record.requestId);
      rethrow;
    }

    record.status = PaperImportStatus.downloading;
    await PaperImportDao().upsert(record);

    final dir = await requestCacheDir(record.requestId);
    final fileName =
        '${ArxivId.tryParse(paper.arxivId)?.fileNameStem ?? paper.arxivId}-'
        'v${record.downloadVersion}.pdf';
    final target = File(p.join(dir.path, fileName));
    final partial = File('${target.path}.part');

    // Total deadline: an owned timer cancels the request after 5 minutes.
    final deadline = Timer(totalTimeout, () {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('total timeout');
      }
    });

    try {
      var uri = startUri;
      for (var hop = 0; hop < maxRedirectHops; hop++) {
        // Validate the target before requesting it: allowed host AND
        // https — a same-host HTTP downgrade is still a downgrade.
        if (uri.scheme.toLowerCase() != 'https' ||
            !ArxivQueryBuilder.allowedPdfHosts
                .contains(uri.host.toLowerCase())) {
          throw ImportException('redirect to disallowed target: $uri',
              retriable: false);
        }

        // Dio 5.x `Options` has no connectTimeout — set it on the
        // per-request `RequestOptions` instead of mutating shared config.
        final response = await _dio.fetch<ResponseBody>(
          RequestOptions(
            path: uri.toString(),
            method: 'GET',
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (code) => code != null && code >= 200 && code < 400,
            connectTimeout: connectTimeout,
            sendTimeout: connectTimeout,
            receiveTimeout: receiveIdleTimeout,
            cancelToken: cancelToken,
          ),
        );

        final status = response.statusCode ?? 0;
        if (status >= 301 && status <= 308) {
          final location = response.headers.value('location');
          if (location == null || location.isEmpty) {
            throw ImportException('redirect without location',
                retriable: false);
          }
          // Drain/cancel the redirect body so the connection is released
          // before hopping.
          try {
            await response.data?.stream.drain<void>();
          } catch (_) {
            // A cancelled/failed drain still ends this hop's ownership.
          }
          uri = uri.resolve(location);
          continue;
        }
        if (status != 200) {
          try {
            await response.data?.stream.drain<void>();
          } catch (_) {}
          throw ImportException('PDF HTTP $status', retriable: false);
        }

        // Stream the body to disk with a hard size cap.
        final sink = partial.openWrite();
        var received = 0;
        try {
          await for (final chunk in response.data!.stream) {
            received += chunk.length;
            if (received > maxPdfBytes) {
              throw ImportException(
                  'PDF exceeds the ${maxPdfBytes ~/ (1024 * 1024)} MiB limit',
                  retriable: false);
            }
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        if (received == 0) {
          throw ImportException('Empty PDF response', retriable: false);
        }
        final bytes = await partial.readAsBytes();
        verifyPdfBytes(bytes);
        if (target.existsSync()) {
          await target.delete();
        }
        await partial.rename(target.path);

        record.status = PaperImportStatus.downloaded;
        record.pdfMd5 = null;
        record.cacheRelPath =
            p.join(cacheFolderName, record.requestId, fileName);
        record.failureClass = null;
        await PaperImportDao().upsert(record);
        return target;
      }
      throw ImportException('too many redirects', retriable: false);
    } on ImportException catch (e) {
      await _markFailed(record, e.retriable ? 'download_failed' : 'rejected');
      rethrow;
    } on DioException catch (e) {
      final cancelled =
          cancelToken.isCancelled || e.type == DioExceptionType.cancel;
      await _markFailed(record, cancelled ? 'cancelled' : 'download_failed');
      throw ImportException(
          cancelled ? 'Download cancelled' : 'Download failed: $e');
    } catch (e) {
      await _markFailed(record, 'download_failed');
      throw ImportException('Download failed: $e');
    } finally {
      deadline.cancel();
      _activeTokens.remove(cancelToken);
      if (partial.existsSync()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _markFailed(
      PaperImportRecord record, String failureClass) async {
    record.status = failureClass == 'cancelled'
        ? PaperImportStatus.cancelled
        : PaperImportStatus.failed;
    record.failureClass = failureClass;
    record.finishedAt = DateTime.now().toUtc();
    await PaperImportDao().upsert(record);
  }

  /// Validate that [bytes] really are a PDF body. Exposed for tests; a
  /// `.pdf` suffix or HTTP 200 is not enough (HTML error pages arrive as
  /// 200 on some mirrors).
  static void verifyPdfBytes(List<int> bytes) {
    if (bytes.length < 8) {
      throw ImportException('File too small to be a PDF', retriable: false);
    }
    final magic = String.fromCharCodes(bytes.take(5));
    if (magic != '%PDF-') {
      throw ImportException('Response is not a PDF (starts with "$magic")',
          retriable: false);
    }
  }

  /// Compute and persist the PDF MD5 for a downloaded file.
  Future<String> recordMd5({
    required PaperImportRecord record,
    required File file,
    required DateTime nowUtc,
  }) async {
    final md5 = await MD5Service.calculateFileMd5(file.path);
    if (md5 == null || md5.isEmpty) {
      throw ImportException('MD5 calculation failed');
    }
    record.pdfMd5 = md5;
    record.status = PaperImportStatus.downloaded;
    await PaperImportDao().upsert(record);
    return md5;
  }

  /// Check the main library for an existing book with this MD5 before
  /// importing. MD5 is not unique in the main library: prefer a still-valid
  /// prior association, then active books, and surface multiple active
  /// matches to the caller instead of binding arbitrarily.
  Future<ImportReconcileResult> reconcileWithMainLibrary({
    required PaperImportRecord record,
  }) async {
    final md5 = record.pdfMd5;
    if (md5 == null || md5.isEmpty) {
      throw ImportException('reconcile requires a downloaded PDF');
    }

    // 1. A previously recorded association still pointing at a live book.
    if (record.bookId != null) {
      try {
        final book = await bookDao.selectBookById(record.bookId!);
        if (book.md5 == md5 &&
            !book.isDeleted &&
            await _bookFileMatches(book, md5)) {
          return ImportReconcileResult(ImportReconcileKind.alreadyInLibrary,
              matches: [book]);
        }
      } catch (_) {
        // The recorded id no longer exists; fall through to MD5 lookup.
      }
    }

    final all = await bookDao.selectBooksByMd5(md5);
    final active = all.where((b) => !b.isDeleted).toList(growable: false);
    final deleted = all.where((b) => b.isDeleted).toList(growable: false);

    if (active.length == 1) {
      return ImportReconcileResult(ImportReconcileKind.alreadyInLibrary,
          matches: active);
    }
    if (active.length > 1) {
      return ImportReconcileResult(ImportReconcileKind.multipleActive,
          matches: active);
    }
    if (deleted.isNotEmpty) {
      return ImportReconcileResult(ImportReconcileKind.restorable,
          matches: deleted);
    }
    return const ImportReconcileResult(ImportReconcileKind.notInLibrary);
  }

  /// Link an already-imported book to the paper record (two-step commit
  /// step 3, or the user-choice path). Runs under the import lock and
  /// re-verifies the chosen book still matches the PDF MD5 — a sync that
  /// replaced the main library while a dialog was open must not bind the
  /// wrong book.
  Future<void> linkBook({
    required PaperImportRecord record,
    required Book book,
    required DateTime nowUtc,
    File? verifiedPdf,
  }) async {
    await DbOperationLock.instance.runLocked(DbOperationScope.import, () async {
      final md5 = record.pdfMd5;
      var verified = book;
      try {
        final current = await bookDao.selectBookById(book.id);
        if (md5 != null && current.md5 != md5) {
          throw ImportException('selected book no longer matches the PDF MD5',
              retriable: false);
        }
        verified = current;
        if (md5 != null) await _restoreMissingFile(current, verifiedPdf, md5);
        if (current.isDeleted ||
            md5 == null ||
            !await _bookFileMatches(current, md5)) {
          throw ImportException('Selected book file is missing or changed',
              retriable: false);
        }
      } catch (e) {
        if (e is! ImportException) {
          throw ImportException('selected book disappeared before linking',
              retriable: false);
        }
        rethrow;
      }
      record.status = PaperImportStatus.imported;
      record.bookId = verified.id;
      record.bookFilePath = verified.filePath;
      record.finishedAt = nowUtc;
      record.failureClass = null;
      await PaperImportDao().upsert(record);
    });
    endRequest(record.arxivId, record.requestId);
  }

  /// Restore a soft-deleted book the user picked (explicit action; never
  /// auto-revives and never replaces an existing file). Re-verifies under
  /// the import lock that the book is still the soft-deleted MD5 match.
  Future<void> restoreBook(Book book,
      {String? expectedMd5, File? verifiedPdf}) async {
    await DbOperationLock.instance.runLocked(DbOperationScope.import, () async {
      final current = await bookDao.selectBookById(book.id);
      if (!current.isDeleted) {
        throw ImportException('book was already restored', retriable: false);
      }
      if (expectedMd5 != null && current.md5 != expectedMd5) {
        throw ImportException('restored book no longer matches the PDF MD5',
            retriable: false);
      }
      if (expectedMd5 != null) {
        await _restoreMissingFile(current, verifiedPdf, expectedMd5);
      }
      if (expectedMd5 == null ||
          !await _bookFileMatches(current, expectedMd5)) {
        throw ImportException('Restore requires an intact matching book file',
            retriable: false);
      }
      final restored =
          current.copyWith(isDeleted: false, updateTime: DateTime.now());
      await bookDao.updateBook(restored);
    });
  }

  /// Import the downloaded PDF into the bookshelf and finish the two-step
  /// commit across both databases.
  ///
  /// Order is fixed: (1) persist `importing` + MD5 in the paper library,
  /// (2) under the library lock re-reconcile and commit the book to the
  /// main library, (3) persist `imported`, `book_id` and the file snapshot
  /// in the paper library. A crash between (2) and (3) is repaired later by
  /// MD5 — never by re-downloading or overwriting the existing file.
  Future<Book> importDownloadedPdf({
    required Paper paper,
    required PaperImportRecord record,
    required File pdfFile,
  }) async {
    final nowUtc = DateTime.now().toUtc();
    record.status = PaperImportStatus.importing;
    record.pdfMd5 ??= await MD5Service.calculateFileMd5(pdfFile.path);
    await PaperImportDao().upsert(record); // step 1

    final Book book = await DbOperationLock.instance.runLocked(
      DbOperationScope.import,
      () async {
        // Re-check under the lock: a concurrent import or sync may have
        // landed a matching book while we waited.
        final reconcile = await reconcileWithMainLibrary(record: record);
        switch (reconcile.kind) {
          case ImportReconcileKind.alreadyInLibrary:
            return reconcile.matches.first;
          case ImportReconcileKind.multipleActive:
          case ImportReconcileKind.restorable:
            throw ImportException(
                'book requires user choice (${reconcile.kind.name})',
                retriable: false);
          case ImportReconcileKind.notInLibrary:
            break;
        }
        return book_service.getBookMetadata(
          pdfFile,
          md5: record.pdfMd5,
          lockHeld: true,
        );
      },
    ); // step 2

    await linkBook(
        record: record,
        book: book,
        nowUtc: nowUtc,
        verifiedPdf: pdfFile); // step 3
    AnxLog.info(
        'PaperImport: ${paper.arxivId} imported as book ${book.id} (md5 ${record.pdfMd5})');
    return book;
  }

  /// Repair a paper-import whose step 2 committed but step 3 did not:
  /// find the book by MD5 and complete the association without touching
  /// the file.
  Future<bool> repairMissingAssociation({
    required PaperImportRecord record,
    required DateTime nowUtc,
  }) async {
    final md5 = record.pdfMd5;
    if (md5 == null) return false;
    final all = await bookDao.selectBooksByMd5(md5);
    final active = all.where((b) => !b.isDeleted).toList(growable: false);
    if (active.length == 1 && await _bookFileMatches(active.first, md5)) {
      await linkBook(record: record, book: active.first, nowUtc: nowUtc);
      return true;
    }
    return false;
  }

  /// Resolve the book to open for a paper. Verifies both the stored book id
  /// and the MD5 so a main-library sync that reassigned ids can never open
  /// the wrong book. Returns null when the paper is no longer on the shelf.
  Future<Book?> resolveOpenTarget(PaperImportRecord record) async {
    final md5 = record.pdfMd5;
    if (record.bookId != null) {
      try {
        final book = await bookDao.selectBookById(record.bookId!);
        if (md5 != null &&
            book.md5 == md5 &&
            !book.isDeleted &&
            await _bookFileMatches(book, md5)) {
          return book;
        }
      } catch (_) {
        // id vanished after a sync replaced the main library
      }
    }
    if (md5 != null) {
      final all = await bookDao.selectBooksByMd5(md5);
      final active = all.where((b) => !b.isDeleted).toList(growable: false);
      if (active.length == 1 && await _bookFileMatches(active.first, md5)) {
        // Rebind the association after an id change.
        record.bookId = active.first.id;
        record.bookFilePath = active.first.filePath;
        await PaperImportDao().upsert(record);
        return active.first;
      }
    }
    return null;
  }

  /// Drop cache files for downloads that are not in the bookshelf. Imported
  /// records keep their request directory so recovery can verify files;
  /// the paper database and quota records are never touched.
  Future<void> clearUnimportedCache() async {
    try {
      final cache = await getAnxCacheDir();
      final root = Directory(p.join(cache.path, cacheFolderName));
      if (!root.existsSync()) return;
      final records = await PaperImportDao().selectAll();
      final keepRequestIds = records
          .where((r) =>
              r.status == PaperImportStatus.imported ||
              r.status == PaperImportStatus.importing ||
              r.status == PaperImportStatus.downloading)
          .map((r) => r.requestId)
          .toSet();
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final requestId = p.basename(entity.path);
        if (keepRequestIds.contains(requestId)) continue;
        await entity.delete(recursive: true);
      }
    } catch (e) {
      AnxLog.warning('PaperImport: cache cleanup failed: $e');
    }
  }
}

class ImportException implements Exception {
  ImportException(this.message, {this.retriable = true});
  final String message;
  final bool retriable;

  @override
  String toString() => 'ImportException: $message';
}
