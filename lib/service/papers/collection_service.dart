import 'dart:convert';

import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/utils/log/common.dart';

/// Deterministic local rule score used only for pending-analysis ordering.
///
/// N = keyword group count, T = groups hitting the title, A = groups hitting
/// the abstract; `round(100 * (2*T + A) / (3*N))`. Each group counts at most
/// once per field. N == 0 scores 0 (author/category discovery is kept
/// visible through its branch flag instead of the score).
int computeRuleScore({
  required List<PaperKeywordGroup> groups,
  required String title,
  required String abstractText,
}) {
  final n = groups.length;
  if (n == 0) return 0;
  final lowerTitle = title.toLowerCase();
  final lowerAbstract = abstractText.toLowerCase();
  var t = 0;
  var a = 0;
  for (final group in groups) {
    var hitTitle = false;
    var hitAbstract = false;
    for (final synonym in group.synonyms) {
      final needle = synonym.trim().toLowerCase();
      if (needle.isEmpty) continue;
      if (!hitTitle && lowerTitle.contains(needle)) hitTitle = true;
      if (!hitAbstract && lowerAbstract.contains(needle)) hitAbstract = true;
    }
    if (hitTitle) t++;
    if (hitAbstract) a++;
  }
  final score = (100 * (2 * t + a) / (3 * n)).round();
  return score.clamp(0, 100);
}

/// Locally verifiable phrase evidence for a match. When the source returned
/// the entry for this branch but no configured phrase occurs in the title
/// or abstract, the evidence records "source returned" instead of
/// inventing a precise hit. [branchName] is the actual query channel
/// (`topic` or `author:<name>`), not a generic enum.
String buildMatchEvidence({
  required List<PaperKeywordGroup> groups,
  required String title,
  required String abstractText,
  required bool authorBranch,
  required String branchName,
}) {
  final titleHits = <String, List<String>>{};
  final abstractHits = <String, List<String>>{};
  var anyPhrase = false;
  for (var i = 0; i < groups.length; i++) {
    final label = 'g$i';
    for (final synonym in groups[i].synonyms) {
      final needle = synonym.trim();
      if (needle.isEmpty) continue;
      if (title.toLowerCase().contains(needle.toLowerCase())) {
        (titleHits[label] ??= <String>[]).add(needle);
        anyPhrase = true;
      }
      if (abstractText.toLowerCase().contains(needle.toLowerCase())) {
        (abstractHits[label] ??= <String>[]).add(needle);
        anyPhrase = true;
      }
    }
  }
  return PaperTaskMatch.encodeEvidence(
    titlePhrases: titleHits,
    abstractPhrases: abstractHits,
    sourceReturnedOnly:
        (anyPhrase || !authorBranch) ? null : const ['source_returned'],
    branches: [branchName],
  );
}

/// One discovery branch of a task: either the topic branch or one watched
/// author (aliases OR-ed inside the branch).
class TaskBranch {
  const TaskBranch({
    required this.name,
    required this.searchQuery,
    required this.isAuthor,
  });

  final String name;
  final String searchQuery;
  final bool isAuthor;
}

/// Expand a saved task config into independent search branches.
List<TaskBranch> buildTaskBranches(PaperTaskConfig config) {
  final branches = <TaskBranch>[];
  final topic = ArxivQueryBuilder.topicQuery(
    keywordGroups:
        config.keywordGroups.map((g) => g.synonyms).toList(growable: false),
    categories: config.categories,
    groupOperatorOr: config.groupOperatorOr,
  );
  if (topic.isNotEmpty) {
    branches.add(TaskBranch(
      name: 'topic',
      searchQuery: topic,
      isAuthor: false,
    ));
  }
  for (final author in config.authors) {
    final query = ArxivQueryBuilder.authorQuery([
      [author.name, ...author.aliases],
    ]);
    if (query.isEmpty) continue;
    branches.add(TaskBranch(
      name: 'author:${author.name}',
      searchQuery: query,
      isAuthor: true,
    ));
  }
  return branches;
}

/// Resolved run windows for both channels (fixed at run start).
class RunWindows {
  const RunWindows({
    required this.latestFrom,
    required this.latestTo,
    required this.hotFrom,
    required this.hotTo,
  });

  final DateTime latestFrom;
  final DateTime latestTo;
  final DateTime hotFrom;
  final DateTime hotTo;

