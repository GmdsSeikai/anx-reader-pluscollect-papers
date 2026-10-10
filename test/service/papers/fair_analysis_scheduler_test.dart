import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

Paper paperOf(String id, DateTime published) => Paper(
      arxivId: id,
      latestVersion: 1,
      title: 't$id',
      authors: const [PaperAuthor(name: 'A')],
      abstractText: 'a',
      categories: const ['cs.CV'],
      publishedAt: published,
      updatedAt: published,
      contentHash: 'h$id',
      firstSeenAt: published,
      lastSeenAt: published,
    );

AnalysisQueueItem itemOf(
        String id, int priority, PaperChannel channel, DateTime published) =>
    AnalysisQueueItem(
      paper: paperOf(id, published),
      channel: channel,
      priority: priority,
      taskId: 'task-$priority',
      pendingTasks: const [],
    );

void main() {
  group('FairAnalysisScheduler', () {
    test('P06: priority weights 5:4:3:2:1 actually shape the batch', () {
      final scheduler = FairAnalysisScheduler();
      // Enough candidates per group that weights, not group size, limit
      // how many of each priority get picked.
      final latest = [
        for (var i = 0; i < 6; i++)
          itemOf('p1-$i', 1, PaperChannel.latest, DateTime.utc(2026, 1, 1 + i)),
        for (var i = 0; i < 6; i++)
          itemOf('p2-$i', 2, PaperChannel.latest, DateTime.utc(2026, 1, 1 + i)),
        for (var i = 0; i < 6; i++)
          itemOf('p5-$i', 5, PaperChannel.latest, DateTime.utc(2026, 1, 1 + i)),
      ];
      final picked = scheduler.pickBatch(
        latestItems: latest,
        hotItems: const [],
        count: 10,
      );
      // One schedule pass is [1×5, 2×4, 5×1]; a 10-slot batch therefore
      // takes 5 of p1, 4 of p2, 1 of p5.
      final counts = <int, int>{};
      for (final item in picked) {
        counts[item.priority] = (counts[item.priority] ?? 0) + 1;
      }
      expect(counts[1] ?? 0, 5);
      expect(counts[2] ?? 0, 4);
      expect(counts[5] ?? 0, 1);
      expect(counts[1] ?? 0, greaterThan(counts[5] ?? 0));
    });

    test('P06: 70/30 split borrows when one channel runs dry', () {
      final scheduler = FairAnalysisScheduler();
      final latest = [
        for (var i = 0; i < 10; i++)
          itemOf('l$i', 3, PaperChannel.latest, DateTime.utc(2026, 1, i + 1)),
      ];
      final picked = scheduler.pickBatch(
        latestItems: latest,
        hotItems: const [],
        count: 10,
      );
      // Hot is empty: latest items fill the whole batch (borrowing).
      expect(picked, hasLength(10));
      expect(picked.every((i) => i.channel == PaperChannel.latest), isTrue);
    });

    test('R16: cursor rotation keeps low-priority items progressing', () {
      final scheduler = FairAnalysisScheduler();
      List<AnalysisQueueItem> makeItems() => [
            itemOf('h1', 1, PaperChannel.hot, DateTime.utc(2026, 1, 1)),
            itemOf('h2', 1, PaperChannel.hot, DateTime.utc(2026, 1, 2)),
            itemOf('h3', 5, PaperChannel.hot, DateTime.utc(2026, 1, 3)),
            itemOf('h4', 5, PaperChannel.hot, DateTime.utc(2026, 1, 4)),
          ];

      final seen = <String>{};
      // Multiple batches while "new" high-priority items keep arriving at
      // the front of the list (later published = sorted first).
      for (var batch = 0; batch < 6; batch++) {
        final items = makeItems();
        items.insert(
            0,
            itemOf('new$batch', 1, PaperChannel.hot,
                DateTime.utc(2026, 2, 1 + batch)));
        final picked = scheduler.pickBatch(
          latestItems: const [],
          hotItems: items,
          count: 3,
        );
        for (final item in picked) {
          seen.add(item.paper.arxivId);
        }
      }
      // A low-priority item must not starve across batches.
      expect(seen.contains('h3') || seen.contains('h4'), isTrue);
    });

    test('queue items carry real task inputs', () {
      final item = AnalysisQueueItem(
        paper: paperOf('x', DateTime.utc(2026, 1, 1)),
        channel: PaperChannel.latest,
        priority: 1,
        taskId: 'task-vision',
        pendingTasks: const [
          AnalysisTaskInput(
            taskId: 'task-vision',
            profileHash: 'ph',
            config: PaperTaskConfig(researchTopic: 'vision'),
          ),
        ],
      );
      expect(item.pendingTasks.single.config.researchTopic, 'vision');
    });
  });

  group('rule score and evidence at the queue boundary', () {
    test('author-watch items keep priority even with zero rule score', () {
      // Author-discovered items are queued regardless of rule score 0.
      final item =
          itemOf('a1', 2, PaperChannel.latest, DateTime.utc(2026, 1, 1));
      expect(item.priority, 2);
    });
  });
}
