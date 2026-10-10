import 'dart:convert';

import 'package:anx_reader/models/papers/paper_enums.dart';

/// Discovery record linking one task revision to one paper, with the
/// locally verifiable evidence for the hit.
class PaperTaskMatch {
  PaperTaskMatch({
    required this.id,
    required this.taskId,
    required this.queryRevision,
    required this.arxivId,
    required this.branch,
    required this.evidenceJson,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.ruleScore = 0,
    this.aiScore,
    this.analysisCacheKey,
  });

  final int id;
  final String taskId;
  final int queryRevision;
  final String arxivId;

  /// Primary branch (author when any author branch hit). All hit branches
  /// and their evidence are additionally preserved in [evidenceJson].
  final PaperMatchBranch branch;

  /// Versioned JSON: matched groups/phrases per field, the list of hit
  /// branches, and/or a marker that the source returned the entry for a
  /// branch without locally confirmable phrases.
  final String evidenceJson;
  final DateTime firstSeenAt;
  DateTime lastSeenAt;

  /// Deterministic rule score used only for pending-analysis ordering.
  int ruleScore;

  /// Rebuildable projection of the current valid AI relevance score for
  /// this task; null while pending or when the projection is stale.
  int? aiScore;

  /// Cache key of the analysis whose assessment covers this task; null
  /// while pending. Projections reference the cache row and are rebuildable.
  String? analysisCacheKey;

  static const int evidenceVersion = 1;

  static String encodeEvidence({
    required Map<String, List<String>> titlePhrases,
    required Map<String, List<String>> abstractPhrases,
    List<String>? sourceReturnedOnly,
    List<String>? branches,
  }) {
    return jsonEncode(<String, dynamic>{
      'v': evidenceVersion,
      'title': titlePhrases,
      'abstract': abstractPhrases,
      if (sourceReturnedOnly != null && sourceReturnedOnly.isNotEmpty)
        'source_returned_only': sourceReturnedOnly,
      if (branches != null && branches.isNotEmpty) 'branches': branches,
    });
  }

  /// Merge two evidence documents from different branches of the same
  /// task/revision/paper so no discovery reason is lost. Phrase groups and
  /// branch names union; source-returned markers persist until a concrete
  /// phrase for that branch is confirmed.
  static String mergeEvidence(String existingJson, String incomingJson,
      {required String incomingBranch}) {
    Map<String, dynamic> parse(String raw) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
      return <String, dynamic>{};
    }

    Map<String, List<String>> phrasesOf(Map<String, dynamic> doc, String key) {
      final raw = doc[key];
      final result = <String, List<String>>{};
      if (raw is Map) {
        for (final entry in raw.entries) {
          final values = entry.value;
          if (values is List) {
            result[entry.key.toString()] =
                values.map((e) => e.toString()).toList();
          }
        }
      }
      return result;
    }

    final a = parse(existingJson);
    final b = parse(incomingJson);

    final title = phrasesOf(a, 'title');
    for (final entry in phrasesOf(b, 'title').entries) {
      final merged = {...?title[entry.key], ...entry.value}.toList();
      title[entry.key] = merged;
    }
    final abstract = phrasesOf(a, 'abstract');
    for (final entry in phrasesOf(b, 'abstract').entries) {
      final merged = {...?abstract[entry.key], ...entry.value}.toList();
      abstract[entry.key] = merged;
    }

    String branchOf(Map<String, dynamic> doc) {
      final raw = doc['branches'];
      if (raw is List) return raw.map((e) => e.toString()).toList().join(',');
      return '';
    }

    final branches = <String>{};
    for (final name in [
      ...branchOf(a).split(','),
      ...branchOf(b).split(','),
      incomingBranch,
    ]) {
      if (name.trim().isNotEmpty) branches.add(name.trim());
    }

    final sourceOnly = <String>{};
    for (final doc in [a, b]) {
      final raw = doc['source_returned_only'];
      if (raw is List) {
        sourceOnly.addAll(raw.map((e) => e.toString()));
      }
    }