  Map<String, dynamic> toJson() => {
        'latest_from': latestFrom.toUtc().toIso8601String(),
        'latest_to': latestTo.toUtc().toIso8601String(),
        'hot_from': hotFrom.toUtc().toIso8601String(),
        'hot_to': hotTo.toUtc().toIso8601String(),
      };
}

/// Subtract [months] calendar months, clamping the day to the target
/// month's last day (e.g. Mar 31 minus 1 month = Feb 28/29).
DateTime subtractCalendarMonths(DateTime fromUtc, int months) {
  final u = fromUtc.toUtc();
  var year = u.year;
  var month = u.month - months;
  while (month <= 0) {
    month += 12;
    year -= 1;
  }
  final lastDay = _lastDayOfMonth(year, month);
  final day = u.day > lastDay ? lastDay : u.day;
  return DateTime.utc(
      year, month, day, u.hour, u.minute, u.second, u.millisecond);
}

int _lastDayOfMonth(int year, int month) {
  final next = month == 12
      ? DateTime.utc(year + 1, 1, 1)
      : DateTime.utc(year, month + 1, 1);
  return next.subtract(const Duration(days: 1)).day;
}

/// Floor to the start of the UTC day containing [t].
DateTime utcDayFloor(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day);
}

/// Compute run windows for a task at [now].
///
/// latest covers the UNION of the configured lookback and the gap since
/// the last successful watermark (minus the 7-day delayed-indexing
/// overlap): expanding the window adds the new difference, and a long
/// shutdown covers the interval between watermark and now. Completed
/// stable slices are reused, so planning the union does not re-query
/// covered ranges.
RunWindows computeWindows({
  required PaperTaskConfig config,
  required DateTime now,
  bool isFirstRun = true,
  DateTime? latestWatermark,
}) {
  final nowUtc = now.toUtc();
  final latestTo = nowUtc;
  final fullLookback = nowUtc.subtract(Duration(days: config.latestWindowDays));
  // Union: configured window AND watermark-7d (for shutdown gaps).
  var latestFrom = fullLookback;
  if (latestWatermark != null) {
    final fromWatermark =
        latestWatermark.toUtc().subtract(const Duration(days: 7));
    if (fromWatermark.isBefore(latestFrom)) {
      latestFrom = fromWatermark;
    }
  }

  final hotTo = nowUtc;
  final hotFrom = subtractCalendarMonths(nowUtc, config.hotWindowMonths);

  return RunWindows(
    latestFrom: latestFrom,
    latestTo: latestTo,
    hotFrom: hotFrom,
    hotTo: hotTo,
  );
}

/// A time slice to scan. Slice ranges are UTC-anchored buckets (whole days
/// for latest, whole 7-day multiples for hot) so identical plans across
/// runs reuse completed rows via the UNIQUE slice key.
class SliceSpec {
  const SliceSpec({
    required this.fromUtc,
    required this.toUtc,
    required this.channel,
    required this.branchHash,
  });

  final DateTime fromUtc;
  final DateTime toUtc;
  final PaperChannel channel;
  final String branchHash;
}

/// Bucket size for a channel: latest uses 1-day buckets, hot uses 7-day
/// buckets. Bucket edges are anchored to UTC midnight multiples of the
/// bucket size measured from the Unix epoch, so they do not float with the
/// clock and previous runs' completed slices are reusable.
Duration bucketSizeOf(PaperChannel channel) => channel == PaperChannel.hot
    ? const Duration(days: 7)
    : const Duration(days: 1);

DateTime bucketStartFloor(DateTime t, Duration bucket) {
  final day = utcDayFloor(t);
  if (bucket == const Duration(days: 1)) return day;
  // 7-day buckets aligned to days-since-epoch multiples of 7.
  final epochDay = DateTime.utc(1970, 1, 1);
  final days = day.difference(epochDay).inDays;
  final aligned = days - ((days % 7) + 7) % 7;
  return epochDay.add(Duration(days: aligned));
}

