import 'dart:io';
import 'dart:convert';

import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/service/papers/collection_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixture-driven fake: serves pages from an in-memory corpus and can fail
/// a chosen page once (P03: second-page failure then recovery).
class FakeArxivClient extends ArxivClient {
  FakeArxivClient({required this.corpus});

  final List<ArxivEntry> corpus;
  int failOnStart = -1;
  int requests = 0;

  @override
  Future<ArxivPage> fetchPage({
    required String searchQuery,
    required int start,
    int maxResults = ArxivClient.defaultPageSize,
  }) async {
    requests++;
    if (start == failOnStart) {
      failOnStart = -1;
      throw ArxivException('fixture failure', retriable: true);
    }
    final end = (start + maxResults).clamp(0, corpus.length).toInt();
    final pageEntries = corpus.sublist(start, end);
    return ArxivPage(
      entries: pageEntries,
      totalResults: corpus.length,
      startIndex: start,
      itemsPerPage: maxResults,
    );
  }
}

ArxivEntry entryOf(int i) {
  final published = DateTime.utc(2026, 1, 1).add(Duration(hours: i));
  return ArxivEntry(
    rawId: '2601.0000${i}v1',
    arxivId: '2601.0000$i',
    version: 1,
    title: 'Paper $i',
    authors: const [PaperAuthor(name: 'Alice')],
    abstractText: 'object detection for paper $i',
    categories: const ['cs.CV'],
    publishedAt: published,
    updatedAt: published,
    pdfUrl: 'https://arxiv.org/pdf/2601.0000$i',
  );
}

