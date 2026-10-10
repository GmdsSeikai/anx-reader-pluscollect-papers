import 'dart:convert';

import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Shared SQL validity for aliases a (analysis), p (paper), m (match), t (task).
class PaperAnalysisValidity {
  PaperAnalysisValidity(List<PaperTask> tasks, String model) {
    final profiles = tasks.map((_) => 'WHEN ? THEN ?').join(' ');
    arguments = [
      model,
      for (final task in tasks) ...[
        task.taskId,
        task.config.semanticHash,
      ]
    ];
    final profile = tasks.isEmpty ? 'NULL' : 'CASE m.task_id $profiles END';
    sql = "a.status = 'succeeded' AND a.arxiv_id = p.arxiv_id "
        'AND a.content_hash = p.content_hash AND a.model_fingerprint = ? '
        'AND a.prompt_version = 1 AND a.result_version = 1 '
        "AND COALESCE(a.title_zh, '') != '' AND COALESCE(a.abstract_zh, '') != '' "
        'AND (NOT ($needsRelevance) OR EXISTS ('
        'SELECT 1 FROM json_each(a.assessments_json) assessment '
        "WHERE json_extract(assessment.value, '\$.task_id') = m.task_id "
        "AND json_extract(assessment.value, '\$.profile_hash') = $profile))";
  }

  static const needsRelevance =
      "TRIM(COALESCE(json_extract(t.config_json, '\$.research_topic'), '')) != '' "
      "OR COALESCE(json_array_length(json_extract(t.config_json, '\$.keyword_groups')), 0) > 0";
  late final String sql;
  late final List<Object?> arguments;
}

/// Atomic daily analysis-quota reservation.
///
/// The effective limit is read INSIDE the transaction (latest user
/// setting), and the quota day is captured from a single clock value so a
/// midnight boundary cannot return a different day than the one recorded.
/// A day change rolls the counter forward; lowering the daily limit never
/// refunds already reserved slots and never allows new ones past the
/// current limit.
Future<bool> reserveAnalysisQuota({
  required DatabaseExecutor txn,
  required int fallbackDailyLimit,
  required DateTime nowUtc,
}) async {
  final String day = PaperQuotaDay.dayOf(nowUtc);
  final rows = await txn.rawQuery(
    'SELECT quota_day, reserved_count, daily_limit FROM paper_settings WHERE id = 1',
  );
  if (rows.isEmpty) {
    throw StateError('paper_settings row missing');
  }
  final storedDay = rows.first['quota_day'] as String;
  int reserved = rows.first['reserved_count'] as int? ?? 0;
  final dailyLimit = (rows.first['daily_limit'] as int?) ?? fallbackDailyLimit;
  if (storedDay != day) {
    reserved = 0;
    await txn.update(
      'paper_settings',
      <String, Object?>{'quota_day': day, 'reserved_count': 0},
      where: 'id = 1',
    );
  }
  if (reserved >= dailyLimit) {
    return false;
  }
  await txn.update(
    'paper_settings',
    <String, Object?>{'reserved_count': reserved + 1},
    where: 'id = 1',
  );
  return true;
}

/// Atomic release of a reservation whose request was never sent.
///
/// [reservedOnDay] is the quota day the reservation was taken on; if the
/// stored day has moved past it the release is a no-op (the counter
/// already rolled).
Future<bool> releaseAnalysisQuota({
  required DatabaseExecutor txn,
  required String reservedOnDay,
}) async {
  final rows = await txn.rawQuery(
    'SELECT quota_day, reserved_count FROM paper_settings WHERE id = 1',
  );
  if (rows.isEmpty) return false;
  final storedDay = rows.first['quota_day'] as String;
  final reserved = rows.first['reserved_count'] as int? ?? 0;
  if (storedDay != reservedOnDay || reserved <= 0) return false;
  await txn.update(
    'paper_settings',
    <String, Object?>{'reserved_count': reserved - 1},
    where: 'id = 1',
  );
  return true;
}

