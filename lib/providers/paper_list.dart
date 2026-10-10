import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/service/papers/analysis_service.dart'
    show currentAnalysisModelFingerprint, isCurrentAnalysis;
import 'package:anx_reader/service/papers/collection_service.dart'
    show subtractCalendarMonths;
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum PaperListView { latest, hot, tasks }

enum PaperListSort {
  /// Latest view default: relevance (AI score first, pending by rule score).
  relevance,

  /// Latest view alternate: first submission time.
  newest,

  /// Hot view default: cumulative citation count.
  citations,
}

enum PaperListFilter {
  all,
  pendingAnalysis,
  lowRelevance,
  ignored,
  imported,
}

/// One rendered row: paper plus the display state computed at query time.
class PaperListItem {
  const PaperListItem({
    required this.paper,
    required this.ruleScore,
    required this.aiScore,
    required this.assessmentPending,
    required this.assessmentTaskName,
    required this.citationCount,
    required this.citationUnknown,
    required this.citationStale,
    required this.imported,
    required this.authorWatch,
    required this.lowRelevance,
    required this.taskNames,
  });

  final Paper paper;
  final int ruleScore;
  final int? aiScore;
  final bool assessmentPending;
  final String? assessmentTaskName;
  final int? citationCount;
  final bool citationUnknown;
  final bool citationStale;
  final bool imported;
  final bool authorWatch;
  final bool lowRelevance;
  final List<String> taskNames;
}

class PaperListQuery {
  const PaperListQuery({
    this.view = PaperListView.latest,
    this.sort = PaperListSort.relevance,
    this.filter = PaperListFilter.all,
    this.taskId,
    this.searchText = '',
    this.pageSize = 50,
    this.showLowRelevance = false,
    this.latestWindowDays = 30,
    this.hotWindowMonths = 12,
  });

  final PaperListView view;
  final PaperListSort sort;
  final PaperListFilter filter;
  final String? taskId;

  /// Local filter over already discovered candidates; not a new source
  /// query. Pagination only affects rendering.
  final String searchText;
  final int pageSize;

  /// Low-relevance candidates stay in the result set; the flag only
  /// controls whether the default list shows them (counts are always kept).
  final bool showLowRelevance;

  /// User-adjustable task windows that shape the view predicate.
  final int latestWindowDays;
  final int hotWindowMonths;

  @override
  bool operator ==(Object other) =>
      other is PaperListQuery &&
      other.view == view &&
      other.sort == sort &&
      other.filter == filter &&
      other.taskId == taskId &&
      other.searchText == searchText &&
      other.pageSize == pageSize &&
      other.showLowRelevance == showLowRelevance &&
      other.latestWindowDays == latestWindowDays &&
      other.hotWindowMonths == hotWindowMonths;

  @override
  int get hashCode => Object.hash(view, sort, filter, taskId, searchText,
      pageSize, showLowRelevance, latestWindowDays, hotWindowMonths);
}

class PaperListResult {
  const PaperListResult({
    required this.items,
    required this.lowRelevanceItems,
    required this.totalCount,
    required this.lowRelevanceCount,
    required this.pendingCount,
    required this.hasMore,
  });

  /// Default-visible candidates (low-relevance excluded unless requested).
  final List<PaperListItem> items;

  /// Low-relevance group: hidden from the default list but always counted
  /// and reachable; author-watch results are never hidden.
  final List<PaperListItem> lowRelevanceItems;
  final int totalCount;
  final int lowRelevanceCount;
  final int pendingCount;
  final bool hasMore;
}

