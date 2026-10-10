import 'dart:async';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:anx_reader/service/ai/ai_rpm_limiter.dart';
import 'package:anx_reader/service/ai/langchain_runner.dart';
import 'package:anx_reader/utils/get_path/storage_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordingRunner extends CancelableLangchainRunner {
  int dispatches = 0;
  StreamController<String>? source;
  @override
  Stream<String> stream(
      {required BaseChatModel model, required PromptValue prompt}) {
    dispatches++;
    return source?.stream ??
        Stream.value(
            '{"schema_version":1,"title_zh":"检测","abstract_zh":"摘要","assessments":[]}');
  }
}

const fakeProvider = AiProvider(
    id: 'test',
    title: 'test',
    url: 'https://invalid.example/v1',
    protocol: AiProtocol.openai,
    model: 'test-model',
    apiKeys: [AiApiKey(id: 'test', key: 'fixture-key')]);

Paper samplePaper() => Paper(
      arxivId: '2601.12345',
      latestVersion: 1,
      title: 'Detection',
      authors: const [],
      abstractText: 'Object detection with distillation.',
      categories: const ['cs.CV'],
      contentHash: 'body',
      publishedAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      firstSeenAt: DateTime.utc(2026),
      lastSeenAt: DateTime.utc(2026),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('production analysis dispatch', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs().initPrefs();
      Prefs().aiRpm = 0;
      AiRpmLimiter.instance.debugReset();
    });

    test('translation-only reaches the runner and validates the result',
        () async {
      final runner = RecordingRunner();
      var sends = 0;
      final payload = await AnalysisService(runner: runner).analyze(
          paper: samplePaper(),
          tasks: const [],
          provider: fakeProvider,
          onRequestSent: () => sends++);
      expect(sends, 1);
      expect(runner.dispatches, 1);
      expect(payload.titleZh, '检测');
      expect(payload.assessments, isEmpty);
    });

    test('cancel during RPM wait never dispatches', () async {
      Prefs().aiRpm = 1;
      await AiRpmLimiter.instance.reserve();
      final runner = RecordingRunner();
      final service = AnalysisService(runner: runner);
      var sends = 0;
      final request = service.analyze(
          paper: samplePaper(),
          tasks: const [],
          provider: fakeProvider,
          onRequestSent: () => sends++);
      final check =
          expectLater(request, throwsA(isA<AnalysisCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      service.cancel();
      await check.timeout(const Duration(seconds: 1));
      expect(sends, 0);
      expect(runner.dispatches, 0);
      expect(AiRpmLimiter.instance.debugWindowCount, 1);
    });

    test('service cancellation settles an already dispatched stream', () async {
      final runner = RecordingRunner();
      var cleanups = 0;
      runner.source = StreamController<String>(onCancel: () {
        cleanups++;
      });
      final service = AnalysisService(runner: runner);
      final sent = Completer<void>();
      final request = service.analyze(
          paper: samplePaper(),
          tasks: const [],
          provider: fakeProvider,
          onRequestSent: sent.complete);
      final check =
          expectLater(request, throwsA(isA<AnalysisCancelledException>()));
      await sent.future;
      service.cancel();
      await check.timeout(const Duration(seconds: 1));
      expect(runner.dispatches, 1);
      expect(cleanups, 1);
      await runner.source!.close();
    });
  });
  test('mid-stream cancellation settles and cancels its subscription',
      () async {
    final cancelled = Completer<void>();
    var cleanups = 0;
    final source = StreamController<String>(onCancel: () {
      cleanups++;
    });
    final future = collectAnalysisStream(source.stream,
        cancelled: cancelled.future, total: const Duration(minutes: 5));
    final check =
        expectLater(future, throwsA(isA<AnalysisCancelledException>()));
    source.add('partial');
    await Future<void>.delayed(Duration.zero);
    cancelled.complete();
    await check.timeout(const Duration(seconds: 1));
    expect(cleanups, 1);
    await source.close();
  });

  test('stream timeout releases the subscription', () async {
    final cancellation = Completer<void>();
    var cleanups = 0;
    final source = StreamController<String>(onCancel: () {
      cleanups++;
    });
    await expectLater(
        collectAnalysisStream(source.stream,
            cancelled: cancellation.future,
            total: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()));
    expect(cleanups, 1);
    cancellation.complete();
    await source.close();
  });

  test('input budget includes system text and splits full profile messages',
      () {
    final paper = samplePaper();
    final first = AnalysisTaskInput(
        taskId: 'one',
        profileHash: 'one',
        config: PaperTaskConfig(researchTopic: 'a' * 800));
    final second = AnalysisTaskInput(
        taskId: 'two',
        profileHash: 'two',
        config: PaperTaskConfig(researchTopic: 'b' * 800));
    final oneSize =
        buildAnalysisMessages(paper: paper, tasks: [first]).inputChars;
    expect(oneSize,
        greaterThan(paper.title.length + paper.abstractText.length + 800));
    final chunks = splitAnalysisTasks(
        paper: paper, tasks: [first, second], maxInputChars: oneSize + 10);
    expect(chunks, hasLength(2));
    for (final chunk in chunks) {
      expect(buildAnalysisMessages(paper: paper, tasks: chunk).inputChars,
          lessThanOrEqualTo(oneSize + 10));
    }
    expect(analysisRequestIdentity(paper, [first], 'model'),
        isNot(analysisRequestIdentity(paper, [second], 'model')));
  });

  test('copy verification preserves the source and rejects tampering',
      () async {
    final root = await Directory.systemTemp.createTemp('paper-storage-test');
    try {
      final source = Directory(p.join(root.path, 'source'));
      final target = Directory(p.join(root.path, 'target'));
      final original =
          File(p.join(source.path, 'databases', 'paper_collection.db'));
      await original.parent.create(recursive: true);
      await original.writeAsString('closed-database-content');
      expect(
          await performStorageMigration(
              sourcePath: source.path, destinationPath: target.path),
          isTrue);
      await verifyStorageCopy(source.path, target.path);
      expect(original.existsSync(), isTrue);
      await File(p.join(target.path, 'databases', 'paper_collection.db'))
          .writeAsString('tampered');
      await expectLater(
          verifyStorageCopy(source.path, target.path), throwsStateError);
      expect(await original.readAsString(), 'closed-database-content');
      expect(
          () => validateStoragePaths(source.path, p.join(source.path, 'child')),
          throwsArgumentError);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('target reopen failure closes target before restoring source', () async {
    final root = await Directory.systemTemp.createTemp('paper-rollback-test');
    try {
      final source = p.join(root.path, 'source');
      final target = p.join(root.path, 'target');
      final original = File(p.join(source, 'databases', 'app_database.db'));
      await original.parent.create(recursive: true);
      await original.writeAsString('original-content');
      final events = <String>[];
      var activePath = source;
      var openPath = source;
      final success = await migrateStorageStores(
          sourcePath: source,
          destinationPath: target,
          closeStores: () async {
            events.add('close:$openPath');
            openPath = '';
          },
          publishPath: (path) async {
            expect(openPath, isEmpty,
                reason: 'no handle may survive a path switch');
            activePath = path;
            events.add('publish:$path');
          },
          verifyStores: (path) async {
            openPath = path;
            if (path == target) {
              throw StateError('paper store failed to reopen');
            }
            expect(await original.readAsString(), 'original-content');
          });
      expect(success, isFalse);
      expect(activePath, source);
      expect(openPath, source);
      expect(events, [
        'close:$source',
        'publish:$target',
        'close:$target',
        'publish:$source'
      ]);
      expect(original.existsSync(), isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