void main() {
  late Directory tempDir;
  late PaperTask task;
  late PaperRun run;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('paper_scan_test');
    PaperDatabase.instance.debugDbPathOverride =
        '${tempDir.path}${Platform.pathSeparator}paper_collection.db';
    await PaperDatabase.instance.open();

    final now = DateTime.utc(2026, 2, 1);
    task = PaperTask(
      taskId: 'task-1',
      name: 'vision',
      enabled: true,
      priority: 3,
      config: const PaperTaskConfig(
        keywordGroups: [
          PaperKeywordGroup(synonyms: ['object detection']),
        ],
      ),
      queryRevision: 1,
      createTime: now,
      modifyTime: now,
    );
    await PaperTaskDao().upsert(task);
    run = PaperRun(
      runId: 'run-1',
      taskId: 'task-1',
      queryRevision: 1,
      trigger: PaperRunTrigger.manual,
      configSnapshotJson: '{}',
      rangeJson: '{}',
      status: PaperRunStatus.running,
      startedAt: now,
    );
    await PaperRunDao().upsert(run);
  });

  test('narrowed windows exclude old pending slices but preserve coverage',
      () async {
    final now = DateTime.utc(2026, 2, 1);
    final service = CollectionService(
        client: FakeArxivClient(corpus: []), nowUtc: () => now);
    for (final channel in PaperChannel.values) {
      final wide = await service.ensureSlices(
        task: task,
        channel: channel,
        fromUtc: DateTime.utc(2025, 2, 1),
        toUtc: now,
      );
      final from = now.subtract(const Duration(days: 5));
      final narrow = await service.ensureSlices(
        task: task,
        channel: channel,
        fromUtc: from,
        toUtc: now,
      );
      expect(narrow, isNotEmpty);
      expect(narrow.length, lessThan(wide.length));
      expect(narrow.every((s) => s.toUtc.isAfter(from)), isTrue);
      expect(narrow.every((s) => s.fromUtc.isBefore(now)), isTrue);
      final expanded = await service.ensureSlices(
        task: task,
        channel: channel,
        fromUtc: DateTime.utc(2025, 2, 1),
        toUtc: now,
      );
      expect(expanded.map((s) => s.sliceId).toSet(),
          wide.map((s) => s.sliceId).toSet());
    }
  });

  tearDown(() async {
    await PaperDatabase.instance.close();
    PaperDatabase.instance.debugDbPathOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  PaperScanSlice newSlice() => PaperScanSlice(
        sliceId: 0,
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
        requestQuery:
            'submittedDate:[202601010000 TO 202601022359] AND (ti:"object detection")',
        status: PaperSliceStatus.pending,
      );

  TaskBranch branch() => const TaskBranch(
      name: 'topic', searchQuery: 'ti:"object detection"', isAuthor: false);

  test('hot recheck continues across restarts without waiting seven days',
      () async {
    final now = DateTime.utc(2026, 11, 1);
    final windows = computeWindows(config: task.config, now: now);
    final specs = planSlices(
        channel: PaperChannel.hot,
        fromUtc: windows.hotFrom,
        toUtc: windows.hotTo,
        branchHash: 'topic');
    for (final spec in specs) {
      await PaperSliceDao().ensure(PaperScanSlice(
          sliceId: 0,
          taskId: task.taskId,
          revision: 1,
          channel: PaperChannel.hot,
          branchHash: 'topic',
          fromUtc: spec.fromUtc,
          toUtc: spec.toUtc,
          requestQuery: 'fixture',
          status: PaperSliceStatus.completed,
          lastCheckedAt: now));
    }
    final client = FakeArxivClient(corpus: const []);
    Future<List<dynamic>> pendingIds() async {
      final settings = await PaperSettingsDao().get();
      final cursor =
          jsonDecode(settings.pollerCursorJson!) as Map<String, dynamic>;
      return cursor['hot_recheck_cursor_task-1_r1'] as List<dynamic>;
    }

    await CollectionService(client: client, nowUtc: () => now)
        .schedulePeriodicRecheck(task: task, windows: windows, now: now);
    expect(await pendingIds(), hasLength(specs.length - 10));
    await CollectionService(client: client, nowUtc: () => now)
        .schedulePeriodicRecheck(
            task: task,
            windows: windows,
            now: now.add(const Duration(minutes: 1)));
    expect(await pendingIds(), hasLength(specs.length - 20));
    for (var turn = 0; turn < 5; turn++) {
      await CollectionService(client: client, nowUtc: () => now)
          .schedulePeriodicRecheck(
              task: task,
              windows: windows,
              now: now.add(Duration(minutes: turn + 2)));
    }
    expect(await pendingIds(), isEmpty);
    expect(
        (await PaperSliceDao().selectByTask(task.taskId))
            .where((row) => row.status == PaperSliceStatus.completed),
        isEmpty);
  });

  test(
      'P03: page-2 failure then recovery keeps every id and the breakpoint '
      'does not advance past the failed page', () async {
    final dao = PaperSliceDao();
    await dao.ensure(newSlice());
    var slice = (await dao.selectByKey(
      taskId: 'task-1',
      revision: 1,
      channel: PaperChannel.latest,
      branchHash: 'topic',
      fromUtc: DateTime.utc(2026, 1, 1),
      toUtc: DateTime.utc(2026, 1, 2),
    ))!;

    // Pages are requested at start=0 and start=3 (page size 3, 5 entries):
    // fail the SECOND page so page 1 is committed and page 2 is not.
    final smallClient = _SmallPageFake(
        corpus: [for (var i = 0; i < 5; i++) entryOf(i)], pageSize: 3);
    smallClient.failOnStart = 3;
    final smallService = CollectionService(
      client: smallClient,
      nowUtc: () => DateTime.utc(2026, 2, 1),
    );

    final outcome1 = await smallService.scanSlice(
      task: task,
      slice: slice,
      branch: branch(),
      run: run,
    );
    expect(outcome1.reason, ScanStopReason.failed);

    slice = (await dao.selectByKey(
      taskId: 'task-1',
      revision: 1,
      channel: PaperChannel.latest,
      branchHash: 'topic',
      fromUtc: DateTime.utc(2026, 1, 1),
      toUtc: DateTime.utc(2026, 1, 2),
    ))!;
    expect(slice.status, PaperSliceStatus.failed);
    // Page 1 committed (3 entries); the failed page 2 must not advance.
    expect(slice.startIndex, 3);
    expect(slice.insertedCount, 3);

    // Recovery re-scan: restarts from 0 and dedups; every id present once.
    final outcome2 = await smallService.scanSlice(
      task: task,
      slice: slice,
      branch: branch(),
      run: run,
    );
    expect(outcome2.reason, ScanStopReason.completed);

    final rows = await PaperDao().selectPage(
      where: '1 = 1',
      whereArgs: const [],
      orderBy: 'arxiv_id ASC',
      limit: 50,
      offset: 0,
    );
    expect(rows, hasLength(5),
        reason: 'unique ids must not be lost across recovery');
    final ids = rows.map((p) => p.arxivId).toSet();
    expect(ids, {
      '2601.00000',
      '2601.00001',
      '2601.00002',
      '2601.00003',
      '2601.00004',
    });
  });

  test('P01: same id from a later page after restart keeps first_seen',
      () async {
    final client = _SmallPageFake(
        corpus: [for (var i = 0; i < 2; i++) entryOf(i)], pageSize: 2);
    final service = CollectionService(
      client: client,
      nowUtc: () => DateTime.utc(2026, 2, 1),
    );
    final dao = PaperSliceDao();
    await dao.ensure(newSlice());
    var slice = (await dao.selectByKey(
      taskId: 'task-1',
      revision: 1,
      channel: PaperChannel.latest,
      branchHash: 'topic',
      fromUtc: DateTime.utc(2026, 1, 1),
      toUtc: DateTime.utc(2026, 1, 2),
    ))!;

    await service.scanSlice(
        task: task, slice: slice, branch: branch(), run: run);
    final first = (await PaperDao().selectById('2601.00000'))!;

    // A second pass re-scans the same slice (e.g. periodic recheck).
    slice.status = PaperSliceStatus.interrupted;
    await service.scanSlice(
        task: task, slice: slice, branch: branch(), run: run);
    final second = (await PaperDao().selectById('2601.00000'))!;
    expect(second.firstSeenAt, first.firstSeenAt);
  });

  test('P04: oversized slice splits and children must complete for coverage',
      () async {
    final big = [
      for (var i = 0; i < 1001; i++)
        ArxivEntry(
          rawId: '2601.1000${i % 10}v1',
          arxivId: '2601.${10000 + i}',
          version: 1,
          title: 'Big $i',
          authors: const [PaperAuthor(name: 'Alice')],
          abstractText: 'object detection',
          categories: const ['cs.CV'],
          publishedAt: DateTime.utc(2026, 1, 1, 0, i % 60, i ~/ 60),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
    ];
    final client = _SplitAwareFake(corpus: big);
    final service = CollectionService(
      client: client,
      nowUtc: () => DateTime.utc(2026, 2, 1),
    );
    final dao = PaperSliceDao();
    await dao.ensure(newSlice());
    final slice = (await dao.selectByKey(
      taskId: 'task-1',
      revision: 1,
      channel: PaperChannel.latest,
      branchHash: 'topic',
      fromUtc: DateTime.utc(2026, 1, 1),
      toUtc: DateTime.utc(2026, 1, 2),
    ))!;

    final outcome = await service.scanSlice(
      task: task,
      slice: slice,
      branch: branch(),
      run: run,
    );
    expect(outcome.reason, ScanStopReason.split);
    expect(outcome.children, isNotEmpty);

    // Coverage must not be claimed until children complete.
    final coveredBefore = await service.isChannelCovered(
      task: task,
      channel: PaperChannel.latest,
      fromUtc: DateTime.utc(2026, 1, 1),
      toUtc: DateTime.utc(2026, 1, 2),
    );
    expect(coveredBefore, isFalse);
  });

  test('R02: planning terminates and buckets cover the range', () {
    final specs = planSlices(
      channel: PaperChannel.hot,
      fromUtc: DateTime.utc(2025, 12, 25),
      toUtc: DateTime.utc(2026, 1, 10),
      branchHash: 'topic',
    );
    expect(specs.length, lessThan(100), reason: 'must terminate');
    // Every instant in the range is inside at least one bucket.
    final probe = DateTime.utc(2025, 12, 28, 13);
    expect(
      specs.any((s) => !probe.isBefore(s.fromUtc) && probe.isBefore(s.toUtc)),
      isTrue,
    );
    // Buckets never duplicate the same range.
    final keys = specs.map((s) => '${s.fromUtc}|${s.toUtc}').toSet();
    expect(keys.length, specs.length);
  });
}

/// Small-page variant used by the failure/recovery scenarios.
class _SmallPageFake extends ArxivClient {
  _SmallPageFake({required this.corpus, required this.pageSize});

  final List<ArxivEntry> corpus;
  final int pageSize;
  int failOnStart = -1;

  @override
  Future<ArxivPage> fetchPage({
    required String searchQuery,
    required int start,
    int maxResults = ArxivClient.defaultPageSize,
  }) async {
    if (start == failOnStart) {
      failOnStart = -1;
      throw ArxivException('fixture failure', retriable: true);
    }
    final end = (start + pageSize).clamp(0, corpus.length).toInt();
    return ArxivPage(
      entries: corpus.sublist(start, end),
      totalResults: corpus.length,
      startIndex: start,
      itemsPerPage: pageSize,
    );
  }
}

/// Fake whose totalResults is above the subdivide threshold but whose
/// per-page answers shrink after a split (children queries filter by range).
class _SplitAwareFake extends ArxivClient {
  _SplitAwareFake({required this.corpus});

  final List<ArxivEntry> corpus;

  @override
  Future<ArxivPage> fetchPage({
    required String searchQuery,
    required int start,
    int maxResults = ArxivClient.defaultPageSize,
  }) async {
    // The probe asks for 1 entry; report the full total to trigger split.
    if (maxResults == 1 && start == 0) {
      return ArxivPage(
        entries: [corpus.first],
        totalResults: corpus.length,
        startIndex: 0,
        itemsPerPage: 1,
      );
    }
    final end = (start + maxResults).clamp(0, corpus.length).toInt();
    return ArxivPage(
      entries: corpus.sublist(start, end),
      totalResults: corpus.length,
      startIndex: start,
      itemsPerPage: maxResults,
    );
  }
}
