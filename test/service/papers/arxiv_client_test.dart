import 'dart:io';

import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:flutter_test/flutter_test.dart';

String fixture(String name) =>
    File('test/fixtures/papers/$name').readAsStringSync();

void main() {
  group('ArxivId', () {
    test('parses new-style id with and without version', () {
      final withVersion = ArxivId.tryParse('2309.02719v2');
      expect(withVersion, isNotNull);
      expect(withVersion!.value, '2309.02719');
      expect(withVersion.version, 2);

      final bare = ArxivId.tryParse('2309.02719');
      expect(bare!.value, '2309.02719');
      expect(bare.version, 1);
    });

    test('parses old-style id and escapes slash for file names', () {
      final old = ArxivId.tryParse('math.GT/0309136v1');
      expect(old, isNotNull);
      expect(old!.value, 'math.GT/0309136');
      expect(old.isOldStyle, isTrue);
      expect(old.fileNameStem, 'math.GT_0309136');
    });

    test('rejects non-arXiv text', () {
      expect(ArxivId.tryParse('hello world'), isNull);
      expect(ArxivId.tryParse(''), isNull);
      expect(ArxivId.tryParse('999.99'), isNull);
    });

    test('parses from abs URL', () {
      final id = ArxivId.tryParse('https://arxiv.org/abs/2309.02719v2');
      expect(id!.value, '2309.02719');
    });
  });

  group('ArxivAtomParser', () {
    test('parses entries, versions, authors, categories and links', () {
      final page = ArxivAtomParser.parse(fixture('arxiv_atom_page.xml'));
      expect(page.totalResults, 2);
      expect(page.entries, hasLength(2));

      final first = page.entries.first;
      expect(first.arxivId, '2309.02719');
      expect(first.version, 2);
      expect(first.title, contains('Knowledge Distillation'));
      expect(first.authors, hasLength(2));
      expect(first.authors[1].affiliation, 'Nanjing Tech University');
      expect(first.categories, ['cs.CV', 'cs.LG']);
      // published is the first version submission; updated never replaces it
      expect(first.publishedAt, DateTime.utc(2023, 9, 6, 17, 59, 59));
      expect(first.updatedAt, DateTime.utc(2024, 3, 1, 9, 0, 0));
      expect(first.pdfUrl, contains('2309.02719'));
      expect(first.doi, '10.1000/test.doi');
      expect(first.journalRef, 'Some Journal 2024');
    });

    test('parses old-style identifiers from entries', () {
      final page = ArxivAtomParser.parse(fixture('arxiv_atom_page.xml'));
      final second = page.entries[1];
      expect(second.arxivId, 'math.GT/0309136');
      expect(second.publishedAt, second.updatedAt);
    });

    test('treats HTTP-200 error entries as failure', () {
      expect(
        () => ArxivAtomParser.parse(fixture('arxiv_atom_error.xml')),
        throwsA(isA<ArxivException>()),
      );
    });
  });

  group('ArxivQueryBuilder', () {
    test('maps keyword groups to ti/abs with OR within a group', () {
      final query = ArxivQueryBuilder.topicQuery(
        keywordGroups: [
          ['object detection', 'object detector'],
          ['knowledge distillation'],
        ],
        categories: const [],
        groupOperatorOr: true,
      );
      expect(query, contains('ti:"object detection"'));
      expect(query, contains('abs:"object detection"'));
      expect(query,
          contains(' OR (ti:"object detector" OR abs:"object detector")'));
      expect(query, contains(') OR ('));
    });

    test('AND mode joins groups with AND', () {
      final query = ArxivQueryBuilder.topicQuery(
        keywordGroups: [
          ['a b'],
          ['c d'],
        ],
        categories: const [],
        groupOperatorOr: false,
      );
      expect(query, contains(') AND ('));
    });

    test('category constrains only the topic branch', () {
      final query = ArxivQueryBuilder.topicQuery(
        keywordGroups: [
          ['object detection'],
        ],
        categories: const ['cs.CV'],
        groupOperatorOr: true,
      );
      expect(query, startsWith('cat:cs.CV AND '));
    });

    test('author branch is independent and OR-s aliases', () {
      final query = ArxivQueryBuilder.authorQuery([
        ['Xili Wan', 'X Wan'],
      ]);
      expect(query, contains('au:"Xili Wan"'));
      expect(query, contains(' OR au:"X Wan"'));
      expect(query, isNot(contains('ti:')));
    });

    test('date range wraps body with submittedDate in UTC minutes', () {
      final wrapped = ArxivQueryBuilder.withDateRange(
        'cat:cs.CV',
        DateTime.utc(2026, 1, 1, 0, 0),
        DateTime.utc(2026, 1, 2, 23, 59),
      );
      expect(wrapped, contains('submittedDate:[202601010000 TO 202601022359]'));
      expect(wrapped, endsWith('AND (cat:cs.CV)'));
    });

    test('normalizes PDF urls and rejects non-arXiv hosts', () {
      final ok = ArxivQueryBuilder.normalizePdfUrl(
          'http://arxiv.org/pdf/2309.02719v2');
      expect(ok, isNotNull);
      expect(ok!.scheme, 'https');
      expect(
          ArxivQueryBuilder.normalizePdfUrl('https://evil.example.com/a.pdf'),
          isNull);
      expect(
          ArxivQueryBuilder.normalizePdfUrl('ftp://arxiv.org/a.pdf'), isNull);
    });
  });
}
