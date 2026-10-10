import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/collection_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeWindows', () {
    final config = const PaperTaskConfig(
      latestWindowDays: 30,
      hotWindowMonths: 12,
    );

    test('latest initial window is 30 days back (UTC)', () {
      final now = DateTime.utc(2026, 10, 9, 12);
      final windows =
          computeWindows(config: config, now: now, isFirstRun: true);
      expect(windows.latestTo, now);
      expect(windows.latestFrom, DateTime.utc(2026, 9, 9, 12));
    });

    test('hot initial window is 12 calendar months back', () {
      final now = DateTime.utc(2026, 10, 9, 12);
      final windows =
          computeWindows(config: config, now: now, isFirstRun: true);
      expect(windows.hotFrom, DateTime.utc(2025, 10, 9, 12));
    });

    test('month-end clamping: Mar 31 minus 1 month is Feb 28/29', () {
      expect(
        subtractCalendarMonths(DateTime.utc(2026, 3, 31), 1),
        DateTime.utc(2026, 2, 28),
      );
      expect(
        subtractCalendarMonths(DateTime.utc(2024, 3, 31), 1),
        DateTime.utc(2024, 2, 29), // leap year
      );
    });

    test('subsequent runs still guard the full configured window', () {
      final now = DateTime.utc(2026, 10, 9, 12);
      final watermark = DateTime.utc(2026, 10, 5, 0);
      final windows = computeWindows(
        config: config,
        now: now,
        isFirstRun: false,
        latestWatermark: watermark,
      );
      // The full window is planned every run so an expanded window or a
      // long shutdown covers the gap; completed stable slices are reused.
      expect(windows.latestFrom, DateTime.utc(2026, 9, 9, 12));
    });
  });

  group('planSlices', () {
    test('latest slices are UTC day buckets, newest first, stable edges', () {
      final specs = planSlices(
        channel: PaperChannel.latest,
        fromUtc: DateTime.utc(2026, 1, 1, 0),
        toUtc: DateTime.utc(2026, 1, 3, 12),
        branchHash: 'topic',
      );
      expect(specs, isNotEmpty);
      // Newest bucket covers the end of the range as a whole UTC day.
      expect(specs.first.fromUtc, DateTime.utc(2026, 1, 3));
      expect(specs.first.toUtc, DateTime.utc(2026, 1, 4));
      // Newest first.
      expect(specs.first.fromUtc.isAfter(specs.last.fromUtc), isTrue);
      // Edges are UTC-midnight stable, so replanning reuses completed rows.
      for (final spec in specs) {
        expect(spec.fromUtc.hour, 0);
        expect(spec.fromUtc.minute, 0);
      }
    });

    test('hot slices are 7-day chunks covering the range', () {
      final specs = planSlices(
        channel: PaperChannel.hot,
        fromUtc: DateTime.utc(2025, 12, 25),
        toUtc: DateTime.utc(2026, 1, 10),
        branchHash: 'topic',
      );
      expect(specs.length, greaterThanOrEqualTo(2));
      final covered = specs.fold<DateTime>(DateTime.utc(2100),
          (acc, s) => s.fromUtc.isBefore(acc) ? s.fromUtc : acc);
      // `covered` is the lowest bucket start; it must not be after the
      // requested lower bound.
      expect(covered.isAfter(DateTime.utc(2025, 12, 25)), isFalse);
    });

    test('subdivideThreshold splits oversized slices first to days', () {
      final children = splitSlice(SliceSpec(
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 1, 8),
        channel: PaperChannel.hot,
        branchHash: 'topic',
      ));
      expect(children.length, greaterThan(1));
      // Children stay inside the parent range.
      for (final child in children) {
        expect(!child.fromUtc.isAfter(DateTime.utc(2026, 1, 8)), isTrue);
        expect(!child.toUtc.isBefore(DateTime.utc(2026, 1, 1)), isTrue);
      }
    });

    test('minute-level slice cannot split further', () {
      final children = splitSlice(SliceSpec(
        fromUtc: DateTime.utc(2026, 1, 1, 0, 0),
        toUtc: DateTime.utc(2026, 1, 1, 0, 1),
        channel: PaperChannel.hot,
        branchHash: 'topic',
      ));
      expect(children, isEmpty);
    });
  });

  group('rule score', () {
    final groups = [
      PaperKeywordGroup(synonyms: const ['object detection']),
      PaperKeywordGroup(synonyms: const ['knowledge distillation']),
    ];

    test('round(100*(2T+A)/(3N)) and per-field group counted once', () {
      final score = computeRuleScore(
        groups: groups,
        title: 'Object detection via knowledge distillation',
        abstractText: 'We study object detection object detection.',
      );
      // T=2, A=1 -> 100*(4+1)/6 = 83.33 -> 83
      expect(score, 83);
    });

    test('N=0 scores 0', () {
      expect(
        computeRuleScore(groups: const [], title: 'x', abstractText: 'y'),
        0,
      );
    });

    test('score clamps to 0..100', () {
      final score = computeRuleScore(
        groups: groups,
        title: 'object detection knowledge distillation',
        abstractText: 'object detection knowledge distillation',
      );
      expect(score, inInclusiveRange(0, 100));
    });
  });

  group('match evidence', () {
    test('records locally verifiable phrases and the real branch name', () {
      final evidence = buildMatchEvidence(
        groups: [
          PaperKeywordGroup(synonyms: const ['object detection']),
        ],
        title: 'Fast Object Detection',
        abstractText: 'We improve object detection speed.',
        authorBranch: false,
        branchName: 'topic',
      );
      expect(evidence, contains('object detection'));
      expect(evidence, contains('title'));
      expect(evidence, contains('abstract'));
      expect(evidence, contains('topic'));
    });

    test('author branch without phrases falls back to source-returned', () {
      final evidence = buildMatchEvidence(
        groups: const [],
        title: 'Anything',
        abstractText: 'Something',
        authorBranch: true,
        branchName: 'author:Xili Wan',
      );
      expect(evidence, contains('source_returned'));
      // The actual watched author is recorded, not a generic marker.
      expect(evidence, contains('author:Xili Wan'));
    });
  });

  group('discovery evidence merge (R19)', () {
    test('topic then author keeps both branches and phrases', () {
      final topicEvidence = PaperTaskMatch.encodeEvidence(
        titlePhrases: const {
          'g0': ['object detection'],
        },
        abstractPhrases: const {},
        branches: const ['topic'],
      );
      final authorEvidence = PaperTaskMatch.encodeEvidence(
        titlePhrases: const {},
        abstractPhrases: const {},
        sourceReturnedOnly: const ['source_returned'],
        branches: const ['author:Xili Wan'],
      );

      final merged = PaperTaskMatch.mergeEvidence(
        topicEvidence,
        authorEvidence,
        incomingBranch: 'author:Xili Wan',
      );
      expect(merged, contains('object detection'));
      expect(merged, contains('topic'));
      expect(merged, contains('author:Xili Wan'));
      expect(merged, contains('source_returned'));
    });

    test('author then topic keeps the author marker', () {
      final authorEvidence = PaperTaskMatch.encodeEvidence(
        titlePhrases: const {},
        abstractPhrases: const {},
        sourceReturnedOnly: const ['source_returned'],
        branches: const ['author:Alice Zhang'],
      );
      final topicEvidence = PaperTaskMatch.encodeEvidence(
        titlePhrases: const {
          'g0': ['knowledge distillation'],
        },
        abstractPhrases: const {},
        branches: const ['topic'],
      );
      final merged = PaperTaskMatch.mergeEvidence(
        authorEvidence,
        topicEvidence,
        incomingBranch: 'topic',
      );
      expect(merged, contains('author:Alice Zhang'));
      expect(merged, contains('knowledge distillation'));
    });

    test('two watched authors both survive', () {
      final a = PaperTaskMatch.encodeEvidence(
        titlePhrases: const {},
        abstractPhrases: const {},
        sourceReturnedOnly: const ['source_returned'],
        branches: const ['author:A'],
      );
      final b = PaperTaskMatch.encodeEvidence(
        titlePhrases: const {},
        abstractPhrases: const {},
        sourceReturnedOnly: const ['source_returned'],
        branches: const ['author:B'],
      );
      final merged =
          PaperTaskMatch.mergeEvidence(a, b, incomingBranch: 'author:B');
      expect(merged, contains('author:A'));
      expect(merged, contains('author:B'));
    });
  });

  group('task branches', () {
    test('topic and each watched author are separate branches', () {
      final config = PaperTaskConfig(
        keywordGroups: [
          PaperKeywordGroup(synonyms: const ['object detection']),
        ],
        authors: const [
          PaperAuthorWatch(name: 'Xili Wan', aliases: ['X Wan']),
          PaperAuthorWatch(name: 'Alice Zhang'),
        ],
        categories: const ['cs.CV'],
      );
      final branches = buildTaskBranches(config);
      expect(branches.map((b) => b.name).toList(),
          ['topic', 'author:Xili Wan', 'author:Alice Zhang']);
      expect(branches.first.searchQuery, startsWith('cat:cs.CV'));
      expect(branches[1].searchQuery, contains('au:"X Wan"'));
      // Author branch is never constrained by topic keywords or categories.
      expect(branches[1].searchQuery, isNot(contains('cat:')));
      expect(branches[1].searchQuery, isNot(contains('ti:')));
    });

    test('config without executable conditions yields no branches', () {
      final config =
          const PaperTaskConfig(researchTopic: 'only natural language');
      expect(buildTaskBranches(config), isEmpty);
    });
  });

  group('task config revision semantics', () {
    test('changing keywords bumps query revision requirement', () {
      const a = PaperTaskConfig(keywordGroups: [
        PaperKeywordGroup(synonyms: ['a']),
      ]);
      const b = PaperTaskConfig(keywordGroups: [
        PaperKeywordGroup(synonyms: ['b']),
      ]);
      expect(taskConfigChangesQuery(a, b), isTrue);
    });

    test('changing window size alone does not change the query', () {
      const a = PaperTaskConfig(latestWindowDays: 30);
      const b = PaperTaskConfig(latestWindowDays: 60);
      expect(taskConfigChangesQuery(a, b), isFalse);
    });

    test('changing research topic changes the query', () {
      const a = PaperTaskConfig(researchTopic: 'vision');
      const b = PaperTaskConfig(researchTopic: 'materials');
      expect(taskConfigChangesQuery(a, b), isTrue);
    });
  });
}