    return encodeEvidence(
      titlePhrases: title,
      abstractPhrases: abstract,
      sourceReturnedOnly: sourceOnly.isEmpty ? null : sourceOnly.toList(),
      branches: branches.toList(),
    );
  }

  factory PaperTaskMatch.fromDb(Map<String, dynamic> row) {
    return PaperTaskMatch(
      id: row['id'] as int,
      taskId: row['task_id'] as String,
      queryRevision: row['query_revision'] as int,
      arxivId: row['arxiv_id'] as String,
      branch: PaperMatchBranch.fromCode(row['branch'] as String),
      evidenceJson: row['evidence_json'] as String,
      firstSeenAt: DateTime.parse(row['first_seen_at'] as String),
      lastSeenAt: DateTime.parse(row['last_seen_at'] as String),
      ruleScore: row['rule_score'] as int? ?? 0,
      aiScore: row['ai_score'] as int?,
      analysisCacheKey: row['analysis_cache_key'] as String?,
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'id': id,
        'task_id': taskId,
        'query_revision': queryRevision,
        'arxiv_id': arxivId,
        'branch': branch.code,
        'evidence_json': evidenceJson,
        'first_seen_at': firstSeenAt.toUtc().toIso8601String(),
        'last_seen_at': lastSeenAt.toUtc().toIso8601String(),
        'rule_score': ruleScore,
        'ai_score': aiScore,
        'analysis_cache_key': analysisCacheKey,
      };
}

class PaperRun {
  PaperRun({
    required this.runId,
    required this.taskId,
    required this.queryRevision,
    required this.trigger,
    required this.configSnapshotJson,
    required this.rangeJson,
    required this.status,
    required this.startedAt,
    this.finishedAt,
    this.failureClass,
    this.execToken = 0,
    this.phaseCountsJson,
  });

  final String runId;
  final String taskId;
  final int queryRevision;
  final PaperRunTrigger trigger;

  /// Task config snapshot used for the whole run; pagination never mixes
  /// two revisions.
  final String configSnapshotJson;

  /// Resolved time ranges for both channels at run start.
  final String rangeJson;
  PaperRunStatus status;
  final DateTime startedAt;
  DateTime? finishedAt;
  String? failureClass;

  /// Execution token; pausing the task increments it so late responses
  /// from an old run cannot advance state.
  int execToken;
  String? phaseCountsJson;

  factory PaperRun.fromDb(Map<String, dynamic> row) {
    return PaperRun(
      runId: row['run_id'] as String,
      taskId: row['task_id'] as String,
      queryRevision: row['query_revision'] as int,
      trigger: PaperRunTrigger.fromCode(row['trigger'] as String),
      configSnapshotJson: row['config_snapshot'] as String,
      rangeJson: row['range_json'] as String,
      status: PaperRunStatus.fromCode(row['status'] as String),
      startedAt: DateTime.parse(row['started_at'] as String),
      finishedAt: row['finished_at'] == null
          ? null
          : DateTime.parse(row['finished_at'] as String),
      failureClass: row['failure_class'] as String?,
      execToken: row['exec_token'] as int? ?? 0,
      phaseCountsJson: row['phase_counts'] as String?,
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'run_id': runId,
        'task_id': taskId,
        'query_revision': queryRevision,
        'trigger': trigger.code,
        'config_snapshot': configSnapshotJson,
        'range_json': rangeJson,
        'status': status.code,
        'started_at': startedAt.toUtc().toIso8601String(),
        'finished_at': finishedAt?.toUtc().toIso8601String(),
        'failure_class': failureClass,
        'exec_token': execToken,
        'phase_counts': phaseCountsJson,
      };
}

/// One resumable time slice of a scan.
class PaperScanSlice {
  PaperScanSlice({
    required this.sliceId,
    required this.taskId,
    required this.revision,
    required this.channel,
    required this.branchHash,
    required this.fromUtc,
    required this.toUtc,
    required this.requestQuery,
    required this.status,
    this.startIndex = 0,
    this.totalReported,
    this.insertedCount = 0,
    this.lastCheckedAt,
    this.failureClass,
    this.nextRetryAt,
    this.sourceLimit = false,
  });

  final int sliceId;
  final String taskId;
  final int revision;
  final PaperChannel channel;
  final String branchHash;
  final DateTime fromUtc;
  final DateTime toUtc;

  /// The actual arXiv `search_query` string used for this slice.
  final String requestQuery;

  /// Next page offset. Advances only after a page transaction commits.
  int startIndex;

  /// `opensearch:totalResults` from the latest response; informational.
  int? totalReported;
  int insertedCount;
  PaperSliceStatus status;
  DateTime? lastCheckedAt;
  String? failureClass;
  DateTime? nextRetryAt;

  /// Set when the slice cannot be traversed completely even at the
  /// smallest granularity; coverage must not claim completion for it.
  bool sourceLimit;

