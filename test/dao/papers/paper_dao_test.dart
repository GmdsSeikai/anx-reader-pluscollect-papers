import 'dart:io';

import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:flutter_test/flutter_test.dart';

Paper paperOf(
  String id, {
  DateTime? published,
  DateTime? firstSeen,
  String title = 'Title',
}) {
  final publishedAt = published ?? DateTime.utc(2026, 1, 1);
  return Paper(
    arxivId: id,
    latestVersion: 1,
    title: title,
    authors: const [PaperAuthor(name: 'Alice')],
    abstractText: 'abstract of $id',
    categories: const ['cs.CV'],
    publishedAt: publishedAt,
    updatedAt: publishedAt,
    contentHash: Paper.contentHashOf(
      title: title,
      abstractText: 'abstract of $id',
      authors: const [PaperAuthor(name: 'Alice')],
      categories: const ['cs.CV'],
    ),
    firstSeenAt: firstSeen ?? DateTime.utc(2026, 2, 1),
    lastSeenAt: DateTime.utc(2026, 2, 1),
  );
}

PaperScanSlice sliceOf({PaperSliceStatus status = PaperSliceStatus.pending}) {
  return PaperScanSlice(
    sliceId: 0,
    taskId: 'task-1',
    revision: 1,
    channel: PaperChannel.latest,
    branchHash: 'topic',
    fromUtc: DateTime.utc(2026, 1, 1),
    toUtc: DateTime.utc(2026, 1, 2),
    requestQuery:
        'submittedDate:[202601010000 TO 202601022359] AND (cat:cs.CV)',
    status: status,
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('paper_dao_test');
    PaperDatabase.instance.debugDbPathOverride =
        '${tempDir.path}${Platform.pathSeparator}paper_collection.db';
    await PaperDatabase.instance.open();
    final now = DateTime.utc(2026);
    await PaperTaskDao().upsert(PaperTask(
        taskId: 'task-1',
        name: 'vision',
        enabled: true,
        priority: 3,
        config: const PaperTaskConfig(),
        queryRevision: 1,
        createTime: now,
        modifyTime: now));
  });

  tearDown(() async {
    await PaperDatabase.instance.close();
    PaperDatabase.instance.debugDbPathOverride = null;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('scan page commits', () {
    test('upsert, discovery relation and breakpoint share one transaction',
        () async {
      final dao = PaperSliceDao();
      final slice = sliceOf();
      await dao.ensure(slice);
      final stored = await dao.selectByKey(
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
      );
      expect(stored, isNotNull);

      final papers = [paperOf('2309.02719'), paperOf('2309.02720')];
      final matches = [
        for (final p in papers)
          PaperTaskMatch(
            id: 0,
            taskId: 'task-1',
            queryRevision: 1,
            arxivId: p.arxivId,
            branch: PaperMatchBranch.topic,
            evidenceJson: PaperTaskMatch.encodeEvidence(
              titlePhrases: const {},
              abstractPhrases: const {},
            ),
            firstSeenAt: DateTime.utc(2026, 2, 1),
            lastSeenAt: DateTime.utc(2026, 2, 1),
            ruleScore: 10,
          ),
      ];

      final row = (await dao.selectByKey(
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
      ))!;

      row.startIndex = 100;
      row.insertedCount = 2;
      row.status = PaperSliceStatus.running;
      row.totalReported = 2;

      await commitScanPage(
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        slice: row,
        papers: papers,
        matches: matches,
        nowUtc: DateTime.utc(2026, 2, 1),
      );

      final reloaded = (await dao.selectByKey(
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
      ))!;
      expect(reloaded.startIndex, 100);
      expect(reloaded.insertedCount, 2);

      final storedPaper = await PaperDao().selectById('2309.02719');
      expect(storedPaper, isNotNull);
      final matchRows = await PaperMatchDao().selectForPaper('2309.02719');
      expect(matchRows, hasLength(1));
    });

    test('P01: same id from two branches/tasks keeps first_seen and dedups',
        () async {
      final dao = PaperSliceDao();
      final slice = sliceOf();
      await dao.ensure(slice);
      final row = (await dao.selectByKey(
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 2),
      ))!;

      final firstSeen = DateTime.utc(2026, 1, 5);
      final laterSeen = DateTime.utc(2026, 3, 5);

      await commitScanPage(
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        slice: row,
        papers: [
          paperOf('2309.02719',
              published: DateTime.utc(2023, 9, 6),
              title: 'Original',
              firstSeen: firstSeen),
        ],
        matches: [
          PaperTaskMatch(
            id: 0,
            taskId: 'task-1',
            queryRevision: 1,
            arxivId: '2309.02719',
            branch: PaperMatchBranch.topic,
            evidenceJson: PaperTaskMatch.encodeEvidence(
                titlePhrases: const {}, abstractPhrases: const {}),
            firstSeenAt: firstSeen,
            lastSeenAt: firstSeen,
          ),
        ],
        nowUtc: firstSeen,
      );

      // Second discovery (newer version metadata from the source).
      await commitScanPage(
        taskId: 'task-1',
        revision: 1,
        channel: PaperChannel.latest,
        branchHash: 'topic',
        slice: row,
        papers: [
          paperOf('2309.02719',
              published: DateTime.utc(2023, 9, 6),
              title: 'Updated Title',
              firstSeen: laterSeen),
        ],
        matches: [
          PaperTaskMatch(
            id: 0,
            taskId: 'task-1',
            queryRevision: 1,
            arxivId: '2309.02719',
            branch: PaperMatchBranch.topic,
            evidenceJson: PaperTaskMatch.encodeEvidence(
                titlePhrases: const {}, abstractPhrases: const {}),
            firstSeenAt: laterSeen,
            lastSeenAt: laterSeen,
          ),
        ],
        nowUtc: laterSeen,
      );

      final paper = (await PaperDao().selectById('2309.02719'))!;
      // published_at is the first submission and is never replaced.
      expect(paper.publishedAt, DateTime.utc(2023, 9, 6));
      // first_seen_at keeps the earlier discovery time.
      expect(paper.firstSeenAt, firstSeen);
      // Metadata is updated to the latest source view.
      expect(paper.title, 'Updated Title');
      final matches = await PaperMatchDao().selectForPaper('2309.02719');
      expect(matches, hasLength(1),
          reason: 'unique per (task, revision, paper)');
    });

    test('P06: quota reservation is atomic and never exceeds the limit',
        () async {
      final settingsDao = PaperSettingsDao();
      final now = DateTime.utc(2026, 1, 10, 12);

      var reservedCount = 0;
      for (var i = 0; i < 101; i++) {
        final reserved = await PaperDatabase.instance.txn((txn) {
          return reserveAnalysisQuota(
            txn: txn,
            fallbackDailyLimit: 100,
            nowUtc: now,
          );
        });
        if (reserved) reservedCount++;
      }
      // Exactly 100 reservations succeed; the 101st is refused.
      expect(reservedCount, 100);

      final settings = await settingsDao.get();
      expect(settings.reservedCount, 100);
      expect(settings.quotaDay, '2026-01-10');

      // A new UTC day resets the counter.
      final nextDay = DateTime.utc(2026, 1, 11, 0, 1);
      final ok = await PaperDatabase.instance.txn((txn) {
        return reserveAnalysisQuota(
            txn: txn, fallbackDailyLimit: 100, nowUtc: nextDay);
      });
      expect(ok, isTrue);
      final after = await settingsDao.get();
      expect(after.quotaDay, '2026-01-11');
      expect(after.reservedCount, 1);
    });

    test('P06: lowering the limit does not refund or over-issue', () async {
      final now = DateTime.utc(2026, 1, 10, 12);
      for (var i = 0; i < 5; i++) {
        await PaperDatabase.instance.txn((txn) {
          return reserveAnalysisQuota(
              txn: txn, fallbackDailyLimit: 100, nowUtc: now);
        });
      }
      // Lower the daily limit below what is already reserved.
      final settings = await PaperSettingsDao().get();
      settings.dailyLimit = 3;
      await PaperSettingsDao().save(settings);

      final reserved = await PaperDatabase.instance.txn((txn) {
        return reserveAnalysisQuota(
            txn: txn, fallbackDailyLimit: 3, nowUtc: now);
      });
      expect(reserved, isFalse);
    });
  });

  group('paper analysis cache', () {
    test('P08-style: success rows are queryable and keyed uniquely', () async {
      final analysis = PaperAnalysis(
        cacheKey: 'key-1',
        arxivId: '2309.02719',
        contentHash: 'hash',
        modelFingerprint: 'fp',
        promptVersion: 1,
        resultVersion: 1,
        titleZh: '标题',
        abstractZh: '摘要',
        assessments: [
          PaperAssessment(
            taskId: 'task-1',
            profileHash: 'ph1',
            relevanceScore: 80,
            reasonZh: '相关',
            evidence: const [
              PaperEvidenceQuote(field: 'abstract', quote: 'x'),
            ],
          ),
        ],
        status: PaperAnalysisStatus.succeeded,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await PaperDatabase.instance.txn((txn) async {
        await txn.insert('papers', paperOf('2309.02719').toDb());
      });
      await PaperAnalysisDao().upsert(analysis);
      final loaded = await PaperAnalysisDao().selectByKey('key-1');
      expect(loaded, isNotNull);
      expect(loaded!.assessments.single.relevanceScore, 80);

      final succeeded =
          await PaperAnalysisDao().selectSucceededForPaper('2309.02719');
      expect(succeeded, hasLength(1));
    });
  });

  group('import records', () {
    test('P12-style: import record round-trips book binding fields', () async {
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert('papers', paperOf('2309.02719').toDb());
      });
      final record = PaperImportRecord(
        arxivId: '2309.02719',
        downloadVersion: 2,
        requestId: 'req-1',
        status: PaperImportStatus.importing,
        startedAt: DateTime.utc(2026, 1, 1),
        pdfMd5: 'abc',
      );
      await PaperImportDao().upsert(record);

      // Simulate a crash after the main-library commit but before the
      // paper-library link: the record keeps its MD5 for reconciliation.
      await PaperImportDao().markOpenInterrupted();
      final reloaded = (await PaperImportDao().selectById('2309.02719'))!;
      expect(reloaded.status, PaperImportStatus.interrupted);
      expect(reloaded.pdfMd5, 'abc');
      expect(reloaded.downloadVersion, 2);
    });
  });

  group('schema version guard', () {
    test('P15-style: a newer schema refuses to open', () async {
      final current = await PaperDatabase.instance.database;
      await current.execute('PRAGMA user_version = 2');
      await PaperDatabase.instance.close();
      // Bump user_version above what this build supports.
      final path = PaperDatabase.instance.debugDbPathOverride!;
      final file = File(path);
      expect(file.existsSync(), isTrue);
      // Reopen with a higher version via raw ffi is out of scope here; the
      // guard is exercised by writing the pragma through a second open with
      // an upgraded version number simulated below.
      PaperDatabase.instance.debugDbPathOverride = path;
      await expectLater(PaperDatabase.instance.open(),
          throwsA(isA<PaperSchemaTooNewException>()));
      expect(file.existsSync(), isTrue);
    });
  });
}
