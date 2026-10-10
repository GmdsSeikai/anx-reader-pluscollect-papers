import 'dart:io';

import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/service/papers/semantic_scholar_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

void main() {
  final live = Platform.environment['PAPER_LIVE_SOURCES'] == '1';
  test('live arXiv Atom page uses the production client and parser', () async {
    final page = await ArxivClient().fetchPage(
        searchQuery: 'cat:cs.CV AND ti:"deep learning"',
        start: 0,
        maxResults: 1);
    expect(page.entries, hasLength(1));
    final paper = page.entries.single;
    expect(ArxivId.tryParse(paper.arxivId), isNotNull);
    expect(paper.title, isNotEmpty);
    expect(paper.abstractText, isNotEmpty);
    expect(paper.publishedAt.isAfter(paper.updatedAt), isFalse);
    debugPrint('arXiv ${paper.arxivId} v${paper.version}: ${paper.title}');
  }, skip: !live, timeout: const Timeout(Duration(minutes: 3)));

  test('live Semantic Scholar matches an explicit arXiv identifier', () async {
    final results = await SemanticScholarClient(keyProvider: () => '')
        .lookup(['1706.03762']);
    expect(results, hasLength(1));
    expect(results.single.matched, isTrue);
    expect(results.single.count, isNotNull);
    debugPrint(
        'Semantic Scholar ARXIV:1706.03762 count=${results.single.count}');
  }, skip: !live, timeout: const Timeout(Duration(minutes: 3)));
}
