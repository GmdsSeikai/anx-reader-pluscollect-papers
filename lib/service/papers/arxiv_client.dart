import 'dart:convert';
import 'dart:math';

import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/service/papers/request_wait.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// Result of one arXiv API page.
class ArxivPage {
  const ArxivPage({
    required this.entries,
    required this.totalResults,
    required this.startIndex,
    required this.itemsPerPage,
  });

  final List<ArxivEntry> entries;
  final int totalResults;
  final int startIndex;
  final int itemsPerPage;
}

class ArxivEntry {
  const ArxivEntry({
    required this.rawId,
    required this.arxivId,
    required this.version,
    required this.title,
    required this.authors,
    required this.abstractText,
    required this.categories,
    required this.publishedAt,
    required this.updatedAt,
    this.absUrl,
    this.pdfUrl,
    this.doi,
    this.journalRef,
  });

  /// Versioned id as returned by the source, e.g. `2309.02719v2`.
  final String rawId;
  final String arxivId;
  final int version;
  final String title;
  final List<PaperAuthor> authors;
  final String abstractText;
  final List<String> categories;
  final DateTime publishedAt;
  final DateTime updatedAt;
  final String? absUrl;
  final String? pdfUrl;
  final String? doi;
  final String? journalRef;
}

class ArxivQueryBranch {
  const ArxivQueryBranch({
    required this.name,
    required this.searchQuery,
    required this.dateFrom,
    required this.dateTo,
  });

  /// Stable hash key of this branch (name + query + window).
  final String name;
  final String searchQuery;
  final DateTime dateFrom;
  final DateTime dateTo;

  String branchHash() {
    return '$name|$searchQuery|${dateFrom.toUtc().toIso8601String()}|${dateTo.toUtc().toIso8601String()}';
  }
}

/// Normalized arXiv identifiers.
class ArxivId {
  ArxivId._(this.value, this.version, this.isOldStyle);

  /// Stable id without version suffix. Old-style ids keep their slash.
  final String value;
  final int version;
  final bool isOldStyle;

  static final RegExp _newStyle = RegExp(r'^(\d{4}\.\d{4,5})(?:v(\d+))?$');
  static final RegExp _oldStyle =
      RegExp(r'^([a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v(\d+))?$');

  /// Parse a bare id or an abs/pdf URL path fragment. Returns null when the
  /// input is not a legal arXiv identifier.
  static ArxivId? tryParse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2 ||
          !const ['abs', 'pdf'].contains(segments.first) ||
          !const ['arxiv.org', 'export.arxiv.org']
              .contains(uri.host.toLowerCase())) {
        return null;
      }
      text = segments.skip(1).join('/');
      if (text.endsWith('.pdf')) text = text.substring(0, text.length - 4);
    }
    final newMatch = _newStyle.firstMatch(text);
    if (newMatch != null) {
      return ArxivId._(
        newMatch.group(1)!,
        newMatch.group(2) == null ? 1 : int.parse(newMatch.group(2)!),
        false,
      );
    }
    final oldMatch = _oldStyle.firstMatch(text);
    if (oldMatch != null) {
      return ArxivId._(
        oldMatch.group(1)!,
        oldMatch.group(2) == null ? 1 : int.parse(oldMatch.group(2)!),
        true,
      );
    }
    return null;
  }

  /// Filesystem-safe file stem (old-style ids escape `/`).
  String get fileNameStem => value.replaceAll('/', '_');

  String withVersion(int v) => 'v$v';
}

/// Builds `search_query` values for the two discovery branches.
class ArxivQueryBuilder {
  ArxivQueryBuilder._();

  static const Set<String> allowedPdfHosts = {
    'arxiv.org',
    'export.arxiv.org',
    'www.arxiv.org',
  };

  /// Escape a phrase for a quoted arXiv term. Embedded quotes are removed
  /// (the API has no escape sequence inside a quoted term).
  static String quotePhrase(String phrase) {
    final cleaned = phrase.replaceAll('"', '');
    return '"$cleaned"';
  }