/// Plan fixed buckets covering [fromUtc]..[toUtc] for one branch, newest
/// first. Every bucket is a closed-open UTC range [start, start+bucket)
/// that may extend slightly past `toUtc`/before `fromUtc` to keep edges
/// stable; queries still filter by `submittedDate`, so extra range is
/// harmless. Each bucket strictly advances toward the past, so the loop
/// always terminates.
List<SliceSpec> planSlices({
  required PaperChannel channel,
  required DateTime fromUtc,
  required DateTime toUtc,
  required String branchHash,
}) {
  final bucket = bucketSizeOf(channel);
  final specs = <SliceSpec>[];
  if (!toUtc.isAfter(fromUtc)) return specs;

  var end = bucketStartFloor(toUtc, bucket).add(bucket); // end of newest bucket
  final lowerBound = bucketStartFloor(fromUtc, bucket);
  while (end.isAfter(lowerBound)) {
    final start = end.subtract(bucket);
    specs.add(SliceSpec(
      fromUtc: start,
      toUtc: end,
      channel: channel,
      branchHash: branchHash,
    ));
    // Strict progress toward the past; the lower bucket is the last one.
    if (!start.isAfter(lowerBound)) break;
    end = start;
  }
  return specs;
}

/// Subdivide an oversized slice: 7-day -> day -> hour -> minute. Children
/// are strictly smaller than the parent and cover it without gaps. A
/// minute-level slice cannot be subdivided (returns empty).
List<SliceSpec> splitSlice(SliceSpec spec) {
  final span = spec.toUtc.difference(spec.fromUtc);
  if (span > const Duration(days: 1)) {
    // Day-bucket children (also used when a 7-day hot slice is oversized).
    return _fixedBuckets(spec.fromUtc, spec.toUtc, const Duration(days: 1),
        spec.channel, spec.branchHash);
  }
  if (span > const Duration(hours: 1)) {
    return _fixedBuckets(spec.fromUtc, spec.toUtc, const Duration(hours: 1),
        spec.channel, spec.branchHash);
  }
  if (span > const Duration(minutes: 1)) {
    return _fixedBuckets(spec.fromUtc, spec.toUtc, const Duration(minutes: 1),
        spec.channel, spec.branchHash);
  }
  return const [];
}

/// Children of a parent slice at fixed [step] size, strictly inside the
/// parent range (never equal to it).
List<SliceSpec> _fixedBuckets(
  DateTime fromUtc,
  DateTime toUtc,
  Duration step,
  PaperChannel channel,
  String branchHash,
) {
  final specs = <SliceSpec>[];
  if (step <= Duration.zero || !toUtc.isAfter(fromUtc)) return specs;
  var end = toUtc;
  while (end.isAfter(fromUtc)) {
    var start = end.subtract(step);
    if (start.isBefore(fromUtc)) start = fromUtc;
    if (start.isBefore(end)) {
      specs.add(SliceSpec(
        fromUtc: start,
        toUtc: end,
        channel: channel,
        branchHash: branchHash,
      ));
    }
    // Strict progress; stop when the lower edge is reached.
    if (!start.isAfter(fromUtc)) break;
    end = start;
  }
  return specs;
}

/// Why a scan stopped; drives run status and slice bookkeeping.
enum ScanStopReason {
  completed,
  failed,
  cancelled,
  sourceLimit,
  split,
}

/// Result of scanning one slice. [children] lists sub-slices created for an
/// oversized parent; the caller must schedule them immediately and must not
/// claim coverage of the parent until every child completes.
class SliceScanOutcome {
  const SliceScanOutcome(
    this.reason, {
    this.failureClass,
    this.children = const [],
  });

  final ScanStopReason reason;
  final String? failureClass;
  final List<PaperScanSlice> children;
}

/// Scans task branches across time slices with resumable per-page commits.
class CollectionService {
  CollectionService({
    ArxivClient? client,
    required this.nowUtc,
    this.isCancelled,
  }) : _client = client ?? ArxivClient();

  final ArxivClient _client;

  /// Clock injection point for tests (fake clock).
  final DateTime Function() nowUtc;
  final bool Function()? isCancelled;

  static const int subdivideThreshold = 1000;
  static const int maxEntriesPerSliceTurn = 100 * 50;

  /// Hot historical recheck work re-queued per run; the rest waits for the
  /// next tick so a full-window recheck never monopolizes one turn.
  static const int hotRecheckBudgetPerRun = 10;

  bool get _cancelled => isCancelled?.call() ?? false;

