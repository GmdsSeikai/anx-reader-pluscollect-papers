import 'dart:math';

import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/service/papers/request_wait.dart';
import 'package:dio/dio.dart';

/// One validated citation result.
class CitationLookupResult {
  const CitationLookupResult({
    required this.arxivId,
    required this.count,
    required this.providerPaperId,
    required this.matched,
  });

  final String arxivId;

  /// Non-negative count when [matched]; null means unknown (not found or
  /// service did not return a valid count). Zero is only reported when the
  /// service explicitly returned `citationCount: 0`.
  final int? count;
  final String? providerPaperId;
  final bool matched;
}

/// Semantic Scholar batch citation lookup by exact arXiv id.
///
/// The single citation provider for v1: no title fuzzing, no OpenAlex
/// fallback. Failures leave statistics unknown or stale, never zero.
class SemanticScholarClient {
  SemanticScholarClient(
      {Dio? dio, String? apiKey, String Function()? keyProvider})
      : _dio = dio ?? Dio(),
        _keyProvider = keyProvider ?? (() => apiKey ?? '');

  final Dio _dio;
  final Set<CancelToken> _ownedRequests = {};

  void cancelActiveRequests() {
    for (final token in _ownedRequests.toList()) {
      token.cancel('paper statistics paused');
    }
  }

  /// Resolved per request so a key edited in settings takes effect on the
  /// next lookup instead of being captured at construction time.
  final String Function() _keyProvider;

  static const String batchEndpoint =
      'https://api.semanticscholar.org/graph/v1/paper/batch';
  static const String fieldsParam = 'paperId,title,externalIds,citationCount';
  static const int batchSize = 100;
  static const Duration minRequestInterval = Duration(seconds: 1);
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration totalTimeout = Duration(seconds: 45);