  /// Topic branch: keyword groups mapped to `ti`/`abs`, optional category
  /// constraint. Groups combine with OR by default, AND in advanced mode.
  static String topicQuery({
    required List<List<String>> keywordGroups,
    required List<String> categories,
    required bool groupOperatorOr,
  }) {
    final groupClauses = <String>[];
    for (final group in keywordGroups) {
      final parts = <String>[];
      for (final synonym in group) {
        final q = quotePhrase(synonym.trim());
        parts.add('(ti:$q OR abs:$q)');
      }
      if (parts.isEmpty) continue;
      groupClauses
          .add(parts.length == 1 ? parts.first : '(${parts.join(' OR ')})');
    }

    String body;
    if (groupClauses.isEmpty) {
      body = '';
    } else if (groupClauses.length == 1) {
      body = groupClauses.first;
    } else {
      body = groupClauses.join(groupOperatorOr ? ' OR ' : ' AND ');
      body = '($body)';
    }

    final catClause = categories
        .where((c) => c.trim().isNotEmpty)
        .map((c) => 'cat:${c.trim()}')
        .join(' OR ');
    if (catClause.isNotEmpty) {
      final catPart = categories.length == 1 ? catClause : '($catClause)';
      body = body.isEmpty ? catPart : '$catPart AND $body';
    }
    return body;
  }

  /// Author branch: `au` terms, aliases OR-ed. Never constrained by topic
  /// keywords or categories.
  static String authorQuery(List<List<String>> authorNames) {
    final parts = <String>[];
    for (final names in authorNames) {
      final clauses = names
          .where((n) => n.trim().isNotEmpty)
          .map((n) => 'au:${quotePhrase(n.trim())}')
          .toList();
      if (clauses.isEmpty) continue;
      parts.add(
          clauses.length == 1 ? clauses.first : '(${clauses.join(' OR ')})');
    }
    if (parts.isEmpty) return '';
    return parts.length == 1 ? parts.first : '(${parts.join(' OR ')})';
  }

  /// Wrap a branch query with a `submittedDate` range in UTC minutes.
  /// Boundary minutes are intentionally inclusive at both ends.
  static String withDateRange(String body, DateTime fromUtc, DateTime toUtc) {
    final String range = '[${_minute(fromUtc)} TO ${_minute(toUtc)}]';
    final dateClause = 'submittedDate:$range';
    if (body.isEmpty) return dateClause;
    return '$dateClause AND ($body)';
  }

  static String _minute(DateTime t) {
    final u = t.toUtc();
    final y = u.year.toString().padLeft(4, '0');
    final mo = u.month.toString().padLeft(2, '0');
    final d = u.day.toString().padLeft(2, '0');
    final h = u.hour.toString().padLeft(2, '0');
    final mi = u.minute.toString().padLeft(2, '0');
    return '$y$mo$d$h$mi';
  }

  /// Validate and normalize a PDF link to an allowed arXiv host over HTTPS.
  static Uri? normalizePdfUrl(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final host = uri.host.toLowerCase();
    if (!allowedPdfHosts.contains(host)) return null;
    return uri.replace(scheme: 'https');
  }
}

/// Parse the Atom namespace responses the arXiv API returns.
class ArxivAtomParser {
  ArxivAtomParser._();

  static const String _ns = 'http://www.w3.org/2005/Atom';
  static const String _openSearch = 'http://a9.com/-/spec/opensearch/1.1/';
  static const String _arxiv = 'http://arxiv.org/schemas/atom';

  static ArxivPage parse(String xmlText) {
    final document = XmlDocument.parse(xmlText);

    final feed = document.rootElement;
    if (feed.name.local != 'feed') {
      throw FormatException('Unexpected Atom root: ${feed.name.local}');
    }

    // An HTTP 200 body may still carry an Atom error entry (bad query,
    // id_list miss, ...). Detect it before treating entries as papers.
    for (final entry in feed.findElements('entry', namespace: _ns)) {
      String? title;
      for (final t in entry.findElements('title', namespace: _ns)) {
        title = t.innerText.trim();
      }
      String? idText;
      for (final t in entry.findElements('id', namespace: _ns)) {
        idText = t.innerText.trim();
      }
      final hasValidId = idText != null && ArxivId.tryParse(idText) != null;
      if (title == 'Error' && !hasValidId) {
        String summary = '';
        for (final s in entry.findElements('summary', namespace: _ns)) {
          summary = s.innerText.trim();
        }
        throw ArxivException(
            'arXiv error entry in HTTP 200: ${summary.isEmpty ? title : summary}',
            retriable: false);
      }
    }

    int intChild(String local, {required int fallback}) {
      for (final child in feed.childElements) {
        if (child.name.local == local &&
            (child.name.namespaceUri == _openSearch ||
                child.name.namespaceUri == _ns ||
                child.name.namespaceUri == null)) {
          final value = int.tryParse(child.innerText.trim());
          if (value != null) return value;
        }
      }
      return fallback;
    }

    final totalResults = intChild('totalResults', fallback: -1);
    final startIndex = intChild('startIndex', fallback: 0);
    final itemsPerPage = intChild('itemsPerPage', fallback: 0);

    final entries = <ArxivEntry>[];
    for (final entry in feed.findElements('entry', namespace: _ns)) {
      entries.add(_parseEntry(entry));
    }
    return ArxivPage(
      entries: entries,
      totalResults: totalResults,
      startIndex: startIndex,
      itemsPerPage: itemsPerPage,
    );
  }