  /// Scan one slice of one branch to completion (or failure). Each page is
  /// committed atomically: papers upsert, discovery matches, pagination
  /// checkpoint. The checkpoint never advances without a committed page.
  ///
  /// Interrupted or pending slices restart from page 0: dynamic sources
  /// change offsets, so re-scan plus dedup is safer than trusting an old
  /// offset. The caller must honor `nextRetryAt` before invoking again.
  Future<SliceScanOutcome> scanSlice({
    required PaperTask task,
    required PaperScanSlice slice,
    required TaskBranch branch,
    required PaperRun run,
  }) async {
    final config = task.config;
    var now = nowUtc();

    if (slice.status == PaperSliceStatus.interrupted ||
        slice.status == PaperSliceStatus.pending ||
        slice.status == PaperSliceStatus.failed) {
      // Re-scan from the first page (see doc comment).
      slice.startIndex = 0;
    }
    slice.status = PaperSliceStatus.running;
    slice.lastCheckedAt = now;
    await PaperSliceDao().update(slice);

    try {
      if (_cancelled) return await _interruptSlice(slice);
      final probe = await _client.fetchPage(
        searchQuery: slice.requestQuery,
        start: 0,
        maxResults: 1,
      );

      // Subdivide oversized slices before paging through them.
      if (probe.totalResults > subdivideThreshold) {
        final children = splitSlice(SliceSpec(
          fromUtc: slice.fromUtc,
          toUtc: slice.toUtc,
          channel: slice.channel,
          branchHash: slice.branchHash,
        ));
        if (children.isNotEmpty) {
          final dao = PaperSliceDao();
          final childRows = <PaperScanSlice>[];
          for (final child in children) {
            final id = await dao.ensure(PaperScanSlice(
              sliceId: 0,
              taskId: slice.taskId,
              revision: slice.revision,
              channel: child.channel,
              branchHash: child.branchHash,
              fromUtc: child.fromUtc,
              toUtc: child.toUtc,
              requestQuery: ArxivQueryBuilder.withDateRange(
                branch.searchQuery,
                child.fromUtc,
                child.toUtc,
              ),
              status: PaperSliceStatus.pending,
            ));
            childRows.add(PaperScanSlice(
              sliceId: id,
              taskId: slice.taskId,
              revision: slice.revision,
              channel: child.channel,
              branchHash: child.branchHash,
              fromUtc: child.fromUtc,
              toUtc: child.toUtc,
              requestQuery: ArxivQueryBuilder.withDateRange(
                branch.searchQuery,
                child.fromUtc,
                child.toUtc,
              ),
              status: PaperSliceStatus.pending,
            ));
          }
          // The parent records the split and stays non-covering until every
          // child completes (coverage walks children of split parents).
          slice.status = PaperSliceStatus.completed;
          slice.failureClass = 'split';
          slice.totalReported = probe.totalResults;
          await dao.update(slice);
          AnxLog.info(
              'Collection: split slice ${slice.fromUtc}..${slice.toUtc} '
              '(${probe.totalResults} results) into ${children.length} children');
          return SliceScanOutcome(ScanStopReason.split,
              children: childRows, failureClass: 'split');
        }
        // Minute granularity and still oversized: cannot claim coverage.
        slice.status = PaperSliceStatus.completed;
        slice.sourceLimit = true;
        slice.totalReported = probe.totalResults;
        slice.failureClass = 'source_limit';
        await PaperSliceDao().update(slice);
        return const SliceScanOutcome(ScanStopReason.sourceLimit,
            failureClass: 'source_limit');
      }

      var start = 0;
      int? observedTotal = probe.totalResults < 0 ? null : probe.totalResults;
      var inserted = slice.insertedCount;
      final seenIds = <String>{};
      var processed = 0;

      while (true) {
        if (_cancelled) {
          slice.status = PaperSliceStatus.interrupted;
          await PaperSliceDao().update(slice);
          return const SliceScanOutcome(ScanStopReason.cancelled);
        }

        final page = await _client.fetchPage(
          searchQuery: slice.requestQuery,
          start: start,
        );
        final total = page.totalResults < 0 ? observedTotal : page.totalResults;

        // Total drift: the source's view changed mid-traversal. Restart the
        // slice from 0 (dedup by stable id absorbs overlaps).
        if (observedTotal != null &&
            total != null &&
            total != observedTotal &&
            start > 0) {
          AnxLog.warning(
              'Collection: total drift $observedTotal -> $total, restarting slice');
          slice.status = PaperSliceStatus.interrupted;
          slice.startIndex = 0;
          await PaperSliceDao().update(slice);
          return await scanSlice(
              task: task, slice: slice, branch: branch, run: run);
        }
        observedTotal = total;

        // Empty page before the end is an anomaly: do not advance the whole
        // slice watermark on it.
        if (page.entries.isEmpty) {
          if (total != null && start < total) {
            slice.status = PaperSliceStatus.failed;
            slice.failureClass = 'empty_page_anomaly';
            slice.nextRetryAt = nowUtc().add(const Duration(minutes: 30));
            await PaperSliceDao().update(slice);
            return const SliceScanOutcome(ScanStopReason.failed,
                failureClass: 'empty_page_anomaly');
          }
          break;
        }

        final papers = <Paper>[];
        final matches = <PaperTaskMatch>[];
        for (final entry in page.entries) {
          if (!seenIds.add(entry.arxivId)) {
            // Boundary overlap between slices: dedup by stable id.
            continue;
          }
          final contentHash = Paper.contentHashOf(
            title: entry.title,
            abstractText: entry.abstractText,
            authors: entry.authors,
            categories: entry.categories,
          );
          final paper = Paper(
            arxivId: entry.arxivId,
            latestVersion: entry.version,
            title: entry.title,
            authors: entry.authors,
            abstractText: entry.abstractText,
            categories: entry.categories,
            publishedAt: entry.publishedAt,
            updatedAt: entry.updatedAt,
            absUrl: entry.absUrl,
            pdfUrl: ArxivQueryBuilder.normalizePdfUrl(entry.pdfUrl)?.toString(),
            doi: entry.doi,
            journalRef: entry.journalRef,
            contentHash: contentHash,
            firstSeenAt: now,
            lastSeenAt: now,
          );
          papers.add(paper);
          matches.add(PaperTaskMatch(
            id: 0,
            taskId: task.taskId,
            queryRevision: task.queryRevision,
            arxivId: entry.arxivId,
            branch: branch.isAuthor
                ? PaperMatchBranch.author
                : (branch.name == 'topic'
                    ? PaperMatchBranch.topic
                    : PaperMatchBranch.category),
            evidenceJson: buildMatchEvidence(
              groups: config.keywordGroups,
              title: entry.title,
              abstractText: entry.abstractText,
              authorBranch: branch.isAuthor,
              branchName: branch.name,
            ),
            firstSeenAt: now,
            lastSeenAt: now,
            ruleScore: branch.isAuthor
                ? 0
                : computeRuleScore(
                    groups: config.keywordGroups,
                    title: entry.title,
                    abstractText: entry.abstractText,
                  ),
          ));
        }

        start += page.entries.length;
        processed += page.entries.length;
        inserted += papers.length;
        slice.startIndex = start;
        slice.insertedCount = inserted;
        slice.totalReported = total;
        slice.status = PaperSliceStatus.running;

        // Reject late commits after pause/shutdown: only pages committed
        // before the cancellation stay recorded.
        if (_cancelled) {
          slice.status = PaperSliceStatus.interrupted;
          await PaperSliceDao().update(slice);
          return const SliceScanOutcome(ScanStopReason.cancelled);
        }

        // One transaction per page: upserts + matches + breakpoint.
        await commitScanPage(
          taskId: task.taskId,
          revision: task.queryRevision,
          channel: slice.channel,
          branchHash: slice.branchHash,
          slice: slice,
          papers: papers,
          matches: matches,
          nowUtc: nowUtc(),
        );

        if (total != null && start >= total) break;
        if (page.entries.isEmpty) break;
        if (processed >= maxEntriesPerSliceTurn) {
          // Defensive budget for one turn; the slice stays resumable.
          slice.status = PaperSliceStatus.interrupted;
          await PaperSliceDao().update(slice);
          return const SliceScanOutcome(ScanStopReason.cancelled);
        }
      }

      now = nowUtc();
      slice.status = PaperSliceStatus.completed;
      slice.failureClass = null;
      slice.nextRetryAt = null;
      // Coverage ends at the probe time, before later pages can observe additions.
      await PaperSliceDao().update(slice);
      return const SliceScanOutcome(ScanStopReason.completed);
    } on ArxivException catch (e) {
      if (_cancelled) return _interruptSlice(slice);
      slice.status = PaperSliceStatus.failed;
      slice.failureClass = e.retriable ? 'network' : 'source_error';
      slice.nextRetryAt = nowUtc().add(const Duration(hours: 1));
      await PaperSliceDao().update(slice);
      AnxLog.warning('Collection: slice failed: $e');
      return SliceScanOutcome(ScanStopReason.failed,
          failureClass: slice.failureClass);
    } catch (e) {
      if (_cancelled) return _interruptSlice(slice);
      slice.status = PaperSliceStatus.failed;
      slice.failureClass = 'unexpected';
      slice.nextRetryAt = nowUtc().add(const Duration(hours: 1));
      await PaperSliceDao().update(slice);
      AnxLog.severe('Collection: slice unexpected failure: $e');
      return const SliceScanOutcome(ScanStopReason.failed,
          failureClass: 'unexpected');
    }
  }