  DateTime? _lastRequestAt;
  Future<void> _chain = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function(CancelToken token) action) {
    final token = CancelToken();
    _ownedRequests.add(token);
    final previous = _chain;
    final Future<T> task = previous.then((_) {
      if (token.isCancelled) throw token.cancelError!;
      return action(token);
    });
    _chain = task.then<void>((_) {}, onError: (_) {});
    return Future.any<T>(
            [task, token.whenCancel.then<T>((error) => throw error)])
        .whenComplete(() => _ownedRequests.remove(token));
  }

  Future<void> _enforceGap(CancelToken token) async {
    final last = _lastRequestAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < minRequestInterval) {
        await waitForPaperRequest(minRequestInterval - elapsed, token);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  /// Look up citations for [arxivIds]; returns one result per requested id
  /// in input order. Throws [SemanticScholarException] when the whole batch
  /// request fails; per-item misses come back as `matched: false`.
  Future<List<CitationLookupResult>> lookup(List<String> arxivIds) {
    return _serialized((token) => _lookupAll(arxivIds, token));
  }

  Future<List<CitationLookupResult>> _lookupAll(
      List<String> arxivIds, CancelToken token) async {
    final results = <CitationLookupResult>[];
    for (var i = 0; i < arxivIds.length; i += batchSize) {
      final end = min(i + batchSize, arxivIds.length);
      results.addAll(await _lookupBatch(arxivIds.sublist(i, end), token));
    }
    return results;
  }

  Future<List<CitationLookupResult>> _lookupBatch(
      List<String> ids, CancelToken cancelToken) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      await _enforceGap(cancelToken);
      try {
        final headers = <String, dynamic>{};
        final key = _keyProvider();
        if (key.trim().isNotEmpty) {
          headers['x-api-key'] = key.trim();
        }
        final response = await _dio.fetch<dynamic>(
          RequestOptions(
            path: batchEndpoint,
            method: 'POST',
            queryParameters: <String, String>{'fields': fieldsParam},
            data: <String, dynamic>{
              'ids': ids.map((id) => 'ARXIV:$id').toList(growable: false),
            },
            headers: headers,
            responseType: ResponseType.json,
            validateStatus: (code) => code != null && code >= 200 && code < 500,
            connectTimeout: connectTimeout,
            sendTimeout: connectTimeout,
            receiveTimeout: totalTimeout,
            cancelToken: cancelToken,
          ),
        );

        final status = response.statusCode ?? 0;
        if (status == 429 || status == 503) {
          lastError = SemanticScholarException('HTTP $status');
          final retryAfter = response.headers.value('retry-after');
          final delay = retryAfter != null
              ? Duration(seconds: int.tryParse(retryAfter) ?? 5)
              : _backoff(attempt);
          await waitForPaperRequest(delay, cancelToken);
          continue;
        }
        if (status == 401 || status == 403) {
          throw SemanticScholarException('HTTP $status', retriable: false);
        }
        if (status != 200) {
          throw SemanticScholarException('HTTP $status', retriable: false);
        }

        final data = response.data;
        if (data is! List) {
          throw SemanticScholarException('expected a batch array',
              retriable: false);
        }
        if (data.length != ids.length) {
          // Contract: the batch array length mirrors the request length.
          throw SemanticScholarException(
            'batch length mismatch: got ${data.length} for ${ids.length}',
            retriable: false,
          );
        }
        return mapBatchResults(ids, List<dynamic>.from(data));
      } on SemanticScholarException catch (e) {
        if (!e.retriable) rethrow;
        lastError = e;
        await waitForPaperRequest(_backoff(attempt), cancelToken);
      } on DioException catch (e) {
        if (cancelToken.isCancelled) rethrow;
        lastError = e;
        if (e.response != null) {
          final code = e.response!.statusCode ?? 0;
          if (code == 401 || code == 403) {
            throw SemanticScholarException('HTTP $code', retriable: false);
          }
        }
        await waitForPaperRequest(_backoff(attempt), cancelToken);
      }
    }
    throw SemanticScholarException('request failed after retries: $lastError');
  }

  /// Map a batch response payload to per-id results. The batch array length
  /// mirrors the request length; a mismatch is a contract violation.
  List<CitationLookupResult> mapBatchResults(
      List<String> ids, List<dynamic> data) {
    if (data.length != ids.length) {
      throw SemanticScholarException(
        'batch length mismatch: got ${data.length} for ${ids.length}',
        retriable: false,
      );
    }
    return _mapResultsCore(ids, data);
  }

  List<CitationLookupResult> _mapResultsCore(
      List<String> ids, List<dynamic> data) {
    final results = <CitationLookupResult>[];
    for (var i = 0; i < ids.length; i++) {
      final requestedId = ids[i];
      final item = data[i];
      if (item == null) {
        results.add(CitationLookupResult(
          arxivId: requestedId,
          count: null,
          providerPaperId: null,
          matched: false,
        ));
        continue;
      }
      if (item is! Map) {
        throw SemanticScholarException('malformed batch item',
            retriable: false);
      }
      final map = Map<String, dynamic>.from(item);
      final externalIds = map['externalIds'];
      String? returnedArxiv;
      if (externalIds is Map) {
        returnedArxiv = externalIds['ArXiv'] as String?;
      }
      // A different arXiv id is an identity mismatch: never bind it.
      if (returnedArxiv == null ||
          returnedArxiv.trim().isEmpty ||
          returnedArxiv.trim() != requestedId) {
        results.add(CitationLookupResult(
          arxivId: requestedId,
          count: null,
          providerPaperId: map['paperId'] as String?,
          matched: false,
        ));
        continue;
      }
      final rawCount = map['citationCount'];
      if (rawCount is! int || rawCount < 0) {
        // null / missing / non-integer is unknown, never coerced to zero.
        results.add(CitationLookupResult(
          arxivId: requestedId,
          count: null,
          providerPaperId: map['paperId'] as String?,
          matched: true,
        ));
        continue;
      }
      results.add(CitationLookupResult(
        arxivId: requestedId,
        count: rawCount,
        providerPaperId: map['paperId'] as String?,
        matched: true,
      ));
    }
    return results;
  }

  Duration _backoff(int attempt) {
    final base = Duration(seconds: 1 << attempt);
    final jitterMs = Random().nextInt(500);
    return base + Duration(milliseconds: jitterMs);
  }
}

class SemanticScholarException implements Exception {
  SemanticScholarException(this.message, {this.retriable = true});
  final String message;
  final bool retriable;

  @override
  String toString() => 'SemanticScholarException: $message';
}

/// Build a [PaperCitation] refresh state from a lookup result.
///
/// Keeps a previously successful value and its date when a refresh fails or
/// returns unknown; only an explicit success replaces the count.
PaperCitation applyCitationResult({
  required PaperCitation? existing,
  required String arxivId,
  required CitationLookupResult result,
  required DateTime nowUtc,
}) {
  final previous =
      existing ?? PaperCitation(arxivId: arxivId, provider: 'semantic_scholar');
  if (result.matched && result.count != null) {
    return PaperCitation(
      arxivId: arxivId,
      provider: previous.provider,
      providerPaperId: result.providerPaperId,
      citationCount: result.count,
      lastSuccessAt: nowUtc,
      lastAttemptAt: nowUtc,
      lastError: null,
      // Successful statistics are refreshed after 7 days.
      nextRefreshAt: nowUtc.add(const Duration(days: 7)),
    );
  }
  // Miss or invalid value: keep the old success (mark stale when we had
  // one) and retry in 24h — covers both "recent paper not yet indexed"
  // and "refresh failed". Nothing is ever zeroed or cleared.
  return PaperCitation(
    arxivId: arxivId,
    provider: previous.provider,
    providerPaperId: result.providerPaperId ?? previous.providerPaperId,
    citationCount: previous.citationCount,
    lastSuccessAt: previous.lastSuccessAt,
    lastAttemptAt: nowUtc,
    lastError: result.matched ? 'missing_citation_count' : 'not_matched',
    nextRefreshAt: nowUtc.add(const Duration(hours: 24)),
  );
}