  static ArxivEntry _parseEntry(XmlElement entry) {
    String? childText(String local, {String? namespace}) {
      for (final e in entry.findElements(local, namespace: namespace)) {
        return e.innerText.trim();
      }
      return null;
    }

    String? firstDescendantText(String local, String? namespace) {
      for (final el in entry.descendants.whereType<XmlElement>()) {
        if (el.name.local == local &&
            (namespace == null || el.name.namespaceUri == namespace)) {
          return el.innerText.trim();
        }
      }
      return null;
    }

    final idText = childText('id', namespace: _ns) ?? '';
    final parsed = ArxivId.tryParse(idText);
    if (parsed == null) {
      throw FormatException('Entry has illegal arXiv id: $idText');
    }

    final authors = <PaperAuthor>[];
    var order = 0;
    for (final authorEl in entry.findElements('author', namespace: _ns)) {
      String? name;
      for (final n in authorEl.findElements('name', namespace: _ns)) {
        name = n.innerText.trim();
        break;
      }
      if (name == null || name.isEmpty) continue;
      String? affiliation;
      for (final a in authorEl.findElements('affiliation', namespace: _arxiv)) {
        final affText = a.innerText.trim();
        if (affText.isNotEmpty) {
          affiliation = affText;
          break;
        }
      }
      authors
          .add(PaperAuthor(name: name, order: order, affiliation: affiliation));
      order++;
    }

    final categories = <String>[];
    for (final cat in entry.findElements('category', namespace: _ns)) {
      final term = cat.getAttribute('term');
      if (term != null && term.isNotEmpty) categories.add(term);
    }

    String? pdfUrl;
    String? absUrl;
    for (final link in entry.findElements('link', namespace: _ns)) {
      final title = link.getAttribute('title');
      final href = link.getAttribute('href');
      if (href == null) continue;
      if (title == 'pdf') {
        pdfUrl = href;
      } else if (title == 'abs' || link.getAttribute('rel') == 'alternate') {
        absUrl = href;
      }
    }

    final publishedRaw = childText('published', namespace: _ns) ?? '';
    final updatedRaw = childText('updated', namespace: _ns) ?? '';
    if (publishedRaw.isEmpty) {
      throw FormatException('Entry missing published date: $idText');
    }
    final publishedAt = DateTime.parse(publishedRaw).toUtc();
    final updatedAt =
        updatedRaw.isEmpty ? publishedAt : DateTime.parse(updatedRaw).toUtc();

    // The entry id path is the versioned identifier.
    final rawId = '${parsed.value}v${parsed.version}';

    return ArxivEntry(
      rawId: rawId,
      arxivId: parsed.value,
      version: parsed.version,
      title: _normalizeWhitespace(childText('title', namespace: _ns) ?? ''),
      authors: authors,
      abstractText:
          _normalizeWhitespace(childText('summary', namespace: _ns) ?? ''),
      categories: categories,
      publishedAt: publishedAt,
      updatedAt: updatedAt,
      absUrl: absUrl,
      pdfUrl: pdfUrl,
      doi: childText('doi', namespace: _arxiv) ??
          firstDescendantText('doi', _arxiv),
      journalRef: childText('journal_ref', namespace: _arxiv) ??
          firstDescendantText('journal_ref', _arxiv),
    );
  }

