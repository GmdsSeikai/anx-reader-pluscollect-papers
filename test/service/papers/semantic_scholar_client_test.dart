import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/service/papers/semantic_scholar_client.dart';
import 'package:flutter_test/flutter_test.dart';

List<dynamic> fixture() =>
    jsonDecode(File('test/fixtures/papers/semantic_scholar_batch.json')
        .readAsStringSync()) as List<dynamic>;

void main() {
  group('batch result mapping', () {
    test('maps count, null miss, explicit zero and identity mismatch', () {
      final client = SemanticScholarClient();
      final results = client.mapBatchResults(
        // Positional contract: result[i] answers request[i].
        ['2309.02719', '0000.00000', '1111.1111', '4444.44444', '2222.22222'],
        fixture(),
      );

      // Normal match with a positive count.
      expect(results[0].matched, isTrue);
      expect(results[0].count, 42);

      // A null slot is unknown, not zero.
      expect(results[1].matched, isFalse);
      expect(results[1].count, isNull);

      // An explicit 0 from the service is zero.
      expect(results[2].matched, isTrue);
      expect(results[2].count, 0);

      // A different arXiv id is an identity mismatch and must not bind.
      expect(results[3].matched, isFalse);
      expect(results[3].count, isNull);

      // citationCount: null is unknown even when identity matches.
      expect(results[4].matched, isTrue);
      expect(results[4].count, isNull);
    });

    test('rejects batch length mismatch', () {
      final client = SemanticScholarClient();
      expect(
        () => client.mapBatchResults(['a', 'b'], fixture()),
        throwsA(isA<SemanticScholarException>()),
      );
    });
  });

  group('applyCitationResult', () {
    final now = DateTime.utc(2026, 1, 10);

    test('success sets count and 7-day refresh', () {
      final updated = applyCitationResult(
        existing: null,
        arxivId: '2309.02719',
        result: const CitationLookupResult(
          arxivId: '2309.02719',
          count: 42,
          providerPaperId: 's2-normal',
          matched: true,
        ),
        nowUtc: now,
      );
      expect(updated.citationCount, 42);
      expect(updated.lastSuccessAt, now);
      expect(updated.isStale, isFalse);
      expect(updated.nextRefreshAt, now.add(const Duration(days: 7)));
    });

    test('explicit zero is stored as zero with a success time', () {
      final updated = applyCitationResult(
        existing: null,
        arxivId: '1111.1111',
        result: const CitationLookupResult(
          arxivId: '1111.1111',
          count: 0,
          providerPaperId: 's2-zero',
          matched: true,
        ),
        nowUtc: now,
      );
      expect(updated.citationCount, 0);
      expect(updated.lastSuccessAt, isNotNull);
      expect(updated.isUnknown, isFalse);
    });

    test('failed refresh keeps the previous value and marks it stale', () {
      final previous = PaperCitation(
        arxivId: '2309.02719',
        provider: 'semantic_scholar',
        citationCount: 42,
        lastSuccessAt: DateTime.utc(2026, 1, 1),
        lastAttemptAt: DateTime.utc(2026, 1, 1),
      );
      final updated = applyCitationResult(
        existing: previous,
        arxivId: '2309.02719',
        result: const CitationLookupResult(
          arxivId: '2309.02719',
          count: null,
          providerPaperId: null,
          matched: false,
        ),
        nowUtc: now,
      );
      // Never zeroed or cleared.
      expect(updated.citationCount, 42);
      expect(updated.lastSuccessAt, DateTime.utc(2026, 1, 1));
      expect(updated.isStale, isTrue);
    });

    test('miss on a never-collected paper stays unknown', () {
      final updated = applyCitationResult(
        existing: null,
        arxivId: '2222.22222',
        result: const CitationLookupResult(
          arxivId: '2222.22222',
          count: null,
          providerPaperId: null,
          matched: false,
        ),
        nowUtc: now,
      );
      expect(updated.citationCount, isNull);
      expect(updated.isUnknown, isTrue);
    });

    test('a decreased count from the service is kept as reported', () {
      final previous = PaperCitation(
        arxivId: '2309.02719',
        provider: 'semantic_scholar',
        citationCount: 100,
        lastSuccessAt: DateTime.utc(2026, 1, 1),
      );
      final updated = applyCitationResult(
        existing: previous,
        arxivId: '2309.02719',
        result: const CitationLookupResult(
          arxivId: '2309.02719',
          count: 90,
          providerPaperId: 's2-normal',
          matched: true,
        ),
        nowUtc: now,
      );
      expect(updated.citationCount, 90);
    });

    test('constructing a count without a success time is rejected', () {
      expect(
        () => PaperCitation(
          arxivId: 'x',
          provider: 'semantic_scholar',
          citationCount: 5,
        ),
        throwsArgumentError,
      );
      expect(
        () => PaperCitation(
          arxivId: 'x',
          provider: 'semantic_scholar',
          citationCount: -1,
          lastSuccessAt: now,
        ),
        throwsArgumentError,
      );
    });
  });
}