  Future<SliceScanOutcome> _interruptSlice(PaperScanSlice slice) async {
    slice.status = PaperSliceStatus.interrupted;
    slice.failureClass = 'cancelled';
    slice.nextRetryAt = null;
    await PaperSliceDao().update(slice);
    return const SliceScanOutcome(ScanStopReason.cancelled);
  }

  /// Ensure slice rows exist for every branch of this task/revision/channel
  /// covering [fromUtc]..[toUtc], reusing existing rows. Returns rows
  /// ordered newest-slice-first for scanning.
  Future<List<PaperScanSlice>> ensureSlices({
    required PaperTask task,
    required PaperChannel channel,
    required DateTime fromUtc,
    required DateTime toUtc,
  }) async {
    final dao = PaperSliceDao();
    for (final branch in buildTaskBranches(task.config)) {
      final specs = planSlices(
        channel: channel,
        fromUtc: fromUtc,
        toUtc: toUtc,
        branchHash: branch.name,
      );
      for (final spec in specs) {
        await dao.ensure(PaperScanSlice(
          sliceId: 0,
          taskId: task.taskId,
          revision: task.queryRevision,
          channel: spec.channel,
          branchHash: spec.branchHash,
          fromUtc: spec.fromUtc,
          toUtc: spec.toUtc,
          requestQuery: ArxivQueryBuilder.withDateRange(
            branch.searchQuery,
            spec.fromUtc,
            spec.toUtc,
          ),
          status: PaperSliceStatus.pending,
        ));
      }
    }
    final all = await dao.selectByTask(task.taskId);
    final relevant = all
        .where((s) =>
            s.revision == task.queryRevision &&
            s.channel == channel &&
            s.toUtc.isAfter(fromUtc) &&
            s.fromUtc.isBefore(toUtc))
        .toList();
    relevant.sort((a, b) => b.fromUtc.compareTo(a.fromUtc));
    return relevant;
  }