  factory PaperScanSlice.fromDb(Map<String, dynamic> row) {
    return PaperScanSlice(
      sliceId: row['slice_id'] as int,
      taskId: row['task_id'] as String,
      revision: row['revision'] as int,
      channel: PaperChannel.fromCode(row['channel'] as String),
      branchHash: row['branch_hash'] as String,
      fromUtc: DateTime.parse(row['from_utc'] as String),
      toUtc: DateTime.parse(row['to_utc'] as String),
      requestQuery: row['request_query'] as String,
      status: PaperSliceStatus.fromCode(row['status'] as String),
      startIndex: row['start_index'] as int? ?? 0,
      totalReported: row['total_reported'] as int?,
      insertedCount: row['inserted_count'] as int? ?? 0,
      lastCheckedAt: row['last_checked_at'] == null
          ? null
          : DateTime.parse(row['last_checked_at'] as String),
      failureClass: row['failure_class'] as String?,
      nextRetryAt: row['next_retry_at'] == null
          ? null
          : DateTime.parse(row['next_retry_at'] as String),
      sourceLimit: (row['source_limit'] as int? ?? 0) == 1,
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'slice_id': sliceId,
        'task_id': taskId,
        'revision': revision,
        'channel': channel.code,
        'branch_hash': branchHash,
        'from_utc': fromUtc.toUtc().toIso8601String(),
        'to_utc': toUtc.toUtc().toIso8601String(),
        'request_query': requestQuery,
        'start_index': startIndex,
        'total_reported': totalReported,
        'inserted_count': insertedCount,
        'status': status.code,
        'last_checked_at': lastCheckedAt?.toUtc().toIso8601String(),
        'failure_class': failureClass,
        'next_retry_at': nextRetryAt?.toUtc().toIso8601String(),
        'source_limit': sourceLimit ? 1 : 0,
      };
}

class PaperAssessment {
  const PaperAssessment({
    required this.taskId,
    required this.profileHash,
    required this.relevanceScore,
    required this.reasonZh,
    required this.evidence,
  });

  final String taskId;
  final String profileHash;

  /// 0..100.
  final int relevanceScore;
  final String reasonZh;

  /// Each entry: field ("title"|"abstract") + verbatim quote that must be a
  /// real contiguous fragment of the paper text.
  final List<PaperEvidenceQuote> evidence;

  static const int jsonVersion = 1;