class PaperSettingsDao {
  Future<PaperSettings> get() async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_settings', where: 'id = 1', limit: 1);
    if (rows.isEmpty) {
      throw StateError('paper_settings row missing');
    }
    return PaperSettings.fromDb(rows.first);
  }

  /// Whole-row write. Prefer the field-level updates below: a stale row
  /// snapshot written back here can reset the quota counter or drop keys
  /// another owner wrote concurrently.
  Future<void> save(PaperSettings settings) async {
    final db = await PaperDatabase.instance.database;
    await db.update('paper_settings', settings.toDb(), where: 'id = 1');
  }

  Future<void> updateDailyLimit(int dailyLimit) async {
    final db = await PaperDatabase.instance.database;
    await db.update(
        'paper_settings', <String, Object?>{'daily_limit': dailyLimit},
        where: 'id = 1');
  }

  Future<void> updateAnalysisService({
    String? providerId,
    String? modelOverride,
  }) async {
    final db = await PaperDatabase.instance.database;
    await db.update(
      'paper_settings',
      <String, Object?>{
        'analysis_provider_id': providerId,
        'analysis_model_override': modelOverride,
      },
      where: 'id = 1',
    );
  }

  /// Merge [entries] into the cursor JSON under its own keys and persist
  /// only the cursor column — quota and service selection are untouched.
  /// The read-merge-write runs in one transaction so concurrent owners
  /// (hot recheck markers, fair-schedule phase) cannot drop each other's
  /// keys.
  Future<void> updatePollerCursor(Map<String, dynamic> entries) async {
    await PaperDatabase.instance.txn((txn) async {
      final rows = await txn.query('paper_settings',
          columns: ['poller_cursor'], where: 'id = 1');
      Map<String, dynamic> current = {};
      if (rows.isNotEmpty) {
        final raw = rows.first['poller_cursor'] as String?;
        if (raw != null && raw.isNotEmpty) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) current = decoded;
          } catch (_) {}
        }
      }
      current.addAll(entries);
      await txn.update(
        'paper_settings',
        <String, Object?>{'poller_cursor': jsonEncode(current)},
        where: 'id = 1',
      );
    });
  }
}

class PaperTaskDao {
  Future<List<PaperTask>> selectAll() async {
    final db = await PaperDatabase.instance.database;
    final rows =
        await db.query('paper_tasks', orderBy: 'priority ASC, create_time ASC');
    return rows.map(PaperTask.fromDb).toList(growable: true);
  }

