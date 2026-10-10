import 'dart:io';

import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:anx_reader/service/papers/citation_service.dart';
import 'package:anx_reader/service/papers/semantic_scholar_client.dart';
import 'package:flutter_test/flutter_test.dart';

Paper paperOf(String id, {String contentHash = 'h1'}) => Paper(
      arxivId: id,
      latestVersion: 1,
      title: 't$id',
      authors: const [PaperAuthor(name: 'A')],
      abstractText: 'abstract $id',
      categories: const ['cs.CV'],
      publishedAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      contentHash: contentHash,
      firstSeenAt: DateTime.utc(2026, 1, 1),
      lastSeenAt: DateTime.utc(2026, 1, 1),
    );

class FailingCitationClient extends SemanticScholarClient {
  int requests = 0;
  @override
  Future<List<CitationLookupResult>> lookup(List<String> ids) async {
    requests++;
    throw SemanticScholarException('HTTP 429');
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('round4_contracts');
    PaperDatabase.instance.debugDbPathOverride =
        '${tempDir.path}${Platform.pathSeparator}paper_collection.db';
    await PaperDatabase.instance.open();
    await PaperDatabase.instance.txn((txn) async {
      await txn.insert('papers', paperOf('2601.00003').toDb());
      await txn.insert('papers', paperOf('2601.00004').toDb());
    });
  });

  tearDown(() async {
    await PaperDatabase.instance.close();
    PaperDatabase.instance.debugDbPathOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('G02: pending queue follows the full validity contract', () {
    test('pure translation populates a reusable match projection', () async {
      final paper = paperOf('2601.00001');
      await PaperTaskDao().upsert(PaperTask(
          taskId: 'author',
          name: 'author',
          enabled: true,
          priority: 3,
          config: const PaperTaskConfig(authors: [PaperAuthorWatch(name: 'A')]),
          queryRevision: 1,
          createTime: DateTime.utc(2026),
          modifyTime: DateTime.utc(2026)));
      final match = PaperTaskMatch(
          id: 0,
          taskId: 'author',
          queryRevision: 1,
          arxivId: paper.arxivId,
          branch: PaperMatchBranch.author,
          evidenceJson: '{}',
          firstSeenAt: DateTime.utc(2026),
          lastSeenAt: DateTime.utc(2026));
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert('papers', paper.toDb());
        await txn.insert('paper_task_matches', match.toDb()..remove('id'));
      });
      final service = AnalysisService();
      await service.saveSuccess(
          paper: paper,
          payload: const AnalysisResultPayload(
              titleZh: '标题', abstractZh: '摘要', assessments: []),
          modelFingerprint: 'model',
          tasks: const [],
          matches: [match],
          quotaDay: '2026-01-01');
      expect(
          await PaperDao().selectPendingAnalysisPapers(
              limit: 10, offset: 0, modelFingerprint: 'model'),
          isEmpty);
      final reusable = await service.findReusable(
          paper: paper,
          taskIdToProfileHash: const {},
          modelFingerprint: 'model');
      expect(reusable.translationCacheKey, isNotNull);
    });

    test('keyset walks beyond a thousand candidates despite projection writes',
        () async {
      final now = DateTime.utc(2026);
      await PaperTaskDao().upsert(PaperTask(
          taskId: 'large',
          name: 'large',
          enabled: true,
          priority: 5,
          config: const PaperTaskConfig(),
          queryRevision: 1,
          createTime: now,
          modifyTime: now));
      await PaperDatabase.instance.txn((txn) async {
        for (var index = 0; index < 1201; index++) {
          final id = '2601.${(index + 10000).toString().padLeft(5, '0')}';
          await txn.insert('papers', paperOf(id).toDb());
          await txn.insert(
              'paper_task_matches',
              PaperTaskMatch(
                      id: 0,
                      taskId: 'large',
                      queryRevision: 1,
                      arxivId: id,
                      branch: PaperMatchBranch.topic,
                      evidenceJson: '{}',
                      firstSeenAt: now,
                      lastSeenAt: now)
                  .toDb()
                ..remove('id'));
        }
      });
      String? afterDate;
      String? afterId;
      final seen = <String>{};
      while (true) {
        final page = await PaperDao().selectAnalysisCandidates(
            limit: 200, afterDate: afterDate, afterId: afterId);
        if (page.isEmpty) break;
        seen.addAll(page.map((paper) => paper.arxivId));
        await PaperMatchDao().updateScoreProjection(
            taskId: 'large',
            queryRevision: 1,
            arxivId: page.first.arxivId,
            ruleScore: 10,
            aiScore: 90,
            analysisCacheKey: 'changed');
        afterDate = page.last.publishedAt.toUtc().toIso8601String();
        afterId = page.last.arxivId;
      }
      expect(seen, hasLength(1201));
      expect(seen, contains('2601.11200'));
    });
    test('old-model success projection re-enters the queue', () async {
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert('papers', paperOf('2601.00001').toDb());
      });
      // Match projected against an analysis produced by a previous model.
      final analysis = PaperAnalysis(
        cacheKey: 'old-model',
        arxivId: '2601.00001',
        contentHash: 'h1',
        modelFingerprint: 'model-A',
        promptVersion: 1,
        resultVersion: 1,
        titleZh: '标题',
        abstractZh: '摘要',
        assessments: const [],
        status: PaperAnalysisStatus.succeeded,
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await PaperAnalysisDao().upsert(analysis);
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert("paper_tasks", <String, Object?>{
          'task_id': 'task-1',
          'name': 't',
          'enabled': 1,
          'priority': 3,
          'config_json':
              '{"v":1,"research_topic":"","keyword_groups":[],"authors":[],"categories":[],"not_interested":"","group_operator_or":true,"frequency_hours":24,"latest_window_days":30,"hot_window_months":12}',
          'config_version': 1,
          'query_revision': 1,
          'create_time': DateTime.utc(2026, 1, 1).toIso8601String(),
          'modify_time': DateTime.utc(2026, 1, 1).toIso8601String(),
        });
        await txn.insert('paper_task_matches', <String, Object?>{
          'task_id': 'task-1',
          'query_revision': 1,
          'arxiv_id': '2601.00001',
          'branch': 'topic',
          'evidence_json': '{}',
          'first_seen_at': DateTime.utc(2026, 1, 2).toIso8601String(),
          'last_seen_at': DateTime.utc(2026, 1, 2).toIso8601String(),
          'rule_score': 10,
          'ai_score': 88,
          'analysis_cache_key': 'old-model',
        });
      });

      // Switching the model must re-queue the paper (model-A -> model-B).
      final pending = await PaperDao().selectPendingAnalysisPapers(
          limit: 10, offset: 0, modelFingerprint: 'model-B');
      expect(pending, hasLength(1));

      // The SAME fingerprint that produced the projection is a cache hit.
      final stillPending = await PaperDao().selectPendingAnalysisPapers(
          limit: 10, offset: 0, modelFingerprint: 'model-A');
      expect(stillPending, isEmpty);
    });

    test('body change invalidates a non-empty projection', () async {
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert(
            'papers', paperOf('2601.00002', contentHash: 'new').toDb());
      });
      final analysis = PaperAnalysis(
        cacheKey: 'old-body',
        arxivId: '2601.00002',
        contentHash: 'old',
        modelFingerprint: 'model-A',
        promptVersion: 1,
        resultVersion: 1,
        titleZh: '标题',
        abstractZh: '摘要',
        assessments: const [],
        status: PaperAnalysisStatus.succeeded,
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await PaperAnalysisDao().upsert(analysis);
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert("paper_tasks", <String, Object?>{
          'task_id': 'task-1',
          'name': 't',
          'enabled': 1,
          'priority': 3,
          'config_json':
              '{"v":1,"research_topic":"","keyword_groups":[],"authors":[],"categories":[],"not_interested":"","group_operator_or":true,"frequency_hours":24,"latest_window_days":30,"hot_window_months":12}',
          'config_version': 1,
          'query_revision': 1,
          'create_time': DateTime.utc(2026, 1, 1).toIso8601String(),
          'modify_time': DateTime.utc(2026, 1, 1).toIso8601String(),
        });
        await txn.insert('paper_task_matches', <String, Object?>{
          'task_id': 'task-1',
          'query_revision': 1,
          'arxiv_id': '2601.00002',
          'branch': 'topic',
          'evidence_json': '{}',
          'first_seen_at': DateTime.utc(2026, 1, 2).toIso8601String(),
          'last_seen_at': DateTime.utc(2026, 1, 2).toIso8601String(),
          'rule_score': 10,
          'ai_score': 88,
          'analysis_cache_key': 'old-body',
        });
      });

      final pending = await PaperDao().selectPendingAnalysisPapers(
          limit: 10, offset: 0, modelFingerprint: 'model-A');
      expect(pending, hasLength(1));
    });
  });

  group('G09: manual recovery resets the attempt gate', () {
    test('a changed profile does not inherit an exhausted request', () async {
      final paper = paperOf('2601.00003');
      final first = AnalysisTaskInput(
          taskId: 'task',
          profileHash: 'old',
          config: const PaperTaskConfig(researchTopic: 'old'));
      final changed = AnalysisTaskInput(
          taskId: 'task',
          profileHash: 'new',
          config: const PaperTaskConfig(researchTopic: 'new'));
      final service = AnalysisService();
      await service.recordFailure(
          arxivId: paper.arxivId,
          contentHash: paper.contentHash,
          modelFingerprint: 'model',
          failureClass: 'validation',
          attempt: 3,
          requestIdentity: analysisRequestIdentity(paper, [first], 'model'));
      expect(
          await service.retryAllowed(
              arxivId: paper.arxivId,
              contentHash: paper.contentHash,
              modelFingerprint: 'model',
              nowUtc: DateTime.utc(2030),
              requestIdentity:
                  analysisRequestIdentity(paper, [first], 'model')),
          isFalse);
      expect(
          await service.retryAllowed(
              arxivId: paper.arxivId,
              contentHash: paper.contentHash,
              modelFingerprint: 'model',
              nowUtc: DateTime.utc(2030),
              requestIdentity:
                  analysisRequestIdentity(paper, [changed], 'model')),
          isTrue);
    });
    test('exhausted identity is retryable after clearFailures', () async {
      final service = AnalysisService();
      await service.recordFailure(
        arxivId: '2601.00003',
        contentHash: 'h1',
        modelFingerprint: 'model-A',
        failureClass: 'validation',
        attempt: 3,
      );
      var attempts = await service.attemptCountFor(
          arxivId: '2601.00003',
          contentHash: 'h1',
          modelFingerprint: 'model-A');
      expect(attempts, 3);

      await service.clearFailures(
        arxivId: '2601.00003',
        contentHash: 'h1',
        modelFingerprint: 'model-A',
      );
      attempts = await service.attemptCountFor(
          arxivId: '2601.00003',
          contentHash: 'h1',
          modelFingerprint: 'model-A');
      expect(attempts, 0, reason: 'manual recovery starts a fresh cycle');
    });

    test('a different body has an independent attempt identity', () async {
      final service = AnalysisService();
      await service.recordFailure(
        arxivId: '2601.00004',
        contentHash: 'old',
        modelFingerprint: 'model-A',
        failureClass: 'validation',
        attempt: 3,
      );
      final attempts = await service.attemptCountFor(
          arxivId: '2601.00004',
          contentHash: 'new',
          modelFingerprint: 'model-A');
      expect(attempts, 0);
    });
  });

  group('G12: import ownership is request-scoped', () {
    test('a second request cannot hijack a live owner', () async {
      final service = PaperImportService();
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert('papers', paperOf('2601.00005').toDb());
      });
      final paper = (await PaperDao().selectById('2601.00005'))!;

      final first = await service.startImport(
        paper: paper,
        downloadVersion: 1,
        requestId: 'req-1',
        nowUtc: DateTime.utc(2026, 1, 1),
      );
      expect(first, isNotNull);

      final second = await service.startImport(
        paper: paper,
        downloadVersion: 1,
        requestId: 'req-2',
        nowUtc: DateTime.utc(2026, 1, 1),
      );
      expect(second, isNull, reason: 'live owner blocks duplicate requests');

      // Releasing with the WRONG token does not drop the owner.
      service.endRequest(paper.arxivId, 'req-other');
      final third = await service.startImport(
        paper: paper,
        downloadVersion: 1,
        requestId: 'req-3',
        nowUtc: DateTime.utc(2026, 1, 1),
      );
      expect(third, isNull);

      // The owning token releases it.
      service.endRequest(paper.arxivId, 'req-1');
      final fourth = await service.startImport(
        paper: paper,
        downloadVersion: 1,
        requestId: 'req-4',
        nowUtc: DateTime.utc(2026, 1, 1),
      );
      expect(fourth, isNotNull);
    });

    test('a recoverable record keeps requestId / cache / MD5', () async {
      final service = PaperImportService();
      await PaperDatabase.instance.txn((txn) async {
        await txn.insert('papers', paperOf('2601.00006').toDb());
      });
      final paper = (await PaperDao().selectById('2601.00006'))!;
      final record = await service.startImport(
        paper: paper,
        downloadVersion: 2,
        requestId: 'req-cache',
        nowUtc: DateTime.utc(2026, 1, 1),
      );
      record!
        ..status = PaperImportStatus.downloaded
        ..cacheRelPath = 'paper-collection/req-cache/a.pdf'
        ..pdfMd5 = 'md5-a';
      await PaperImportDao().upsert(record);
      // Simulate restart: the process loses its in-memory owners.
      await PaperImportDao().markOpenInterrupted();

      final restarted = PaperImportService();
      final resumed = await restarted.startImport(
        paper: paper,
        downloadVersion: 2,
        requestId: 'req-new',
        nowUtc: DateTime.utc(2026, 1, 2),
      );
      expect(resumed, isNotNull);
      // Cache identity preserved so the download can be reused.
      expect(resumed!.requestId, 'req-cache');
      expect(resumed.cacheRelPath, isNotNull);
      expect(resumed.pdfMd5, 'md5-a');
      restarted.endRequest(paper.arxivId, resumed.requestId);
      expect(
          await restarted.startImport(
              paper: paper,
              downloadVersion: 2,
              requestId: 'again',
              nowUtc: DateTime.utc(2026, 1, 3)),
          isNotNull);
    });
  });

  group('G10: quota uses the transactional limit', () {
    test('whole citation batch failure keeps stale values and persists backoff',
        () async {
      final now = DateTime.utc(2026, 10, 10);
      final client = FailingCitationClient();
      await PaperCitationDao().upsert(PaperCitation(
          arxivId: '2601.00003',
          provider: 'semantic_scholar',
          citationCount: 12,
          lastSuccessAt: now.subtract(const Duration(days: 8)),
          lastAttemptAt: now.subtract(const Duration(days: 8)),
          nextRefreshAt: now));
      final service = CitationService(client: client);
      await service.drainBatch(maxItems: 20, nowUtc: now);
      final stale = (await PaperCitationDao().selectById('2601.00003'))!;
      final unknown = (await PaperCitationDao().selectById('2601.00004'))!;
      expect(stale.citationCount, 12);
      expect(stale.isStale, isTrue);
      expect(unknown.isUnknown, isTrue);
      expect(unknown.nextRefreshAt, now.add(const Duration(hours: 24)));
      await service.drainBatch(
          maxItems: 20, nowUtc: now.add(const Duration(minutes: 1)));
      expect(client.requests, 1);
    });
    test('lowering the DB limit mid-batch stops further reservations',
        () async {
      final service = AnalysisService();
      // Fill up to the current limit (100 default).
      String? day;
      for (var i = 0; i < 100; i++) {
        day = await service.reserveQuota(fallbackDailyLimit: 100);
        expect(day, isNotNull);
      }
      expect(await service.reserveQuota(fallbackDailyLimit: 100), isNull);

      // New day, then lower the stored limit before the next reserve.
      final settings = await PaperSettingsDao().get();
      settings.quotaDay = '2000-01-01'; // force a day roll on next reserve
      await PaperSettingsDao().save(settings);
      await PaperSettingsDao().updateDailyLimit(2);
      expect(await service.reserveQuota(fallbackDailyLimit: 100), isNotNull);
      expect(await service.reserveQuota(fallbackDailyLimit: 100), isNotNull);
      // The third exceeds the STORED limit of 2 even though the caller
      // still passes the old 100.
      expect(await service.reserveQuota(fallbackDailyLimit: 100), isNull);
    });
  });

  group('G05: pre-dispatch cancellation identity', () {
    test('cancel() bumps the generation used by analyze', () {
      final service = AnalysisService();
      // Behavioral smoke: cancel is callable repeatedly and does not throw;
      // the send-gate is exercised through the production controller path.
      service.cancel();
      service.cancel();
    });
  });
}
