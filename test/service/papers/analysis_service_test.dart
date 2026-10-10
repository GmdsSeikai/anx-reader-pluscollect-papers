import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

Paper _paper() => Paper(
      arxivId: '2309.02719',
      latestVersion: 2,
      title: 'Deep Mutual Knowledge Distillation',
      authors: const [PaperAuthor(name: 'Alice Zhang')],
      abstractText: 'We propose mutual knowledge distillation for detection.',
      categories: const ['cs.CV'],
      publishedAt: DateTime.utc(2023, 9, 6),
      updatedAt: DateTime.utc(2024, 3, 1),
      contentHash: 'hash',
      firstSeenAt: DateTime.utc(2026, 1, 1),
      lastSeenAt: DateTime.utc(2026, 1, 1),
    );

String validResult() => '''
{
  "schema_version": 1,
  "title_zh": "深度互知识蒸馏",
  "abstract_zh": "我们提出互知识蒸馏方法。",
  "assessments": [
    {
      "task_id": "task-1",
      "profile_hash": "ph1",
      "relevance_score": 82,
      "reason_zh": "摘要讨论了目标检测中的知识蒸馏。",
      "evidence": [
        {"field": "abstract", "quote": "mutual knowledge distillation"}
      ]
    }
  ]
}
''';

void main() {
  group('parseAnalysisResult', () {
    final expected = {'task-1': 'ph1'};

    test('accepts a well-formed result with real evidence quotes', () {
      final payload = parseAnalysisResult(
        rawOutput: validResult(),
        paper: _paper(),
        expectedTaskProfileHashes: expected,
        translationOnly: false,
      );
      expect(payload.titleZh, '深度互知识蒸馏');
      expect(payload.assessments, hasLength(1));
      expect(payload.assessments.first.relevanceScore, 82);
    });

    test('accepts a markdown-fenced JSON body', () {
      final payload = parseAnalysisResult(
        rawOutput: '```json\n${validResult()}\n```',
        paper: _paper(),
        expectedTaskProfileHashes: expected,
        translationOnly: false,
      );
      expect(payload.assessments, hasLength(1));
    });

    test('rejects non-JSON output', () {
      expect(
        () => parseAnalysisResult(
          rawOutput: 'I think this paper is relevant!',
          paper: _paper(),
          expectedTaskProfileHashes: expected,
          translationOnly: false,
        ),
        throwsA(isA<AnalysisValidationException>()),
      );
    });

    test('rejects unsupported schema versions', () {
      final bad = validResult()
          .replaceFirst('"schema_version": 1', '"schema_version": 99');
      expect(
        () => parseAnalysisResult(
          rawOutput: bad,
          paper: _paper(),
          expectedTaskProfileHashes: expected,
          translationOnly: false,
        ),
        throwsA(isA<AnalysisValidationException>()),
      );
    });

    test('rejects a missing task assessment', () {
      final empty = '''
      {"schema_version": 1, "title_zh": "t", "abstract_zh": "a", "assessments": []}
      ''';
      expect(
        () => parseAnalysisResult(
          rawOutput: empty,
          paper: _paper(),
          expectedTaskProfileHashes: expected,
          translationOnly: false,
        ),
        throwsA(isA<AnalysisValidationException>()),
      );
    });

    test('rejects out-of-range scores', () {
      final bad = validResult()
          .replaceFirst('"relevance_score": 82', '"relevance_score": 120');
      expect(
        () => parseAnalysisResult(
          rawOutput: bad,
          paper: _paper(),
          expectedTaskProfileHashes: expected,
          translationOnly: false,
        ),
        throwsA(isA<AnalysisValidationException>()),
      );
    });

    test('rejects forged evidence quotes', () {
      final bad = validResult().replaceFirst(
        '"mutual knowledge distillation"',
        '"a sentence that is not in the abstract"',
      );
      expect(
        () => parseAnalysisResult(
          rawOutput: bad,
          paper: _paper(),
          expectedTaskProfileHashes: expected,
          translationOnly: false,
        ),
        throwsA(isA<AnalysisValidationException>()),
      );
    });

    test('rejects wrong profile hash', () {
      final bad = validResult()
          .replaceFirst('"profile_hash": "ph1"', '"profile_hash": "other"');
      expect(
        () => parseAnalysisResult(
          rawOutput: bad,
          paper: _paper(),
          expectedTaskProfileHashes: expected,
          translationOnly: false,
        ),
        throwsA(isA<AnalysisValidationException>()),
      );
    });

    test('translation-only requires empty assessments', () {
      final bad = validResult(); // contains an assessment
      expect(
        () => parseAnalysisResult(
          rawOutput: bad,
          paper: _paper(),
          expectedTaskProfileHashes: const {},
          translationOnly: true,
        ),
        throwsA(isA<AnalysisValidationException>()),
      );
    });

    test('evidence matching normalizes whitespace only', () {
      final spaced = validResult().replaceFirst(
        '"mutual knowledge distillation"',
        '"mutual   knowledge\\n distillation"',
      );
      final payload = parseAnalysisResult(
        rawOutput: spaced,
        paper: _paper(),
        expectedTaskProfileHashes: expected,
        translationOnly: false,
      );
      expect(payload.assessments, hasLength(1));
    });
  });

  group('buildAnalysisMessages', () {
    test('marks the paper text as untrusted and sets translation-only', () {
      final built = buildAnalysisMessages(
        paper: _paper(),
        tasks: const [],
      );
      expect(built.translationOnly, isTrue);
      final input = built.messages.last.contentAsString;
      expect(input, contains('untrusted'));
      expect(input, contains('translation-only'));
    });

    test('includes every task profile when relevance is wanted', () {
      final built = buildAnalysisMessages(
        paper: _paper(),
        tasks: const [
          AnalysisTaskInput(
            taskId: 'task-1',
            profileHash: 'ph1',
            config: PaperTaskConfig(
              researchTopic: 'vision',
              keywordGroups: [
                PaperKeywordGroup(synonyms: ['knowledge distillation']),
              ],
            ),
          ),
          AnalysisTaskInput(
            taskId: 'task-2',
            profileHash: 'ph2',
            config: PaperTaskConfig(
              researchTopic: 'materials',
              keywordGroups: [
                PaperKeywordGroup(synonyms: ['materials property prediction']),
              ],
            ),
          ),
        ],
      );
      expect(built.translationOnly, isFalse);
      final input = built.messages.last.contentAsString;
      expect(input, contains('task-1'));
      expect(input, contains('task-2'));
      // Each task gets its own profile block with its own semantics.
      expect(input, contains('research_topic: vision'));
      expect(input, contains('research_topic: materials'));
    });
  });

  group('cache keys', () {
    test('key changes with content, profiles and model fingerprint', () {
      String key({
        String content = 'c',
        List<String> profiles = const ['p1'],
        String model = 'm1',
      }) =>
          analysisCacheKeyOf(
            arxivId: '2309.02719',
            contentHash: content,
            sortedProfileHashes: profiles,
            modelFingerprint: model,
          );

      expect(key(), key());
      expect(key(content: 'c2'), isNot(key()));
      expect(key(profiles: const ['p2']), isNot(key()));
      expect(key(model: 'm2'), isNot(key()));
    });

    test('model fingerprint never contains the API key', () {
      final fp = modelFingerprintOf(
        providerId: 'p',
        protocol: AiProtocol.openai,
        baseUrl: 'https://api.example.com',
        model: 'm',
        reasoningCode: 'auto',
      );
      expect(fp, hasLength(64)); // sha256 hex
      expect(fp, isNot(contains('secret')));
    });

    test('profile order does not change the cache key', () {
      final a = analysisCacheKeyOf(
        arxivId: 'x',
        contentHash: 'c',
        sortedProfileHashes: const ['p1', 'p2'],
        modelFingerprint: 'm',
      );
      final b = analysisCacheKeyOf(
        arxivId: 'x',
        contentHash: 'c',
        sortedProfileHashes: const ['p1', 'p2'],
        modelFingerprint: 'm',
      );
      expect(a, b);
    });
  });
}