  Future<PaperTask?> selectById(String taskId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_tasks',
        where: 'task_id = ?', whereArgs: [taskId], limit: 1);
    if (rows.isEmpty) return null;
    return PaperTask.fromDb(rows.first);
  }

  Future<void> upsert(PaperTask task) async {
    final db = await PaperDatabase.instance.database;
    await db.insert('paper_tasks', task.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setEnabled(String taskId, bool enabled) async {
    final db = await PaperDatabase.instance.database;
    await db.update(
      'paper_tasks',
      <String, Object?>{
        'enabled': enabled ? 1 : 0,
        'modify_time': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
  }

  Future<void> setNextRun(String taskId, DateTime? nextRunAt) async {
    final db = await PaperDatabase.instance.database;
    await db.update(
      'paper_tasks',
      <String, Object?>{'next_run_at': nextRunAt?.toUtc().toIso8601String()},
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
  }
}

class PaperDao {
  Future<List<T>> rawQueryList<T>(
    String sql, {
    required List<Object?> arguments,
    required T Function(Map<String, Object?> row) mapper,
  }) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.rawQuery(sql, arguments);
    return rows.map(mapper).toList(growable: false);
  }

  Future<Paper?> selectById(String arxivId) async {
    final db = await PaperDatabase.instance.database;
    final rows =
        await db.query('papers', where: 'arxiv_id = ?', whereArgs: [arxivId]);
    if (rows.isEmpty) return null;
    return Paper.fromDb(rows.first);
  }

  Future<void> setIgnored(String arxivId, bool ignored) async {
    final db = await PaperDatabase.instance.database;
    await db.update(
      'papers',
      <String, Object?>{'ignored': ignored ? 1 : 0},
      where: 'arxiv_id = ?',
      whereArgs: [arxivId],
    );
  }

  /// Paged candidates for one view, ordered by the SQL [orderBy] the list
  /// provider builds. Never loads a whole year into memory.
  Future<List<Paper>> selectPage({
    required String where,
    required List<Object?> whereArgs,
    required String orderBy,
    required int limit,
    required int offset,
  }) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT p.* FROM papers p WHERE $where ORDER BY $orderBy LIMIT ? OFFSET ?',
      [...whereArgs, limit, offset],
    );
    return rows.map(Paper.fromDb).toList(growable: false);
  }

  Future<int> countWhere(String where, List<Object?> whereArgs) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM papers p WHERE $where',
      whereArgs,
    );
    return rows.isEmpty ? 0 : (rows.first['c'] as int? ?? 0);
  }

  /// Papers whose current-revision matches still lack a valid analysis
  /// projection — the "pending analysis" queue source. Validity is the
  /// SAME contract as the readers: cached row must be a success whose
  /// content hash matches the paper's current body and whose model
  /// fingerprint / prompt / result versions match the current analysis
  /// configuration. Anything else re-enters the queue.
  Future<List<Paper>> selectPendingAnalysisPapers({
    required int limit,
    required int offset,
    required String modelFingerprint,
  }) async {
    final validity = PaperAnalysisValidity(
        await PaperTaskDao().selectAll(), modelFingerprint);
    final db = await PaperDatabase.instance.database;
    final rows = await db.rawQuery(
      '''
      SELECT DISTINCT p.* FROM papers p
      JOIN paper_task_matches m ON m.arxiv_id = p.arxiv_id
      JOIN paper_tasks t ON t.task_id = m.task_id
      LEFT JOIN paper_analyses a ON a.cache_key = m.analysis_cache_key
      WHERE p.ignored = 0
        AND m.query_revision = t.query_revision
        AND NOT COALESCE((${validity.sql}), 0)
      ORDER BY p.published_at DESC, p.arxiv_id ASC
      LIMIT ? OFFSET ?
      ''',
      [...validity.arguments, limit, offset],
    );
    return rows.map(Paper.fromDb).toList(growable: false);
  }

  /// A stable scan over candidates; projection writes cannot shift its pages.
  Future<List<Paper>> selectAnalysisCandidates({
    required int limit,
    String? afterDate,
    String? afterId,
  }) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT p.* FROM papers p
      WHERE p.ignored = 0 AND EXISTS (
        SELECT 1 FROM paper_task_matches m JOIN paper_tasks t
        ON t.task_id = m.task_id AND t.query_revision = m.query_revision
        WHERE m.arxiv_id = p.arxiv_id AND t.enabled = 1)
      ${afterDate == null ? '' : 'AND (p.published_at < ? OR (p.published_at = ? AND p.arxiv_id > ?))'}
      ORDER BY p.published_at DESC, p.arxiv_id ASC LIMIT ?
    ''', [
      if (afterDate != null) ...[afterDate, afterDate, afterId],
      limit
    ]);
    return rows.map(Paper.fromDb).toList(growable: false);
  }
}

class PaperMatchDao {
  Future<List<PaperTaskMatch>> selectForPaper(String arxivId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_task_matches',
        where: 'arxiv_id = ?', whereArgs: [arxivId]);
    return rows.map(PaperTaskMatch.fromDb).toList(growable: true);
  }

  Future<void> updateScoreProjection({
    required String taskId,
    required int queryRevision,
    required String arxivId,
    required int ruleScore,
    required String? analysisCacheKey,
    int? aiScore,
  }) async {
    final db = await PaperDatabase.instance.database;
    await db.update(
      'paper_task_matches',
      <String, Object?>{
        'rule_score': ruleScore,
        'analysis_cache_key': analysisCacheKey,
        'ai_score': aiScore,
      },
      where: 'task_id = ? AND query_revision = ? AND arxiv_id = ?',
      whereArgs: [taskId, queryRevision, arxivId],
    );
  }
}

class PaperRunDao {
  Future<void> upsert(PaperRun run) async {
    final db = await PaperDatabase.instance.database;
    await db.insert('paper_runs', run.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<PaperRun?> selectById(String runId) async {
    final db = await PaperDatabase.instance.database;
    final rows =
        await db.query('paper_runs', where: 'run_id = ?', whereArgs: [runId]);
    if (rows.isEmpty) return null;
    return PaperRun.fromDb(rows.first);
  }

  Future<List<PaperRun>> selectOpen(String taskId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_runs',
        where: "task_id = ? AND status IN ('queued','running')",
        whereArgs: [taskId]);
    return rows.map(PaperRun.fromDb).toList(growable: true);
  }

  /// Mark every still-open run as interrupted (process restart recovery).
  Future<void> markOpenRunsInterrupted() async {
    final db = await PaperDatabase.instance.database;
    await db.update(
      'paper_runs',
      <String, Object?>{
        'status': PaperRunStatus.interrupted.code,
        'finished_at': DateTime.now().toUtc().toIso8601String(),
        'failure_class': 'process_exit',
      },
      where: "status IN ('queued','running')",
    );
  }
}

class PaperSliceDao {
  Future<List<PaperScanSlice>> selectOpen(String taskId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_scan_slices',
        where: "task_id = ? AND status != 'completed'", whereArgs: [taskId]);
    return rows.map(PaperScanSlice.fromDb).toList(growable: true);
  }

  Future<List<PaperScanSlice>> selectByTask(String taskId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db
        .query('paper_scan_slices', where: 'task_id = ?', whereArgs: [taskId]);
    return rows.map(PaperScanSlice.fromDb).toList(growable: true);
  }

  Future<PaperScanSlice?> selectByKey({
    required String taskId,
    required int revision,
    required PaperChannel channel,
    required String branchHash,
    required DateTime fromUtc,
    required DateTime toUtc,
  }) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_scan_slices',
        where:
            'task_id = ? AND revision = ? AND channel = ? AND branch_hash = ? AND from_utc = ? AND to_utc = ?',
        whereArgs: [
          taskId,
          revision,
          channel.code,
          branchHash,
          fromUtc.toUtc().toIso8601String(),
          toUtc.toUtc().toIso8601String(),
        ]);
    if (rows.isEmpty) return null;
    return PaperScanSlice.fromDb(rows.first);
  }

  /// Insert the slice if absent; returns the row id (existing or new).
  Future<int> ensure(PaperScanSlice slice) async {
    final db = await PaperDatabase.instance.database;
    final existing = await selectByKey(
      taskId: slice.taskId,
      revision: slice.revision,
      channel: slice.channel,
      branchHash: slice.branchHash,
      fromUtc: slice.fromUtc,
      toUtc: slice.toUtc,
    );
    if (existing != null) return existing.sliceId;
    return db.insert('paper_scan_slices', slice.toDb()..remove('slice_id'));
  }

  Future<void> update(PaperScanSlice slice) async {
    final db = await PaperDatabase.instance.database;
    await db.update('paper_scan_slices', slice.toDb(),
        where: 'slice_id = ?', whereArgs: [slice.sliceId]);
  }
}

class PaperAnalysisDao {
  Future<PaperAnalysis?> selectByKey(String cacheKey) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db
        .query('paper_analyses', where: 'cache_key = ?', whereArgs: [cacheKey]);
    if (rows.isEmpty) return null;
    return PaperAnalysis.fromDb(rows.first);
  }

  Future<void> upsert(PaperAnalysis analysis) async {
    final db = await PaperDatabase.instance.database;
    await db.insert('paper_analyses', analysis.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PaperAnalysis>> selectPending({required int limit}) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_analyses',
        where: "status IN ('pending','failed','interrupted')",
        orderBy: 'created_at ASC',
        limit: limit);
    return rows.map(PaperAnalysis.fromDb).toList(growable: true);
  }

  Future<List<PaperAnalysis>> selectSucceededForPaper(String arxivId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_analyses',
        where: "arxiv_id = ? AND status = 'succeeded'",
        whereArgs: [arxivId],
        orderBy: 'created_at DESC');
    return rows.map(PaperAnalysis.fromDb).toList(growable: true);
  }

  Future<List<PaperAnalysis>> selectAllForPaper(String arxivId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_analyses',
        where: 'arxiv_id = ?',
        whereArgs: [arxivId],
        orderBy: 'created_at DESC');
    return rows.map(PaperAnalysis.fromDb).toList(growable: true);
  }

  /// Failed/interrupted rows whose backoff has elapsed and attempts remain.
  Future<List<PaperAnalysis>> selectRetryable({
    required DateTime nowUtc,
    required int limit,
  }) async {
    final db = await PaperDatabase.instance.database;
    final now = nowUtc.toUtc().toIso8601String();
    final rows = await db.query('paper_analyses',
        where: "status IN ('failed','interrupted') "
            "AND next_retry_at IS NOT NULL AND next_retry_at <= ?",
        whereArgs: [now],
        orderBy: 'next_retry_at ASC',
        limit: limit);
    return rows.map(PaperAnalysis.fromDb).toList(growable: true);
  }
}

class PaperCitationDao {
  Future<PaperCitation?> selectById(String arxivId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db
        .query('paper_citations', where: 'arxiv_id = ?', whereArgs: [arxivId]);
    if (rows.isEmpty) return null;
    return PaperCitation.fromDb(rows.first);
  }

  Future<void> upsert(PaperCitation citation) async {
    final db = await PaperDatabase.instance.database;
    await db.insert('paper_citations', citation.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Pending work interleaved between "never tried" and "due for refresh":
  /// each queue is ordered by its due time, and the two queues alternate.
  Future<List<String>> selectPendingIds({
    required int limit,
    required DateTime nowUtc,
  }) async {
    final db = await PaperDatabase.instance.database;
    final now = nowUtc.toUtc().toIso8601String();
    final freshRows = await db.rawQuery(
      '''
      SELECT arxiv_id FROM paper_citations
      WHERE last_attempt_at IS NULL
      ORDER BY arxiv_id ASC
      LIMIT ?
      ''',
      [limit],
    );
    final refreshRows = await db.rawQuery(
      '''
      SELECT arxiv_id FROM paper_citations
      WHERE last_attempt_at IS NOT NULL
        AND next_refresh_at IS NOT NULL AND next_refresh_at <= ?
      ORDER BY next_refresh_at ASC
      LIMIT ?
      ''',
      [now, limit],
    );
    final fresh =
        freshRows.map((r) => r['arxiv_id'] as String).toList(growable: true);
    final refresh =
        refreshRows.map((r) => r['arxiv_id'] as String).toList(growable: true);
    final interleaved = <String>[];
    var i = 0;
    var j = 0;
    while (interleaved.length < limit &&
        (i < fresh.length || j < refresh.length)) {
      if (i < fresh.length) interleaved.add(fresh[i++]);
      if (interleaved.length >= limit) break;
      if (j < refresh.length) interleaved.add(refresh[j++]);
    }
    return interleaved;
  }

  /// All papers without any citation row yet (new candidates entering the
  /// statistics queue right after being saved).
  Future<List<String>> selectUncollectedIds({required int limit}) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.rawQuery(
      '''
      SELECT p.arxiv_id FROM papers p
      LEFT JOIN paper_citations c ON c.arxiv_id = p.arxiv_id
      WHERE c.arxiv_id IS NULL
      ORDER BY p.published_at DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((r) => r['arxiv_id'] as String).toList(growable: true);
  }
}