  static String _normalizeWhitespace(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

/// HTTP client for the arXiv export API.
///
/// The whole module — every task, manual preview and retry — issues arXiv
/// requests through one shared serial gate with at least
/// [minRequestInterval] between requests. The gate is module-level state so
/// multiple [ArxivClient] instances cannot bypass the rate limit.
class ArxivClient {
  ArxivClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final Set<CancelToken> _ownedRequests = {};

  void cancelActiveRequests() {
    for (final token in _ownedRequests.toList()) {
      token.cancel('paper collection paused');
    }
  }

  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration totalTimeout = Duration(seconds: 45);
  static const Duration minRequestInterval = Duration(seconds: 3);
  static const int defaultPageSize = 100;

  static const String endpoint = 'https://export.arxiv.org/api/query';

  /// Shared module-level gate: one in-flight arXiv request at a time and a
  /// minimum gap between request starts, regardless of how many tasks run.
  static DateTime? _lastRequestAt;
  static Future<void> _chain = Future<void>.value();

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

  /// Fetch one page. Retries transient failures at most 3 times with
  /// exponential backoff and jitter; obeys `Retry-After` when present.
  Future<ArxivPage> fetchPage({
    required String searchQuery,
    required int start,
    int maxResults = defaultPageSize,
  }) {
    return _serialized((token) => _fetchPageOnce(
          cancelToken: token,
          searchQuery: searchQuery,
          start: start,
          maxResults: maxResults,
        ));
  }

  Future<ArxivPage> _fetchPageOnce({
    required CancelToken cancelToken,
    required String searchQuery,
    required int start,
    required int maxResults,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      await _enforceGap(cancelToken);
      try {
        final uri = Uri.parse(endpoint).replace(queryParameters: {
          'search_query': searchQuery,
          'start': '$start',
          'max_results': '$maxResults',
          'sortBy': 'submittedDate',
          'sortOrder': 'descending',
        });
        // Dio 5.x `Options` has no connectTimeout; it lives on
        // RequestOptions/BaseOptions. Build RequestOptions explicitly so
        // the setting applies per request without mutating a shared
        // BaseOptions under concurrency.
        final response = await _dio.fetch<List<int>>(
          RequestOptions(
            path: uri.toString(),
            method: 'GET',
            responseType: ResponseType.bytes,
            validateStatus: (code) => code != null && code >= 200 && code < 500,
            connectTimeout: connectTimeout,
            sendTimeout: connectTimeout,
            receiveTimeout: totalTimeout,
            cancelToken: cancelToken,
          ),
        );
        final status = response.statusCode ?? 0;
        if (status == 429 || status == 503) {
          lastError = ArxivException('arXiv HTTP $status');
          final retryAfter = response.headers.value('retry-after');
          final delay = retryAfter != null
              ? Duration(seconds: int.tryParse(retryAfter) ?? 5)
              : _backoff(attempt);
          await waitForPaperRequest(delay, cancelToken);
          continue;
        }
        if (status != 200) {
          throw ArxivException('arXiv HTTP $status', retriable: false);
        }
        final body = utf8.decode(response.data ?? const <int>[]);
        // HTTP 200 may still carry an Atom error entry; the parser throws.
        return ArxivAtomParser.parse(body);
      } on ArxivException catch (e) {
        if (!e.retriable) rethrow;
        lastError = e;
        await waitForPaperRequest(_backoff(attempt), cancelToken);
      } on DioException catch (e) {
        if (cancelToken.isCancelled) rethrow;
        lastError = e;
        final isTimeout = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout;
        if (e.response != null) {
          final code = e.response!.statusCode;
          if (code == 401 || code == 403) {
            throw ArxivException('arXiv HTTP $code', retriable: false);
          }
        }
        if (!isTimeout && e.type == DioExceptionType.badResponse) {
          final code = e.response?.statusCode ?? 0;
          if (code > 0 && code < 500 && code != 429) {
            throw ArxivException('arXiv HTTP $code', retriable: false);
          }
        }
        await waitForPaperRequest(_backoff(attempt), cancelToken);
      } on FormatException catch (e) {
        throw ArxivException('arXiv response parse error: $e',
            retriable: false);
      }
    }
    throw ArxivException('arXiv request failed after retries: $lastError');
  }

  Duration _backoff(int attempt) {
    final base = Duration(seconds: 1 << attempt);
    final jitterMs = Random().nextInt(500);
    return base + Duration(milliseconds: jitterMs);
  }

  /// Manual preview used by the task editor (shares module rate limiting).
  Future<ArxivPage> preview(String searchQuery, {int maxResults = 5}) {
    return fetchPage(
        searchQuery: searchQuery, start: 0, maxResults: maxResults);
  }
}

class ArxivException implements Exception {
  ArxivException(this.message, {this.retriable = true});
  final String message;
  final bool retriable;

  @override
  String toString() => 'ArxivException: $message';
}