  /// Coverage for one channel of one task revision over [fromUtc]..[toUtc]:
  /// every branch's planned bucket intersecting the window must be
  /// completed, and split parents count as covering only when every child
  /// is completed. Failed, interrupted and source-limited slices make the
  /// channel incomplete — they are never ignored.
  Future<bool> isChannelCovered({
    required PaperTask task,
    required PaperChannel channel,
    required DateTime fromUtc,
    required DateTime toUtc,
  }) async {
    final rows = await PaperSliceDao().selectByTask(task.taskId);
    final mine = rows
        .where((r) =>
            r.revision == task.queryRevision &&
            r.channel == channel &&
            r.toUtc.isAfter(fromUtc) &&
            r.fromUtc.isBefore(toUtc))
        .toList();

    final branches = buildTaskBranches(task.config);
    if (branches.isEmpty) return false;

    for (final branch in branches) {
      final specs = planSlices(
        channel: channel,
        fromUtc: fromUtc,
        toUtc: toUtc,
        branchHash: branch.name,
      );
      for (final spec in specs) {
        final slice = _findSlice(mine, spec, branch.name);
        if (slice == null) return false;
        final ok = await _sliceCovers(slice, mine);
        if (!ok) return false;
      }
    }
    return true;
  }

  PaperScanSlice? _findSlice(
      List<PaperScanSlice> rows, SliceSpec spec, String branchHash) {
    for (final row in rows) {
      if (row.branchHash != branchHash) continue;
      if (row.fromUtc == spec.fromUtc && row.toUtc == spec.toUtc) return row;
    }
    return null;
  }