  factory PaperAssessment.fromJson(Map<String, dynamic> json) {
    final version = json['v'] as int? ?? 1;
    if (version != jsonVersion) {
      throw FormatException('Unsupported assessment version: $version');
    }
    final taskId = json['task_id'] as String? ?? '';
    if (taskId.isEmpty) {
      throw FormatException('Assessment requires task_id');
    }
    final score = json['relevance_score'];
    if (score is! int || score < 0 || score > 100) {
      throw FormatException('relevance_score must be int 0..100');
    }
    final rawEvidence = json['evidence'];
    final evidence = rawEvidence is List
        ? rawEvidence
            .map((e) => PaperEvidenceQuote.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList(growable: false)
        : const <PaperEvidenceQuote>[];
    return PaperAssessment(
      taskId: taskId,
      profileHash: json['profile_hash'] as String? ?? '',
      relevanceScore: score,
      reasonZh: json['reason_zh'] as String? ?? '',
      evidence: evidence,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': jsonVersion,
        'task_id': taskId,
        'profile_hash': profileHash,
        'relevance_score': relevanceScore,
        'reason_zh': reasonZh,
        'evidence': evidence.map((e) => e.toJson()).toList(growable: false),
      };
}

class PaperEvidenceQuote {
  const PaperEvidenceQuote({required this.field, required this.quote});

  /// "title" or "abstract".
  final String field;
  final String quote;

  factory PaperEvidenceQuote.fromJson(Map<String, dynamic> json) {
    final field = json['field'] as String? ?? '';
    if (field != 'title' && field != 'abstract') {
      throw FormatException('Unsupported evidence field: $field');
    }
    final quote = json['quote'] as String? ?? '';
    if (quote.isEmpty) {
      throw FormatException('Evidence quote must not be empty');
    }
    return PaperEvidenceQuote(field: field, quote: quote);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'field': field,
        'quote': quote,
      };
}

/// Versioned analysis result stored with a cache key.
class PaperAnalysis {
  PaperAnalysis({
    required this.cacheKey,
    required this.arxivId,
    required this.contentHash,
    required this.modelFingerprint,
    required this.promptVersion,
    required this.resultVersion,
    required this.assessments,
    required this.status,
    required this.createdAt,
    this.titleZh,
    this.abstractZh,
    this.attempt = 0,
    this.quotaDay,
    this.startedAt,
    this.finishedAt,
    this.failureClass,
    this.nextRetryAt,
  });

  final String cacheKey;
  final String arxivId;

  /// Body fingerprint the result was computed from. A row is only valid for
  /// reuse while this matches the paper's current content hash.
  final String contentHash;

  /// Service id / protocol / URL / model / reasoning config fingerprint.
  /// Never contains API keys.
  final String modelFingerprint;
  final int promptVersion;
  final int resultVersion;
  final String? titleZh;
  final String? abstractZh;
  final List<PaperAssessment> assessments;
  PaperAnalysisStatus status;
  int attempt;
  String? quotaDay;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? failureClass;

  /// Failed analyses are retried with backoff instead of every tick.
  DateTime? nextRetryAt;

  static const int resultSchemaVersion = 1;

  factory PaperAnalysis.fromDb(Map<String, dynamic> row) {
    final raw = jsonDecode(row['assessments_json'] as String);
    if (raw is! List) {
      throw FormatException('assessments_json must be a list');
    }
    return PaperAnalysis(
      cacheKey: row['cache_key'] as String,
      arxivId: row['arxiv_id'] as String,
      contentHash: row['content_hash'] as String? ?? '',
      modelFingerprint: row['model_fingerprint'] as String,
      promptVersion: row['prompt_version'] as int,
      resultVersion: row['result_version'] as int,
      titleZh: row['title_zh'] as String?,
      abstractZh: row['abstract_zh'] as String?,
      assessments: raw
          .map((e) =>
              PaperAssessment.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false),
      status: PaperAnalysisStatus.fromCode(row['status'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
      attempt: row['attempt'] as int? ?? 0,
      quotaDay: row['quota_day'] as String?,
      startedAt: row['started_at'] == null
          ? null
          : DateTime.parse(row['started_at'] as String),
      finishedAt: row['finished_at'] == null
          ? null
          : DateTime.parse(row['finished_at'] as String),
      failureClass: row['failure_class'] as String?,
      nextRetryAt: row['next_retry_at'] == null
          ? null
          : DateTime.parse(row['next_retry_at'] as String),
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'cache_key': cacheKey,
        'arxiv_id': arxivId,
        'content_hash': contentHash,
        'model_fingerprint': modelFingerprint,
        'prompt_version': promptVersion,
        'result_version': resultVersion,
        'title_zh': titleZh,
        'abstract_zh': abstractZh,
        'assessments_json': jsonEncode(
            assessments.map((a) => a.toJson()).toList(growable: false)),
        'status': status.code,
        'attempt': attempt,
        'quota_day': quotaDay,
        'created_at': createdAt.toUtc().toIso8601String(),
        'started_at': startedAt?.toUtc().toIso8601String(),
        'finished_at': finishedAt?.toUtc().toIso8601String(),
        'failure_class': failureClass,
        'next_retry_at': nextRetryAt?.toUtc().toIso8601String(),
      };
}

/// Citation statistics from a single provider (Semantic Scholar in v1).
///
/// [citationCount] null means unknown (not collected / not matched). A
/// successful `citationCount: 0` is stored as 0 with a success time and is
/// distinct from unknown.
class PaperCitation {
  PaperCitation({
    required this.arxivId,
    required this.provider,
    this.providerPaperId,
    this.citationCount,
    this.lastSuccessAt,
    this.lastAttemptAt,
    this.lastError,
    this.nextRefreshAt,
  }) {
    if (citationCount != null && lastSuccessAt == null) {
      throw ArgumentError('citation count requires lastSuccessAt');
    }
    if (citationCount != null && citationCount! < 0) {
      throw ArgumentError('citation count must be non-negative');
    }
  }

  final String arxivId;
  final String provider;
  String? providerPaperId;
  int? citationCount;
  DateTime? lastSuccessAt;
  DateTime? lastAttemptAt;
  String? lastError;
  DateTime? nextRefreshAt;

  /// A previously successful value that failed to refresh on the last
  /// attempt; shown as stale, never reset to zero or cleared.
  bool get isStale =>
      lastSuccessAt != null &&
      lastError != null &&
      (lastAttemptAt?.isAfter(lastSuccessAt!) ?? false);

  bool get isUnknown => citationCount == null;

  factory PaperCitation.fromDb(Map<String, dynamic> row) {
    return PaperCitation(
      arxivId: row['arxiv_id'] as String,
      provider: row['provider'] as String? ?? 'semantic_scholar',
      providerPaperId: row['provider_paper_id'] as String?,
      citationCount: row['citation_count'] as int?,
      lastSuccessAt: row['last_success_at'] == null
          ? null
          : DateTime.parse(row['last_success_at'] as String),
      lastAttemptAt: row['last_attempt_at'] == null
          ? null
          : DateTime.parse(row['last_attempt_at'] as String),
      lastError: row['last_error'] as String?,
      nextRefreshAt: row['next_refresh_at'] == null
          ? null
          : DateTime.parse(row['next_refresh_at'] as String),
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'arxiv_id': arxivId,
        'provider': provider,
        'provider_paper_id': providerPaperId,
        'citation_count': citationCount,
        'last_success_at': lastSuccessAt?.toUtc().toIso8601String(),
        'last_attempt_at': lastAttemptAt?.toUtc().toIso8601String(),
        'last_error': lastError,
        'next_refresh_at': nextRefreshAt?.toUtc().toIso8601String(),
      };
}

class PaperImportRecord {
  PaperImportRecord({
    required this.arxivId,
    required this.downloadVersion,
    required this.requestId,
    required this.status,
    required this.startedAt,
    this.cacheRelPath,
    this.pdfMd5,
    this.bookId,
    this.bookFilePath,
    this.attempt = 0,
    this.finishedAt,
    this.failureClass,
  });

  final String arxivId;

  /// Version fixed at user-selection time; the download never silently
  /// switches to a newer version.
  final int downloadVersion;
  final String requestId;
  PaperImportStatus status;
  String? cacheRelPath;
  String? pdfMd5;
  int? bookId;
  String? bookFilePath;
  int attempt;
  final DateTime startedAt;
  DateTime? finishedAt;
  String? failureClass;

  factory PaperImportRecord.fromDb(Map<String, dynamic> row) {
    return PaperImportRecord(
      arxivId: row['arxiv_id'] as String,
      downloadVersion: row['download_version'] as int,
      requestId: row['request_id'] as String,
      status: PaperImportStatus.fromCode(row['status'] as String),
      cacheRelPath: row['cache_rel_path'] as String?,
      pdfMd5: row['pdf_md5'] as String?,
      bookId: row['book_id'] as int?,
      bookFilePath: row['book_file_path'] as String?,
      attempt: row['attempt'] as int? ?? 0,
      startedAt: row['started_at'] == null
          ? DateTime.now()
          : DateTime.parse(row['started_at'] as String),
      finishedAt: row['finished_at'] == null
          ? null
          : DateTime.parse(row['finished_at'] as String),
      failureClass: row['failure_class'] as String?,
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'arxiv_id': arxivId,
        'download_version': downloadVersion,
        'request_id': requestId,
        'status': status.code,
        'cache_rel_path': cacheRelPath,
        'pdf_md5': pdfMd5,
        'book_id': bookId,
        'book_file_path': bookFilePath,
        'attempt': attempt,
        'started_at': startedAt.toUtc().toIso8601String(),
        'finished_at': finishedAt?.toUtc().toIso8601String(),
        'failure_class': failureClass,
      };
}

/// Singleton row of module-wide settings and quota state.
class PaperSettings {
  PaperSettings({
    this.dailyLimit = 100,
    required this.quotaDay,
    this.reservedCount = 0,
    this.analysisProviderId,
    this.analysisModelOverride,
    this.pollerCursorJson,
    this.configVersion = 1,
  });

  int dailyLimit;

  /// UTC calendar day `YYYY-MM-DD` that [reservedCount] belongs to.
  String quotaDay;
  int reservedCount;
  String? analysisProviderId;
  String? analysisModelOverride;
  String? pollerCursorJson;
  int configVersion;

  static const int currentConfigVersion = 1;

  static String quotaDayOf(DateTime utcNow) {
    final now = utcNow.toUtc();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  factory PaperSettings.fromDb(Map<String, dynamic> row) {
    return PaperSettings(
      dailyLimit: row['daily_limit'] as int? ?? 100,
      quotaDay: row['quota_day'] as String,
      reservedCount: row['reserved_count'] as int? ?? 0,
      analysisProviderId: row['analysis_provider_id'] as String?,
      analysisModelOverride: row['analysis_model_override'] as String?,
      pollerCursorJson: row['poller_cursor'] as String?,
      configVersion: row['config_version'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'id': 1,
        'daily_limit': dailyLimit,
        'quota_day': quotaDay,
        'reserved_count': reservedCount,
        'analysis_provider_id': analysisProviderId,
        'analysis_model_override': analysisModelOverride,
        'poller_cursor': pollerCursorJson,
        'config_version': configVersion,
      };
}