class PaperImportDao {
  Future<PaperImportRecord?> selectById(String arxivId) async {
    final db = await PaperDatabase.instance.database;
    final rows = await db
        .query('paper_imports', where: 'arxiv_id = ?', whereArgs: [arxivId]);
    if (rows.isEmpty) return null;
    return PaperImportRecord.fromDb(rows.first);
  }

  Future<List<PaperImportRecord>> selectAll() async {
    final db = await PaperDatabase.instance.database;
    final rows = await db.query('paper_imports');
    return rows.map(PaperImportRecord.fromDb).toList(growable: true);
  }

  Future<void> upsert(PaperImportRecord record) async {
    final db = await PaperDatabase.instance.database;
    await db.insert('paper_imports', record.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markOpenInterrupted() async {
    final db = await PaperDatabase.instance.database;
    await db.update(
      'paper_imports',
      <String, Object?>{
        'status': PaperImportStatus.interrupted.code,
        'finished_at': DateTime.now().toUtc().toIso8601String(),
        'failure_class': 'process_exit',
      },
      where: "status IN ('queued','downloading','downloaded','importing')",
    );
  }
}

/// One source page commit: paper upsert, discovery matches, and the slice
/// pagination checkpoint in a single paper-database transaction.
///
/// The checkpoint only advances after this transaction commits; any
/// failure rolls everything back so a page is never half-recorded.
Future<void> commitScanPage({
  required String taskId,
  required int revision,
  required PaperChannel channel,
  required String branchHash,
  required PaperScanSlice slice,
  required List<Paper> papers,
  required List<PaperTaskMatch> matches,
  required DateTime nowUtc,
}) async {
  await PaperDatabase.instance.txn((txn) async {
    for (final paper in papers) {
      final existingRows = await txn
          .query('papers', where: 'arxiv_id = ?', whereArgs: [paper.arxivId]);
      if (existingRows.isEmpty) {
        await txn.insert('papers', paper.toDb());
      } else {
        final existing = Paper.fromDb(existingRows.first);
        if (paper.latestVersion < existing.latestVersion) {
          // A late older-version response must not downgrade ANY
          // body-derived field (title/abstract/urls/hash): the row keeps
          // the newer complete snapshot and only refreshes last_seen.
          await txn.update(
            'papers',
            <String, Object?>{
              'last_seen_at': paper.lastSeenAt.toUtc().toIso8601String(),
            },
            where: 'arxiv_id = ?',
            whereArgs: [paper.arxivId],
          );
          continue;
        }
        // Same-or-newer version: adopt the complete snapshot, keeping the
        // first-seen time and user ignore state.
        final merged = paper.toDb()
          ..['first_seen_at'] = existing.firstSeenAt.toUtc().toIso8601String()
          ..['ignored'] = existing.ignored ? 1 : 0;
        await txn.update('papers', merged,
            where: 'arxiv_id = ?', whereArgs: [paper.arxivId]);
      }
    }

    for (final match in matches) {
      final existing = await txn.query('paper_task_matches',
          where: 'task_id = ? AND query_revision = ? AND arxiv_id = ?',
          whereArgs: [match.taskId, match.queryRevision, match.arxivId]);
      if (existing.isEmpty) {
        await txn.insert('paper_task_matches', match.toDb()..remove('id'));
      } else {
        final existingRow = existing.first;
        // Merge discovery evidence across branches so no reason is lost;
        // author hits keep author semantics even when seen after topic.
        final mergedEvidence = PaperTaskMatch.mergeEvidence(
          existingRow['evidence_json'] as String? ?? '{}',
          match.evidenceJson,
          incomingBranch: match.branch.code,
        );
        final existingBranch =
            PaperMatchBranch.fromCode(existingRow['branch'] as String);
        final mergedBranch = (existingBranch == PaperMatchBranch.author ||
                match.branch == PaperMatchBranch.author)
            ? PaperMatchBranch.author
            : existingBranch;
        await txn.update(
          'paper_task_matches',
          <String, Object?>{
            'last_seen_at': match.lastSeenAt.toUtc().toIso8601String(),
            'evidence_json': mergedEvidence,
            'branch': mergedBranch.code,
            'rule_score':
                match.ruleScore > (existingRow['rule_score'] as int? ?? 0)
                    ? match.ruleScore
                    : (existingRow['rule_score'] as int? ?? 0),
          },
          where: 'id = ?',
          whereArgs: [existingRow['id']],
        );
      }
    }

    await txn.update(
      'paper_scan_slices',
      <String, Object?>{
        'start_index': slice.startIndex,
        'total_reported': slice.totalReported,
        'inserted_count': slice.insertedCount,
        'status': slice.status.code,
        'last_checked_at': nowUtc.toUtc().toIso8601String(),
        'failure_class': slice.failureClass,
        'next_retry_at': slice.nextRetryAt?.toUtc().toIso8601String(),
        'source_limit': slice.sourceLimit ? 1 : 0,
      },
      where: 'slice_id = ?',
      whereArgs: [slice.sliceId],
    );
  });
}

/// Persist a successful analysis and update ONLY the score projections of
/// tasks this analysis actually covers. Other tasks' existing projections
/// keep their own cache keys — a partial merge must never erase them.
Future<void> commitAnalysisSuccess({
  required PaperAnalysis analysis,
  required List<PaperTaskMatch> matches,
}) async {
  await PaperDatabase.instance.txn((txn) async {
    final tasks =
        (await txn.query('paper_tasks')).map(PaperTask.fromDb).toList();
    await txn.insert('paper_analyses', analysis.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    for (final match in matches) {
      final current = tasks
          .where((t) =>
              t.taskId == match.taskId &&
              t.queryRevision == match.queryRevision)
          .toList();
      if (current.isEmpty) continue;
      final covered = analysis.assessments.any((assessment) =>
          assessment.taskId == match.taskId &&
          assessment.profileHash == current.first.config.semanticHash);
      if (!covered &&
          (current.first.config.wantsRelevance ||
              (analysis.titleZh ?? '').trim().isEmpty ||
              (analysis.abstractZh ?? '').trim().isEmpty)) {
        continue;
      }
      int? aiScore;
      for (final assessment in analysis.assessments) {
        if (assessment.taskId == match.taskId) {
          aiScore = assessment.relevanceScore;
          break;
        }
      }
      await txn.update(
        'paper_task_matches',
        <String, Object?>{
          'analysis_cache_key': analysis.cacheKey,
          'ai_score': aiScore,
          'rule_score': match.ruleScore,
        },
        where: 'task_id = ? AND query_revision = ? AND arxiv_id = ?',
        whereArgs: [match.taskId, match.queryRevision, match.arxivId],
      );
    }
  });
}

/// Clear stale score projections when the cached body/model no longer
/// matches; the rows fall back to the pending-analysis group.
Future<void> clearMatchProjection({
  required String taskId,
  required int queryRevision,
  required String arxivId,
}) async {
  final db = await PaperDatabase.instance.database;
  await db.update(
    'paper_task_matches',
    <String, Object?>{'analysis_cache_key': null, 'ai_score': null},
    where: 'task_id = ? AND query_revision = ? AND arxiv_id = ?',
    whereArgs: [taskId, queryRevision, arxivId],
  );
}

/// Mark every slice that was mid-scan as interrupted so recovery re-scans
/// from the first page (process-restart semantics).
Future<void> markOpenSlicesInterrupted() async {
  final db = await PaperDatabase.instance.database;
  await db.update(
    'paper_scan_slices',
    <String, Object?>{
      'status': PaperSliceStatus.interrupted.code,
      'failure_class': 'process_exit',
    },
    where: "status = 'running'",
  );
}

/// Update settings (quota) and optionally a task row atomically.
Future<void> commitSettingsAndTask({
  required PaperSettings settings,
  PaperTask? task,
}) async {
  await PaperDatabase.instance.txn((txn) async {
    await txn.update('paper_settings', settings.toDb(), where: 'id = 1');
    if (task != null) {
      await txn.insert('paper_tasks', task.toDb(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  });
}

String encodeJsonMap(Map<String, dynamic> map) => jsonEncode(map);
