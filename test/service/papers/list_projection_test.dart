import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/providers/paper_list.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'codex_repair_test.dart' show samplePaper;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ProviderContainer container;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('paper-list-test');
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    PaperDatabase.instance.debugDbPathOverride = p.join(root.path, 'papers.db');
    await PaperDatabase.instance.open();
    final now = DateTime.now().toUtc();
    await PaperTaskDao().upsert(PaperTask(
        taskId: 'current',
        name: 'current',
        enabled: true,
        priority: 1,
        config: const PaperTaskConfig(researchTopic: 'detection'),
        queryRevision: 2,
        createTime: now,
        modifyTime: now));
    final paper = samplePaper().toDb()
      ..['published_at'] = now.toIso8601String();
    await PaperDatabase.instance.txn((txn) async {
      await txn.insert('papers', paper);
      await txn.insert(
          'paper_task_matches',
          PaperTaskMatch(
                  id: 0,
                  taskId: 'current',
                  queryRevision: 2,
                  arxivId: samplePaper().arxivId,
                  branch: PaperMatchBranch.topic,
                  evidenceJson: '{}',
                  firstSeenAt: now,
                  lastSeenAt: now,
                  ruleScore: 10,
                  analysisCacheKey: 'foreign',
                  aiScore: 95)
              .toDb()
            ..remove('id'));
    });
    await PaperAnalysisDao().upsert(PaperAnalysis(
        cacheKey: 'foreign',
        arxivId: samplePaper().arxivId,
        contentHash: 'body',
        modelFingerprint: await currentAnalysisModelFingerprint(),
        promptVersion: 1,
        resultVersion: 1,
        titleZh: '标题',
        abstractZh: '摘要',
        assessments: [
          PaperAssessment(
              taskId: 'current',
              profileHash: 'old-topic',
              relevanceScore: 95,
              reasonZh: 'reason',
              evidence: const [])
        ],
        status: PaperAnalysisStatus.succeeded,
        createdAt: now));
    container = ProviderContainer();
  });
  tearDown(() async {
    container.dispose();
    await PaperDatabase.instance.close();
    PaperDatabase.instance.debugDbPathOverride = null;
    await root.delete(recursive: true);
  });

  test('pending filter and card both reject an old-profile projection',
      () async {
    final result = await container.read(paperListProvider(
            const PaperListQuery(filter: PaperListFilter.pendingAnalysis))
        .future);
    expect(result.pendingCount, 1);
    expect(result.items, hasLength(1));
    expect(result.items.single.assessmentPending, isTrue);
    expect(result.items.single.aiScore, isNull);
  });

  test('ignored candidates remain stored and stay outside pending results',
      () async {
    await PaperDao().setIgnored(samplePaper().arxivId, true);
    final result = await container.read(paperListProvider(
            const PaperListQuery(filter: PaperListFilter.pendingAnalysis))
        .future);
    expect(result.items, isEmpty);
    expect(await PaperDao().selectById(samplePaper().arxivId), isNotNull);
  });
}