  Future<bool> _sliceCovers(
      PaperScanSlice slice, List<PaperScanSlice> siblings) async {
    if (slice.sourceLimit) return false;
    if (slice.status != PaperSliceStatus.completed) return false;
    if (slice.failureClass != 'split') return true;
    // Split parent: every child inside its range must be completed.
    final children = siblings
        .where((s) =>
            s.branchHash == slice.branchHash &&
            !s.fromUtc.isBefore(slice.fromUtc) &&
            !s.toUtc.isAfter(slice.toUtc) &&
            !(s.fromUtc == slice.fromUtc && s.toUtc == slice.toUtc))
        .toList();
    if (children.isEmpty) return false;
    for (final child in children) {
      if (!await _sliceCovers(child, siblings)) return false;
    }
    return true;
  }

  /// Coverage watermark for a channel: the highest point such that every
  /// branch has a contiguous chain of completed (and non-source-limited)
  /// slices up to it. A completed slice only proves data that was visible
  /// when it finished, so the chain end is capped by BOTH the bucket edge
  /// and the slice's actual scanned cutoff (`lastCheckedAt`) — a bucket
  /// completed at t1 never proves coverage up to t2 while still open.
  Future<DateTime?> coverageWatermark({
    required PaperTask task,
    required PaperChannel channel,
    DateTime? cutoff,
  }) async {
    final rows = await PaperSliceDao().selectByTask(task.taskId);
    final cap = cutoff ?? nowUtc();
    final branches = buildTaskBranches(task.config);
    if (branches.isEmpty) return null;

    DateTime? overall;
    for (final branch in branches) {
      // Leaf slices only: split parents are superseded by their children.
      final mine = rows
          .where((r) =>
              r.revision == task.queryRevision &&
              r.channel == channel &&
              r.branchHash == branch.name &&
              r.status == PaperSliceStatus.completed &&
              !r.sourceLimit &&
              r.failureClass != 'split')
          .toList()
        ..sort((a, b) => a.fromUtc.compareTo(b.fromUtc));
      if (mine.isEmpty) return null;

      // Walk a contiguous chain from the earliest completed bucket. The
      // frontier is limited by each slice's actual scanned cutoff.
      var chainEnd = _effectiveEnd(mine.first);
      for (final slice in mine.skip(1)) {
        if (slice.fromUtc.isAfter(chainEnd)) break; // gap
        final end = _effectiveEnd(slice);
        if (end.isAfter(chainEnd)) chainEnd = end;
      }
      final capped = chainEnd.isAfter(cap) ? cap : chainEnd;
      if (overall == null || capped.isBefore(overall)) {
        overall = capped;
      }
    }
    return overall;
  }

  /// What a completed slice actually proves: at most its bucket end, and
  /// at most the moment its scan finished.
  DateTime _effectiveEnd(PaperScanSlice slice) {
    final scanned = slice.lastCheckedAt;
    final end = slice.toUtc;
    if (scanned == null) return end;
    return scanned.isBefore(end) ? scanned : end;
  }

