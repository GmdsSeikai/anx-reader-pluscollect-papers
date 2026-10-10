import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/service/papers/semantic_scholar_client.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'codex_repair_test.dart' show samplePaper;

class CachePaths extends PathProviderPlatform {
  CachePaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationCachePath() async => path;
}

class DownloadAdapter implements HttpClientAdapter {
  DownloadAdapter(this.reply);
  final ResponseBody Function(RequestOptions) reply;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('paper-download-test');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = CachePaths(root.path);
    PaperDatabase.instance.debugDbPathOverride = p.join(root.path, 'papers.db');
    await PaperDatabase.instance.open();
    await PaperDatabase.instance.txn((txn) async {
      await txn.insert('papers', samplePaper().toDb());
    });
  });
  tearDown(() async {
    await PaperDatabase.instance.close();
    PaperDatabase.instance.debugDbPathOverride = null;
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  test('arXiv cancellation interrupts Retry-After and prevents retry dispatch',
      () async {
    final arrived = Completer<void>();
    final adapter = DownloadAdapter((_) {
      if (!arrived.isCompleted) arrived.complete();
      return ResponseBody.fromBytes([], 429,
          headers: {
            'retry-after': ['3600']
          });
    });
    final client = ArxivClient(dio: Dio()..httpClientAdapter = adapter);
    final request = client.fetchPage(searchQuery: 'cat:cs.CV', start: 0);
    final check = expectLater(request, throwsA(isA<DioException>()));
    await arrived.future;
    client.cancelActiveRequests();
    await check.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(adapter.requests, hasLength(1));
  });

  test(
      'statistics cancellation interrupts Retry-After and prevents retry dispatch',
      () async {
    final arrived = Completer<void>();
    final adapter = DownloadAdapter((_) {
      if (!arrived.isCompleted) arrived.complete();
      return ResponseBody.fromString('{"message":"rate limited"}', 429,
          headers: {
            'retry-after': ['3600'],
            Headers.contentTypeHeader: ['application/json']
          });
    });
    final client =
        SemanticScholarClient(dio: Dio()..httpClientAdapter = adapter);
    final request = client.lookup(['1706.03762']);
    final check = expectLater(request, throwsA(isA<DioException>()));
    await arrived.future;
    client.cancelActiveRequests();
    await check.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(adapter.requests, hasLength(1));
  });

  test('citation HTTP errors are classified before reading a batch array',
      () async {
    final adapter = DownloadAdapter((_) =>
        ResponseBody.fromString('{"message":"unauthorized"}', 401, headers: {
          Headers.contentTypeHeader: ['application/json']
        }));
    final client =
        SemanticScholarClient(dio: Dio()..httpClientAdapter = adapter);
    await expectLater(
        client.lookup(['1706.03762']),
        throwsA(isA<SemanticScholarException>()
            .having((error) => error.retriable, 'retriable', isFalse)
            .having((error) => error.message, 'message', contains('401'))));
    expect(adapter.requests, hasLength(1));
  });

  test('download validates bytes, fixed version, timeouts and cache MD5',
      () async {
    final adapter = DownloadAdapter(
        (_) => ResponseBody.fromBytes('%PDF-1.7\nfixture'.codeUnits, 200));
    final service = PaperImportService(dio: Dio()..httpClientAdapter = adapter);
    final record = (await service.startImport(
        paper: samplePaper(),
        downloadVersion: 1,
        requestId: 'first',
        nowUtc: DateTime.utc(2026)))!;
    final file =
        await service.downloadPdf(paper: samplePaper(), record: record);
    expect(adapter.requests.single.uri.path, '/pdf/2601.12345v1.pdf');
    expect(adapter.requests.single.connectTimeout, const Duration(seconds: 10));
    await service.recordMd5(
        record: record, file: file, nowUtc: DateTime.utc(2026));
    expect((await service.reusableCachedPdf(record))?.path, file.path);
    await file.writeAsString('%PDF-1.7\nchanged');
    expect(await service.reusableCachedPdf(record), isNull);
    expect(await MD5Service.calculateFileMd5(file.path), isNot(record.pdfMd5));
    service.endRequest(record.arxivId, record.requestId);
  });

  test('an HTML response settles failure without retaining a partial file',
      () async {
    final adapter = DownloadAdapter(
        (_) => ResponseBody.fromBytes('<html>error</html>'.codeUnits, 200));
    final service = PaperImportService(dio: Dio()..httpClientAdapter = adapter);
    final record = (await service.startImport(
        paper: samplePaper(),
        downloadVersion: 1,
        requestId: 'html',
        nowUtc: DateTime.utc(2026)))!;
    await expectLater(service.downloadPdf(paper: samplePaper(), record: record),
        throwsA(isA<ImportException>()));
    expect((await PaperImportDao().selectById(record.arxivId))?.status,
        PaperImportStatus.failed);
    expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.part')),
        isEmpty);
    service.endRequest(record.arxivId, record.requestId);
  });

  test('a forbidden redirect is rejected before its target is requested',
      () async {
    final adapter = DownloadAdapter((_) => ResponseBody.fromBytes([], 302,
        headers: {
          'location': ['https://example.invalid/paper.pdf']
        }));
    final service = PaperImportService(dio: Dio()..httpClientAdapter = adapter);
    final record = (await service.startImport(
        paper: samplePaper(),
        downloadVersion: 1,
        requestId: 'redirect',
        nowUtc: DateTime.utc(2026)))!;
    await expectLater(service.downloadPdf(paper: samplePaper(), record: record),
        throwsA(isA<ImportException>()));
    expect(adapter.requests, hasLength(1));
    service.endRequest(record.arxivId, record.requestId);
  });
}
