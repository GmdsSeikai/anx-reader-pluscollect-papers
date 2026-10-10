import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/service/papers/semantic_scholar_client.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:dio/dio.dart';

/// Fills in citation statistics for new candidates and refreshes existing
/// values. Failures never block candidate display or downloads.
class CitationService {
  CitationService({
    SemanticScholarClient? client,
    DateTime Function()? nowUtc,
  })  : _client = client ??
            SemanticScholarClient(
              // Read the key per request so settings edits take effect
              // without reconstructing the service.
              keyProvider: () => Prefs().semanticScholarApiKey,
            ),
        _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final SemanticScholarClient _client;
  final DateTime Function() _nowUtc;
  int _cancelGeneration = 0;

  void cancel() {
    _cancelGeneration++;
    _client.cancelActiveRequests();
  }

  /// Process one batch: never-tried candidates and due refreshes are taken
  /// alternately so a large historical refresh cannot starve new papers.
  Future<void> drainBatch({
    required int maxItems,
    required DateTime nowUtc,
  }) async {
    final generation = _cancelGeneration;
    final dao = PaperCitationDao();

    // New candidates enter the statistics queue as soon as they are saved;
    // no PDF download is required first.
    final uncollected = await dao.selectUncollectedIds(limit: maxItems);
    for (final id in uncollected) {
      await dao
          .upsert(PaperCitation(arxivId: id, provider: 'semantic_scholar'));
    }

    final pendingIds = await dao.selectPendingIds(
      limit: maxItems,
      nowUtc: nowUtc,
    );
    if (pendingIds.isEmpty) return;
    if (generation != _cancelGeneration) return;

    final List<CitationLookupResult> results;
    try {
      results = await _client.lookup(pendingIds);
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) return;
      for (final id in pendingIds) {
        final previous = await dao.selectById(id);
        await dao.upsert(PaperCitation(
            arxivId: id,
            provider: previous?.provider ?? 'semantic_scholar',
            providerPaperId: previous?.providerPaperId,
            citationCount: previous?.citationCount,
            lastSuccessAt: previous?.lastSuccessAt,
            lastAttemptAt: nowUtc,
            lastError: 'request_failed',
            nextRefreshAt: nowUtc.add(const Duration(hours: 24))));
      }
      return;
    }

    for (var i = 0; i < pendingIds.length; i++) {
      final arxivId = pendingIds[i];
      final result = results[i];
      final existing = await dao.selectById(arxivId);
      final updated = applyCitationResult(
        existing: existing,
        arxivId: arxivId,
        result: result,
        nowUtc: nowUtc,
      );
      await dao.upsert(updated);
    }
    AnxLog.info('CitationService: refreshed ${pendingIds.length} papers');
  }

  /// Requeue citation lookup for a paper right away (user refresh).
  Future<void> requeue(String arxivId) async {
    final dao = PaperCitationDao();
    final existing = await dao.selectById(arxivId);
    final now = _nowUtc();
    final updated = PaperCitation(
      arxivId: arxivId,
      provider: existing?.provider ?? 'semantic_scholar',
      providerPaperId: existing?.providerPaperId,
      citationCount: existing?.citationCount,
      lastSuccessAt: existing?.lastSuccessAt,
      lastAttemptAt: existing?.lastAttemptAt,
      lastError: existing?.lastError,
      nextRefreshAt: now,
    );
    await dao.upsert(updated);
  }
}