  /// Re-open slices that need periodic re-scan:
  /// - latest: the last 7 days every run (delayed indexing);
  /// - hot: the CURRENT bucket every run (new dates appear inside it);
  /// - hot history: a bounded slice per run, walked with a persisted
  ///   cursor so a 52-bucket window makes progress across runs instead of
  ///   re-opening the same first ten forever. The cycle marker advances
  ///   only after every bucket has been re-queued.
  Future<void> schedulePeriodicRecheck({
    required PaperTask task,
    required RunWindows windows,
    required DateTime now,
  }) async {
    final dao = PaperSliceDao();
    final rows = await dao.selectByTask(task.taskId);
    final nowUtc = now.toUtc();

    // Latest: always re-scan the last 7 days to absorb delayed indexing.
    final recentFrom = nowUtc.subtract(const Duration(days: 7));
    for (final row in rows) {
      if (row.revision != task.queryRevision) continue;
      if (row.channel != PaperChannel.latest) continue;
      if (row.failureClass == 'split') continue;
      if (row.fromUtc.isBefore(windows.latestTo) &&
          row.toUtc.isAfter(recentFrom)) {
        if (row.status == PaperSliceStatus.completed) {
          row.status = PaperSliceStatus.pending;
          row.failureClass = null;
          await dao.update(row);
        }
      }
    }

    // Hot current bucket: re-open it every run so dates published after
    // the first scan of this bucket are picked up ("每日补入新日期").
    for (final row in rows) {
      if (row.revision != task.queryRevision) continue;
      if (row.channel != PaperChannel.hot) continue;
      if (row.failureClass == 'split') continue;
      if (!nowUtc.isBefore(row.toUtc) && row.fromUtc.isAfter(nowUtc)) {
        continue; // outside
      }
      final isCurrent =
          !nowUtc.isBefore(row.fromUtc) && nowUtc.isBefore(row.toUtc);
      if (isCurrent && row.status == PaperSliceStatus.completed) {
        row.status = PaperSliceStatus.pending;
        row.failureClass = null;
        await dao.update(row);
      }
    }

    // Hot history: one cycle re-queues every bucket in the window exactly
    // once, in bounded steps identified by a persisted epoch+cursor.
    final keyBase = '${task.taskId}_r${task.queryRevision}';
    final epochKey = 'hot_recheck_epoch_$keyBase';
    final cursorKey = 'hot_recheck_cursor_$keyBase';

    final entries = await _readCursorEntries({epochKey, cursorKey});
    DateTime? epoch;
    final epochRaw = entries[epochKey];
    if (epochRaw is String) epoch = DateTime.tryParse(epochRaw);
    var pendingIds = entries[cursorKey] is List
        ? (entries[cursorKey] as List).whereType<int>().toList()
        : <int>[];

    // Candidate order is stable (newest first): positional cursor is
    // meaningful even as slices change status between runs.
    final candidates = rows
        .where((r) =>
            r.revision == task.queryRevision &&
            r.channel == PaperChannel.hot &&
            r.failureClass != 'split' &&
            r.fromUtc.isBefore(windows.hotTo) &&
            r.toUtc.isAfter(windows.hotFrom))
        .toList()
      ..sort((a, b) {
        final byFrom = b.fromUtc.compareTo(a.fromUtc);
        if (byFrom != 0) return byFrom;
        return a.branchHash.compareTo(b.branchHash);
      });

    final cycleDue = pendingIds.isNotEmpty ||
        epoch == null ||
        nowUtc.difference(epoch).inDays >= 7;
    if (cycleDue) {
      if (pendingIds.isEmpty) {
        pendingIds = candidates.map((row) => row.sliceId).toList();
      }
      var budget = hotRecheckBudgetPerRun;
      final byId = {for (final row in candidates) row.sliceId: row};
      while (budget > 0 && pendingIds.isNotEmpty) {
        final id = pendingIds.first;
        final row = byId[id];
        budget--;
        if (row != null && row.status == PaperSliceStatus.completed) {
          row.status = PaperSliceStatus.pending;
          row.failureClass = null;
          await dao.update(row);
        }
        pendingIds.removeAt(0);
        // Save after the requeue: interruption may repeat work, never skip it.
        await _writeCursorEntries({cursorKey: pendingIds});
      }
      if (pendingIds.isEmpty) {
        // Whole window re-queued: advance the cycle marker only now.
        await _writeCursorEntries({
          epochKey: nowUtc.toIso8601String(),
          cursorKey: <int>[],
        });
      } else {
        await _writeCursorEntries({
          cursorKey: pendingIds,
        });
      }
    }
  }

  Future<Map<String, dynamic>> _readCursorEntries(Set<String> keys) async {
    final settings = await PaperSettingsDao().get();
    final raw = settings.pollerCursorJson;
    final result = <String, dynamic>{};
    if (raw == null || raw.isEmpty) return result;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        for (final key in keys) {
          if (decoded.containsKey(key)) result[key] = decoded[key];
        }
      }
    } catch (_) {}
    return result;
  }

  Future<void> _writeCursorEntries(Map<String, dynamic> entries) async {
    await PaperSettingsDao().updatePollerCursor(entries);
  }
}

String encodeWindows(RunWindows windows) => jsonEncode(windows.toJson());