/// Paged candidate queries with a global sort applied in SQL before paging,
/// so a high-value older candidate can still reach the first page. Sorting
/// uses the rebuildable `ai_score` projection, rule score and the citation
/// join; pagination never loads a whole year into memory.
class PaperListNotifier
    extends FamilyAsyncNotifier<PaperListResult, PaperListQuery> {
  int _offset = 0;
  final List<PaperListItem> _accumulated = [];
  final List<PaperListItem> _lowAccumulated = [];

  /// Request generation: a refresh bumps it so an older in-flight page can
  /// never mutate the current pagination state (F14).
  int _generation = 0;
  bool _loading = false;

  static const double lowRelevanceThreshold = 40;

  PaperListQuery get _query => arg;

  @override
  Future<PaperListResult> build(PaperListQuery arg) async {
    _offset = 0;
    _accumulated.clear();
    _lowAccumulated.clear();
    _generation++;
    ref.onDispose(() => _generation++);
    return _loadPage();
  }

  String get _orderBy {
    switch (_query.sort) {
      case PaperListSort.newest:
        return 'p.published_at DESC, p.arxiv_id ASC';
      case PaperListSort.relevance:
        // Valid AI scores first (desc), then pending by rule score; stable
        // tie-breakers per design.
        return 'CASE WHEN x.ai_score IS NULL THEN 1 ELSE 0 END ASC, '
            'x.ai_score DESC, x.rule_score DESC, '
            'p.published_at DESC, p.arxiv_id ASC';
      case PaperListSort.citations:
        // Known counts above unknown; stale values participate but marked.
        return 'CASE WHEN c.citation_count IS NULL THEN 1 ELSE 0 END ASC, '
            'c.citation_count DESC, x.rule_score DESC, '
            'p.published_at DESC, p.arxiv_id ASC';
    }
  }

  /// Window predicate computed from the user's adjustable windows. Times
  /// compare in the same ISO format the papers table stores. Calendar
  /// months use the shared end-of-month-clamped subtraction.
  String get _windowPredicate {
    final now = DateTime.now().toUtc();
    if (_query.view == PaperListView.latest) {
      final from = now.subtract(Duration(days: _query.latestWindowDays));
      return "p.published_at >= '${from.toIso8601String()}'";
    }
    final from = subtractCalendarMonths(now, _query.hotWindowMonths);
    return "p.published_at >= '${from.toIso8601String()}'";
  }

  Future<PaperListResult> _loadPage() async {
    final int generation = _generation;
    // One validity contract everywhere: cache row must match body, model,
    // prompt/result versions and be a success.
    final modelFingerprint = await currentAnalysisModelFingerprint();
    final validity = PaperAnalysisValidity(
        await PaperTaskDao().selectAll(), modelFingerprint);
    final where = <String>[];
    final args = <Object?>[];

    switch (_query.filter) {
      case PaperListFilter.all:
        where.add('p.ignored = 0');
        break;
      case PaperListFilter.ignored:
        where.add('p.ignored = 1');
        break;
      case PaperListFilter.imported:
        where.add(
            "EXISTS (SELECT 1 FROM paper_imports i WHERE i.arxiv_id = p.arxiv_id AND i.status = 'imported')");
        break;
      case PaperListFilter.pendingAnalysis:
        where.add('p.ignored = 0');
        where.add('x.complete = 0');
        break;
      case PaperListFilter.lowRelevance:
        // The low-relevance filter IS the low-score group: restrict in SQL
        // instead of returning the full list.
        where.add('p.ignored = 0');
        where.add('x.ai_score IS NOT NULL AND x.ai_score < 40');
        break;
    }

    if (_query.searchText.trim().isNotEmpty) {
      final needle = '%${_query.searchText.trim()}%';
      where.add(
          '(p.title LIKE ? OR p.abstract LIKE ? OR p.authors_json LIKE ?)');
      args.add(needle);
      args.add(needle);
      args.add(needle);
    }

    where.add(_windowPredicate);

    // Current-revision discovery only: a paper whose task has been revised
    // but has no current-revision match is history, not a current candidate.
    where.add('EXISTS (SELECT 1 FROM paper_task_matches mc '
        'JOIN paper_tasks tc ON tc.task_id = mc.task_id '
        'WHERE mc.arxiv_id = p.arxiv_id '
        'AND mc.query_revision = tc.query_revision)');

    // Sort/aggregate projection restricted to the CURRENT revision and to
    // projections whose cache row matches the current body AND the current
    // model/prompt/result configuration — so the rank and the card always
    // show the same effective score.
    final baseSql = '''
      FROM papers p
      LEFT JOIN paper_citations c ON c.arxiv_id = p.arxiv_id
      LEFT JOIN (
        SELECT arxiv_id,
               MAX(CASE WHEN match_valid = 1 THEN ai_score END) AS ai_score,
               MAX(rule_score) AS rule_score, MIN(match_valid) AS complete
        FROM (
          SELECT m.arxiv_id, m.ai_score, m.rule_score,
            CASE WHEN ${validity.sql} THEN 1 ELSE 0 END AS match_valid
          FROM paper_task_matches m
          JOIN paper_tasks t ON t.task_id = m.task_id
            AND m.query_revision = t.query_revision
          JOIN papers p ON p.arxiv_id = m.arxiv_id
          LEFT JOIN paper_analyses a ON a.cache_key = m.analysis_cache_key
          ${_query.taskId != null ? 'WHERE m.task_id = ?' : ''}
        ) GROUP BY arxiv_id
      ) x ON x.arxiv_id = p.arxiv_id
      WHERE ${where.join(' AND ')}
        ${_query.taskId != null ? 'AND x.arxiv_id IS NOT NULL' : ''}
    ''';

    final sqlArgs = <Object?>[
      ...validity.arguments,
      if (_query.taskId != null) _query.taskId,
      ...args,
    ];

    final orderBy = _orderBy;
    final rows = await PaperDao().rawQueryList(
      'SELECT p.*, c.citation_count, c.last_success_at, c.last_attempt_at, c.last_error, '
      'x.ai_score AS x_ai_score, x.rule_score AS x_rule_score, x.complete AS x_complete '
      '$baseSql ORDER BY $orderBy LIMIT ? OFFSET ?',
      arguments: [...sqlArgs, _query.pageSize, _offset],
      mapper: (row) => row,
    );

    final items = <PaperListItem>[];
    for (final row in rows) {
      items.add(await _decorate(row, modelFingerprint));
    }

    // Low relevance is grouped out of the default list but never dropped
    // from the result: counts and the entry stay available across pages.
    final visible = <PaperListItem>[];
    final low = <PaperListItem>[];
    for (final item in items) {
      final isLow = item.lowRelevance && !item.authorWatch;
      final hideForLow = isLow &&
          !_query.showLowRelevance &&
          _query.filter != PaperListFilter.lowRelevance &&
          _query.filter != PaperListFilter.ignored;
      if (hideForLow) {
        low.add(item);
      } else {
        visible.add(item);
      }
    }

    // Discard results from a stale generation (refresh superseded us).
    if (generation != _generation) {
      return _currentResultOrEmpty();
    }

    // Counts cover the FULL matching set, not just the loaded page.
    final totalRows = await PaperDao().rawQueryList(
      'SELECT COUNT(*) AS c $baseSql',
      arguments: sqlArgs,
      mapper: (row) => row,
    );
    final total = totalRows.isEmpty ? 0 : (totalRows.first['c'] as int? ?? 0);
    final lowRows = await PaperDao().rawQueryList(
      "SELECT COUNT(*) AS c $baseSql AND x.ai_score IS NOT NULL "
      "AND x.ai_score < 40",
      arguments: sqlArgs,
      mapper: (row) => row,
    );
    final lowTotal = lowRows.isEmpty ? 0 : (lowRows.first['c'] as int? ?? 0);
    final pendingRows = await PaperDao().rawQueryList(
      'SELECT COUNT(*) AS c $baseSql AND x.complete = 0',
      arguments: sqlArgs,
      mapper: (row) => row,
    );
    final pendingTotal =
        pendingRows.isEmpty ? 0 : (pendingRows.first['c'] as int? ?? 0);

    if (generation != _generation) return _currentResultOrEmpty();
    _accumulated.addAll(visible);
    _lowAccumulated.addAll(low);
    _offset += rows.length;

    return PaperListResult(
      items: List.unmodifiable(_accumulated),
      lowRelevanceItems: List.unmodifiable(_lowAccumulated),
      totalCount: total,
      lowRelevanceCount: lowTotal,
      pendingCount: pendingTotal,
      hasMore: _offset < total,
    );
  }

  PaperListResult _currentResultOrEmpty() {
    final current = state.valueOrNull;
    return current ??
        const PaperListResult(
          items: [],
          lowRelevanceItems: [],
          totalCount: 0,
          lowRelevanceCount: 0,
          pendingCount: 0,
          hasMore: false,
        );
  }

  Future<PaperListItem> _decorate(
      Map<String, dynamic> row, String modelFingerprint) async {
    final paper = Paper.fromDb(row);

    // Only current-revision matches participate in the displayed scores.
    final matches = await PaperMatchDao().selectForPaper(paper.arxivId);
    var ruleScore = 0;
    int? aiScore;
    String? assessmentTaskName;
    var pending = (row['x_complete'] as int? ?? 0) == 0;
    var authorWatch = false;
    final taskNames = <String>[];
    for (final match in matches) {
      if (_query.taskId != null && match.taskId != _query.taskId) continue;
      final task = await PaperTaskDao().selectById(match.taskId);
      if (task == null) continue;
      if (task.queryRevision != match.queryRevision) {
        // Stale-revision discovery does not contribute current scores.
        continue;
      }
      if (match.ruleScore > ruleScore) ruleScore = match.ruleScore;
      if (match.branch == PaperMatchBranch.author) authorWatch = true;
      if (!taskNames.contains(task.name)) taskNames.add(task.name);

      if (match.analysisCacheKey != null && match.aiScore != null) {
        final analysis =
            await PaperAnalysisDao().selectByKey(match.analysisCacheKey!);
        // SAME validity contract as the SQL aggregate and the detail page.
        final valid = analysis != null &&
            isCurrentAnalysis(analysis, paper, modelFingerprint) &&
            analysis.assessments.any((a) =>
                a.taskId == task.taskId &&
                a.profileHash == task.config.semanticHash);
        if (valid) {
          final score = match.aiScore!;
          if (aiScore == null || score > aiScore) {
            aiScore = score;
            assessmentTaskName = task.name;
          }
        }
      }
    }

    final citationUnknown = row['citation_count'] == null;
    final citationCount = row['citation_count'] as int?;
    final lastSuccess = row['last_success_at'] == null
        ? null
        : DateTime.parse(row['last_success_at'] as String);
    final lastAttempt = row['last_attempt_at'] == null
        ? null
        : DateTime.parse(row['last_attempt_at'] as String);
    final citationStale = lastSuccess != null &&
        row['last_error'] != null &&
        (lastAttempt?.isAfter(lastSuccess) ?? false);

    final importRecord = await PaperImportDao().selectById(paper.arxivId);

    final lowRelevance = aiScore != null && aiScore < lowRelevanceThreshold;

    return PaperListItem(
      paper: paper,
      ruleScore: ruleScore,
      aiScore: aiScore,
      assessmentPending: pending,
      assessmentTaskName: assessmentTaskName,
      citationCount: citationCount,
      citationUnknown: citationUnknown,
      citationStale: citationStale,
      imported: importRecord?.status == PaperImportStatus.imported,
      authorWatch: authorWatch,
      lowRelevance: lowRelevance,
      taskNames: taskNames,
    );
  }

  Future<void> loadMore() async {
    if (_loading) return;
    final int generation = _generation;
    _loading = true;
    try {
      final result = await _loadPage();
      // Only the current generation may publish.
      if (generation == _generation) {
        state = AsyncData(result);
      }
    } catch (e, s) {
      if (generation == _generation) {
        state = AsyncError(e, s);
      }
    } finally {
      if (generation == _generation) {
        _loading = false;
      }
    }
  }

  Future<void> refresh() async {
    final int generation = ++_generation;
    _offset = 0;
    _accumulated.clear();
    _lowAccumulated.clear();
    state = const AsyncLoading();
    _loading = true;
    try {
      final result = await _loadPage();
      if (generation == _generation) {
        state = AsyncData(result);
      }
    } catch (e, s) {
      if (generation == _generation) {
        state = AsyncError(e, s);
      }
    } finally {
      if (generation == _generation) {
        _loading = false;
      }
    }
  }
}

final paperListProvider = AsyncNotifierProvider.family<PaperListNotifier,
    PaperListResult, PaperListQuery>(PaperListNotifier.new);
