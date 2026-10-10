import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('verifyPdfBytes', () {
    test('accepts a real PDF header', () {
      PaperImportService.verifyPdfBytes(
          [...'%PDF-1.7'.codeUnits, 1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('P10: rejects an HTML body disguised as a PDF', () {
      expect(
        () => PaperImportService.verifyPdfBytes(
            '<!DOCTYPE html><html>not a pdf</html>'.codeUnits),
        throwsA(isA<ImportException>()),
      );
    });

    test('P10: rejects an empty or tiny body', () {
      expect(
        () => PaperImportService.verifyPdfBytes(const []),
        throwsA(isA<ImportException>()),
      );
      expect(
        () => PaperImportService.verifyPdfBytes('%PDF'.codeUnits),
        throwsA(isA<ImportException>()),
      );
    });
  });

  group('download URL policy', () {
    test('P10: rejects URLs outside the allowed arXiv hosts', () {
      expect(
        ArxivQueryBuilder.normalizePdfUrl('https://evil.example.com/a.pdf'),
        isNull,
      );
      expect(
        ArxivQueryBuilder.normalizePdfUrl(
            'http://mirror.example.org/pdf/a.pdf'),
        isNull,
      );
    });

    test('upgrades http to https for allowed hosts', () {
      final uri = ArxivQueryBuilder.normalizePdfUrl(
          'http://arxiv.org/pdf/2309.02719v2');
      expect(uri!.scheme, 'https');
      expect(uri.host, 'arxiv.org');
    });
  });

  group('arXiv id file naming', () {
    test('old-style ids escape slashes in cache file names', () {
      final id = ArxivId.tryParse('math.GT/0309136v1')!;
      expect(id.fileNameStem, 'math.GT_0309136');
    });
  });
}
