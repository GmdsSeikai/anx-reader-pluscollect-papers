import 'dart:async';
import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/service/papers/citation_service.dart';
import 'package:anx_reader/service/papers/collection_service.dart';
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:anx_reader/service/book.dart'
    show metadataQueueDepth, importWorkDepth;
import 'package:anx_reader/service/db_operation_lock.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

/// Bumped after collection commits so visible lists/details refresh.
final paperDataVersion = StateProvider<int>((ref) => 0);

/// What the papers page observes: never drives the work itself.
class PaperCollectionState {
  const PaperCollectionState({
    this.initialized = false,
    this.enabled = false,
    this.paused = false,
    this.errorMessage,
    this.activeRunIds = const {},
    this.lastTick,
  });

  final bool initialized;
  final bool enabled;
  final bool paused;
  final String? errorMessage;
  final Set<String> activeRunIds;
  final DateTime? lastTick;

  PaperCollectionState copyWith({
    bool? initialized,
    bool? enabled,
    bool? paused,
    String? errorMessage,
    Set<String>? activeRunIds,
    DateTime? lastTick,
  }) {
    return PaperCollectionState(
      initialized: initialized ?? this.initialized,
      enabled: enabled ?? this.enabled,
      paused: paused ?? this.paused,
      errorMessage: errorMessage,
      activeRunIds: activeRunIds ?? this.activeRunIds,
      lastTick: lastTick ?? this.lastTick,
    );
  }
}

/// Application-level, Windows-only, keepAlive owner of the collection
/// scheduler and its queues. Switching pages or minimizing the window does
/// not stop it; closing the process does. No OS timer or background service
/// is ever installed. Startup, repeat runs and shutdown all go through this
/// single owner.
class PaperCollectionController extends Notifier<PaperCollectionState> {
  PaperCollectionController({DateTime Function()? nowUtc})
      : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final DateTime Function() _nowUtc;

  Timer? _tickTimer;
  bool _shuttingDown = false;
  bool _started = false;

  /// Execution tokens per task: pause bumps the token so late responses of
  /// an old run can no longer advance state.
  final Map<String, int> _execTokens = {};

  /// Task-run mutex. Check-and-set is synchronous so two clicks cannot both
  /// pass the gate before either awaits.
  final Set<String> _runningTasks = <String>{};
  final Map<String, ArxivClient> _collectionClients = {};

  /// In-flight owned work. Shutdown drains these before shared resources
  /// are released.
  final Set<Future<void>> _inflight = <Future<void>>{};
  int _importsInFlight = 0;

  final PaperImportService importService = PaperImportService();
  late final CitationService citationService = CitationService(nowUtc: _nowUtc);
  late final AnalysisService analysisService = AnalysisService(nowUtc: _nowUtc);

  bool _citationDraining = false;
  bool _analysisDraining = false;
  bool _metadataDraining = false;

  static const Duration tickInterval = Duration(minutes: 1);
  static const Duration drainTimeout = Duration(seconds: 30);

  @override
  PaperCollectionState build() {
    ref.onDispose(() {
      _tickTimer?.cancel();
      _tickTimer = null;
    });
    return const PaperCollectionState();
  }

  void _track(Future<void> future) {
    _inflight.add(future);
    future.then((_) => _inflight.remove(future),
        onError: (Object _, StackTrace __) => _inflight.remove(future));
  }

  /// Public registration for UI-initiated work (manual runs, manual
  /// analysis, download batches) so shutdown/migration drains it too.
  void trackWork(Future<void> future) {
    _track(future);
  }

  bool get acceptsNewWork =>
      state.enabled &&
      !_shuttingDown &&
      !state.paused &&
      DbOperationLock.instance.acceptsNewWork;

  /// Initialize after paths, prefs, the main DB and the reading server are
  /// ready. Idempotent: the papers page and app init may both call it. A
  /// paper-database failure disables only this feature.
  Future<void> start() async {
    if (!AnxPlatform.isWindows) {
      state = state.copyWith(
          initialized: true, enabled: false, errorMessage: 'windows_only');
      return;
    }
    if (_shuttingDown || _started) return;
    _started = true;
    try {
      await PaperDatabase.instance.open();
    } catch (e) {
      _started = false;
      AnxLog.severe('PaperCollection: database failed to open: $e');
      state = state.copyWith(
          initialized: true,
          enabled: false,
          errorMessage: 'paper_db_failed: $e');
      return;
    }

    try {
      // Interrupted-state recovery after an unclean exit.
      await PaperRunDao().markOpenRunsInterrupted();
      await PaperImportDao().markOpenInterrupted();
      await markOpenSlicesInterrupted();
      // Complete any two-step import whose main-library commit landed but
      // whose paper association did not.
      final interrupted = await PaperImportDao().selectAll();
      final now = _nowUtc();
      for (final record in interrupted) {
        if (record.status == PaperImportStatus.interrupted &&
            record.pdfMd5 != null) {
          try {
            await importService.repairMissingAssociation(
                record: record, nowUtc: now);
          } catch (error) {
            AnxLog.warning(
                'PaperCollection: import recovery failed for ${record.arxivId}: $error');
          }
        }
      }
    } catch (e) {
      AnxLog.warning('PaperCollection: recovery marking failed: $e');
    }

    state =
        state.copyWith(initialized: true, enabled: true, errorMessage: null);
    _tickTimer ??= Timer.periodic(tickInterval, (_) {
      _track(tick());
    });
    _track(tick());
  }

  /// One scheduler pass: start due tasks (priority order) and let the
  /// citation / analysis queues drain opportunistically.
  Future<void> tick() async {
    if (_shuttingDown || state.paused || !state.enabled) return;
    state = state.copyWith(lastTick: _nowUtc());
    try {
      final tasks = await PaperTaskDao().selectAll();
      final due = tasks
          .where((t) =>
              t.enabled &&
              !_runningTasks.contains(t.taskId) &&
              (t.nextRunAt == null || !t.nextRunAt!.isAfter(_nowUtc())))
          .toList();
      due.sort((a, b) {
        if (a.priority != b.priority) return a.priority.compareTo(b.priority);
        final ar = a.nextRunAt?.millisecondsSinceEpoch ?? 0;
        final br = b.nextRunAt?.millisecondsSinceEpoch ?? 0;
        return ar.compareTo(br);
      });
      for (final task in due) {
        if (_runningTasks.contains(task.taskId)) continue;
        _track(runTask(task.taskId, trigger: PaperRunTrigger.schedule)
            .then<void>((_) {})
            .catchError((Object e) {
          AnxLog.warning('PaperCollection: scheduled run failed: $e');
        }));
      }
      _track(_drainCitationQueue());
      _track(_drainAnalysisQueue());
    } catch (e) {
      AnxLog.warning('PaperCollection: tick failed: $e');
    }
  }

  /// Manual run. Bypasses the frequency wait but not rate limits, the
  /// in-exec mutex, or the same-query cache. Returns the current run id
  /// when the task is already running.
  Future<String?> runTask(
    String taskId, {
    PaperRunTrigger trigger = PaperRunTrigger.manual,
  }) async {
    // No new work while paused (covers migration) or shutting down — a
    // manual click must not sneak in beside an in-progress drain.
    if (!acceptsNewWork) return null;
    // Atomic check-and-set before any await.
    if (!_runningTasks.add(taskId)) {
      final open = await PaperRunDao().selectOpen(taskId);
      return open.isEmpty ? null : open.first.runId;
    }
    String? runId;
    try {
      final task = await PaperTaskDao().selectById(taskId);
      if (task == null) return null;
      if (!acceptsNewWork) return null;
      if (!task.enabled && trigger != PaperRunTrigger.manual) return null;

      runId = const Uuid().v4();
      state = state.copyWith(activeRunIds: {...state.activeRunIds, runId});
      final execToken = (_execTokens[taskId] ?? 0) + 1;
      _execTokens[taskId] = execToken;

      final now = _nowUtc();
      final client = ArxivClient();
      _collectionClients[taskId] = client;
      final service = CollectionService(
        client: client,
        nowUtc: _nowUtc,
        // Compare against this run's captured token (no forward reference
        // to `run`, which is created below).
        isCancelled: () =>
            _shuttingDown ||
            state.paused ||
            (_execTokens[task.taskId] ?? 0) != execToken,
      );

      // Coverage watermarks are capped at the actual run cutoff so a
      // future-extending bucket edge never claims coverage beyond it.
      final latestWatermark = await service.coverageWatermark(
          task: task, channel: PaperChannel.latest, cutoff: now);
      final hotWatermark = await service.coverageWatermark(
          task: task, channel: PaperChannel.hot, cutoff: now);
      final isFirstRun = latestWatermark == null && hotWatermark == null;

      final windows = computeWindows(
        config: task.config,
        now: now,
        isFirstRun: isFirstRun,
        latestWatermark: latestWatermark,
      );

      final run = PaperRun(
        runId: runId,
        taskId: taskId,
        queryRevision: task.queryRevision,
        trigger: trigger,
        configSnapshotJson: jsonEncode(task.config.toJson()),
        rangeJson: encodeWindows(windows),
        status: PaperRunStatus.running,
        startedAt: now,
        execToken: execToken,
      );
      await PaperRunDao().upsert(run);

      try {
        final outcome =
            await _executeRun(task, run, windows, service, execToken);
        run.status = switch (outcome) {
          RunOutcome.succeeded => PaperRunStatus.succeeded,
          RunOutcome.partial => PaperRunStatus.partial,
          RunOutcome.failed => PaperRunStatus.failed,
          RunOutcome.cancelled => PaperRunStatus.cancelled,
        };
      } catch (e) {
        AnxLog.severe('PaperCollection: run $runId failed: $e');
        run.status = PaperRunStatus.failed;
        run.failureClass = 'unexpected';
      } finally {
        run.finishedAt = _nowUtc();
        await PaperRunDao().upsert(run);
        if (trigger != PaperRunTrigger.manual) {
          // Manual runs do not change the saved frequency.
          final next =
              _nowUtc().add(Duration(hours: task.config.frequencyHours));
          await PaperTaskDao().setNextRun(taskId, next);
        }
      }
      return runId;
    } finally {
      // Always release the task mutex, including early-return failures.
      _runningTasks.remove(taskId);
      _collectionClients.remove(taskId);
      final finishedRunId = runId;
      if (finishedRunId != null) {
        state = state.copyWith(
            activeRunIds: {...state.activeRunIds}..remove(finishedRunId));
      }
      ref.read(paperDataVersion.notifier).state++;
    }
  }

  Future<RunOutcome> _executeRun(
    PaperTask task,
    PaperRun run,
    RunWindows windows,
    CollectionService service,
    int execToken,
  ) async {
    var sawFailure = false;
    var sawSourceLimit = false;

    // Periodic recheck first so its marks enter this run's queues.
    await service.schedulePeriodicRecheck(
      task: task,
      windows: windows,
      now: _nowUtc(),
    );

    // Rotate latest and hot one slice at a time so hot never blocks latest.
    final latestSlices = await service.ensureSlices(
      task: task,
      channel: PaperChannel.latest,
      fromUtc: windows.latestFrom,
      toUtc: windows.latestTo,
    );
    final hotSlices = await service.ensureSlices(
      task: task,
      channel: PaperChannel.hot,
      fromUtc: windows.hotFrom,
      toUtc: windows.hotTo,
    );

    bool dueNow(PaperScanSlice s) {
      // Completed rows (including split parents whose children carry the
      // work) are not re-scanned here.
      if (s.status == PaperSliceStatus.completed) return false;
      final retry = s.nextRetryAt;
      if (retry != null && retry.isAfter(_nowUtc())) return false;
      return true;
    }

    final latestQueue = latestSlices.where(dueNow).toList();
    final hotQueue = hotSlices.where(dueNow).toList();

    var turn = 0;
    while (latestQueue.isNotEmpty || hotQueue.isNotEmpty) {
      if (_execTokens[task.taskId] != run.execToken || _shuttingDown) {
        return RunOutcome.cancelled;
      }
      final useLatest =
          latestQueue.isNotEmpty && (turn % 2 == 0 || hotQueue.isEmpty);
      final queue = useLatest ? latestQueue : hotQueue;
      final slice = queue.first;
      final branches = buildTaskBranches(task.config);
      TaskBranch? branch;
      for (final b in branches) {
        if (b.name == slice.branchHash) {
          branch = b;
          break;
        }
      }
      branch ??= branches.isEmpty ? null : branches.first;
      if (branch == null) {
        queue.removeAt(0);
        turn++;
        continue;
      }

      final outcome = await service.scanSlice(
        task: task,
        slice: slice,
        branch: branch,
        run: run,
      );
      queue.removeAt(0);
      switch (outcome.reason) {
        case ScanStopReason.completed:
          break;
        case ScanStopReason.split:
          // Schedule children immediately; the parent covers only once all
          // children complete.
          queue.addAll(outcome.children);
          break;
        case ScanStopReason.sourceLimit:
          sawSourceLimit = true;
          break;
        case ScanStopReason.failed:
          sawFailure = true;
          break;
        case ScanStopReason.cancelled:
          return RunOutcome.cancelled;
      }
      turn++;
    }

    final coveredLatest = await service.isChannelCovered(
      task: task,
      channel: PaperChannel.latest,
      fromUtc: windows.latestFrom,
      toUtc: windows.latestTo,
    );
    final coveredHot = await service.isChannelCovered(
      task: task,
      channel: PaperChannel.hot,
      fromUtc: windows.hotFrom,
      toUtc: windows.hotTo,
    );

    _track(_drainCitationQueue());
    _track(_drainAnalysisQueue());
    ref.read(paperDataVersion.notifier).state++;

    // Success requires BOTH channels fully covered; a merely quiet turn
    // (e.g. a failed slice waiting for its retry time) is still partial.
    if (sawFailure || sawSourceLimit) return RunOutcome.partial;
    if (!coveredLatest || !coveredHot) return RunOutcome.partial;
    return RunOutcome.succeeded;
  }

  /// Pause a task: bump the execution token (late responses of the old run
  /// stop advancing state) and stop new work. Already committed pages stay;
  /// a bookshelf import that already started is not hard-cancelled.
  Future<void> pauseTask(String taskId) async {
    _execTokens[taskId] = (_execTokens[taskId] ?? 0) + 1;
    _collectionClients[taskId]?.cancelActiveRequests();
    analysisService.cancel();
    importService.cancelActiveDownloads();
  }

  Future<void> pauseAll() async {
    state = state.copyWith(paused: true);
    analysisService.cancel();
    importService.cancelActiveDownloads();
    citationService.cancel();
    for (final client in _collectionClients.values) {
      client.cancelActiveRequests();
    }
    for (final id in _execTokens.keys.toList()) {
      _execTokens[id] = (_execTokens[id] ?? 0) + 1;
    }
    // Also invalidate tasks that have not run yet.
    final tasks = await PaperTaskDao().selectAll();
    for (final task in tasks) {
      _execTokens[task.taskId] = (_execTokens[task.taskId] ?? 0) + 1;
    }
  }

  Future<void> resumeAll() async {
    if (_shuttingDown || !DbOperationLock.instance.acceptsNewWork) return;
    state = state.copyWith(paused: false);
    _track(tick());
  }

  /// Citation statistics drain: new candidates first, due refreshes next —
  /// alternating so a long historical refresh never starves new papers.
  Future<void> _drainCitationQueue() async {
    if (_citationDraining || _shuttingDown || state.paused) return;
    _citationDraining = true;
    try {
      await citationService.drainBatch(maxItems: 20, nowUtc: _nowUtc());
    } catch (e) {
      AnxLog.warning('PaperCollection: citation drain failed: $e');
    } finally {
      _citationDraining = false;
    }
    ref.read(paperDataVersion.notifier).state++;
  }

  /// Analysis drain: fair 70/30 latest/hot split, weighted by priority,
  /// respecting the shared daily quota. Never deletes candidates.
  Future<void> _drainAnalysisQueue() async {
    if (_analysisDraining || _shuttingDown || state.paused) return;
    _analysisDraining = true;
    try {
      await _runAnalysisBatch(null);
    } catch (e) {
      AnxLog.warning('PaperCollection: analysis drain failed: $e');
    } finally {
      _analysisDraining = false;
    }
    ref.read(paperDataVersion.notifier).state++;
  }

  /// Analysis batch. When [onlyArxivId] is set, only that paper is
  /// processed (user "analyze this" action).
  Future<void> _runAnalysisBatch(String? onlyArxivId) async {
    final settings = await PaperSettingsDao().get();
    final provider = _resolveAnalysisProvider(settings);
    if (provider == null) {
      return; // shown as "pending configuration", candidates stay visible
    }
    final model = (settings.analysisModelOverride ?? '').trim().isEmpty
        ? provider.model
        : settings.analysisModelOverride!.trim();
    final modelFingerprint = modelFingerprintOf(
      providerId: provider.id,
      protocol: provider.protocol,
      baseUrl: provider.url,
      model: model,
      reasoningCode: provider.reasoningEffort.name,
    );

    final latestItems = <AnalysisQueueItem>[];
    final hotItems = <AnalysisQueueItem>[];

    Future<void> consider(Paper paper) async {
      // The manual path is the explicit recovery action: clear failure
      // backoff/exhaustion for this identity so the user can retry now.
      if (onlyArxivId != null) {
        await analysisService.clearFailures(
          arxivId: paper.arxivId,
          contentHash: paper.contentHash,
          modelFingerprint: modelFingerprint,
        );
      }
      final built = await _buildQueueItem(
        paper: paper,
        settings: settings,
        modelFingerprint: modelFingerprint,
      );
      if (built == null) return;
      if (built.channel == PaperChannel.latest) {
        latestItems.add(built);
      } else {
        hotItems.add(built);
      }
    }

    if (onlyArxivId != null) {
      final paper = await PaperDao().selectById(onlyArxivId);
      if (paper != null) await consider(paper);
    } else {
      Map<String, dynamic> cursor = {};
      try {
        cursor = jsonDecode(settings.pollerCursorJson ?? '{}')
            as Map<String, dynamic>;
      } catch (_) {}
      final candidates = await PaperDao().selectAnalysisCandidates(
        limit: 200,
        afterDate: cursor['analysis_after_date'] as String?,
        afterId: cursor['analysis_after_id'] as String?,
      );
      for (final paper in candidates) {
        if (!acceptsNewWork) return;
        await consider(paper);
      }
      await PaperSettingsDao().updatePollerCursor({
        'analysis_after_date': candidates.length < 200
            ? null
            : candidates.last.publishedAt.toUtc().toIso8601String(),
        'analysis_after_id':
            candidates.length < 200 ? null : candidates.last.arxivId,
      });
    }

    // The scheduler reads and writes only its own cursor keys.
    Map<String, dynamic> existingCursor = {};
    try {
      final raw = settings.pollerCursorJson;
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) existingCursor = decoded;
      }
    } catch (_) {}
    final scheduler = FairAnalysisScheduler(initialEntries: existingCursor);
    final batch = onlyArxivId != null
        ? [...latestItems, ...hotItems]
        : scheduler.pickBatch(
            latestItems: latestItems,
            hotItems: hotItems,
            count: 5,
          );

    for (final item in batch) {
      if (_shuttingDown || state.paused) return;
      await _analyzeOne(
        item: item,
        settings: settings,
        provider: provider,
        modelFingerprint: modelFingerprint,
      );
    }

    if (onlyArxivId == null) {
      // Field-level merge: never rewrites quota or service selection.
      await PaperSettingsDao().updatePollerCursor(scheduler.cursorEntries);
    }
  }

  /// Build one queue item with its real task inputs, channel and priority.
  /// Returns null (without consuming queue capacity) when the paper is not
  /// eligible yet: fully cached, exhausted retries, or inside backoff.
  Future<AnalysisQueueItem?> _buildQueueItem({
    required Paper paper,
    required PaperSettings settings,
    required String modelFingerprint,
  }) async {
    final matches = await PaperMatchDao().selectForPaper(paper.arxivId);
    if (matches.isEmpty) return null;

    final taskInputs = <AnalysisTaskInput>[];
    final taskIdToProfile = <String, String>{};
    int bestPriority = 5;
    String owningTaskId = '';
    PaperChannel channel = PaperChannel.hot;

    for (final match in matches) {
      final task = await PaperTaskDao().selectById(match.taskId);
      if (task == null || !task.enabled) continue;
      if (task.queryRevision != match.queryRevision) {
        // Stale-revision projections are not part of the current queue.
        continue;
      }
      final hash = taskProfileHash(task.config);
      taskInputs.add(AnalysisTaskInput(
        taskId: task.taskId,
        profileHash: hash,
        config: task.config,
      ));
      taskIdToProfile[task.taskId] = hash;
      if (owningTaskId.isEmpty || task.priority < bestPriority) {
        bestPriority = task.priority;
        owningTaskId = task.taskId;
      }
      // Channel membership follows this task's own windows.
      final latestFrom =
          _nowUtc().subtract(Duration(days: task.config.latestWindowDays));
      if (paper.publishedAt.isAfter(latestFrom)) {
        channel = PaperChannel.latest;
      }
    }
    if (taskInputs.isEmpty) return null;

    // Full cache hit (body+model+profiles) rebuilds pending or stale
    // projections without a request and without quota.
    final reusable = await analysisService.findReusable(
      paper: paper,
      taskIdToProfileHash: taskIdToProfile,
      modelFingerprint: modelFingerprint,
    );
    // Only relevance-wanting tasks require an assessment; pure discovery /
    // translation tasks are satisfied by the translation fields.
    final missing = taskInputs
        .where((t) =>
            t.config.wantsRelevance &&
            !reusable.assessments.any((a) => a.taskId == t.taskId))
        .toList();
    if (missing.isEmpty) {
      for (final match in matches) {
        if (taskIdToProfile.containsKey(match.taskId) &&
            taskInputs.any((t) => t.taskId == match.taskId) &&
            (await PaperTaskDao().selectById(match.taskId))?.queryRevision ==
                match.queryRevision) {
          int? aiScore;
          String? cacheKey;
          for (final a in reusable.assessments) {
            if (a.taskId == match.taskId) {
              aiScore = a.relevanceScore;
              cacheKey = reusable.taskIdToCacheKey[a.taskId];
              break;
            }
          }
          final input = taskInputs.firstWhere((t) => t.taskId == match.taskId);
          if (!input.config.wantsRelevance) {
            cacheKey = reusable.translationCacheKey;
          }
          // Rebuild missing or stale projections; keep a valid existing one.
          if (cacheKey != null &&
              (match.analysisCacheKey != cacheKey ||
                  match.aiScore != aiScore)) {
            await PaperMatchDao().updateScoreProjection(
              taskId: match.taskId,
              queryRevision: match.queryRevision,
              arxivId: match.arxivId,
              ruleScore: match.ruleScore,
              analysisCacheKey: cacheKey,
              aiScore: aiScore,
            );
            ref.read(paperDataVersion.notifier).state++;
          }
        }
      }
      // Translation is a separate need from assessments: pure author /
      // category discovery tasks still deserve a translation request
      // (assessments: []) when no valid translation is cached. An empty
      // assessment set must never be read as "translation done".
      final needsTranslation =
          reusable.titleZh == null || reusable.abstractZh == null;
      if (!needsTranslation || taskInputs.isEmpty) return null;
    }

    // Retry gating: identity includes body + model; exhausted identities
    // stay out, backoff-not-elapsed identities wait.
    var eligible = false;
    for (final chunk in splitAnalysisTasks(
        paper: paper,
        tasks: missing,
        maxInputChars: analysisInputBudgetChars)) {
      if (await analysisService.retryAllowed(
          arxivId: paper.arxivId,
          contentHash: paper.contentHash,
          modelFingerprint: modelFingerprint,
          nowUtc: _nowUtc(),
          requestIdentity:
              analysisRequestIdentity(paper, chunk, modelFingerprint))) {
        eligible = true;
        break;
      }
    }
    if (!eligible) return null;

    return AnalysisQueueItem(
      paper: paper,
      channel: channel,
      priority: bestPriority,
      taskId: owningTaskId,
      pendingTasks: missing,
    );
  }

  /// Estimated per-request input budget (characters). Profiles beyond the
  /// budget are split into additional requests, each metered separately;
  /// a single paper body that cannot fit is marked `input_too_large`
  /// instead of being silently truncated.
  static const int analysisInputBudgetChars = 24000;

  Future<void> _analyzeOne({
    required AnalysisQueueItem item,
    required PaperSettings settings,
    required AiProvider provider,
    required String modelFingerprint,
  }) async {
    final matches = await PaperMatchDao().selectForPaper(item.paper.arxivId);
    if (matches.isEmpty) return;

    final paper = item.paper;
    final chunks = splitAnalysisTasks(
        paper: paper,
        tasks: item.pendingTasks,
        maxInputChars: analysisInputBudgetChars);

    for (final chunk in chunks) {
      await _analyzeChunk(
        paper: paper,
        chunk: chunk,
        matches: matches,
        settings: settings,
        provider: provider,
        modelFingerprint: modelFingerprint,
      );
    }
  }

  Future<void> _analyzeChunk({
    required Paper paper,
    required List<AnalysisTaskInput> chunk,
    required List<PaperTaskMatch> matches,
    required PaperSettings settings,
    required AiProvider provider,
    required String modelFingerprint,
  }) async {
    final identity = analysisRequestIdentity(paper, chunk, modelFingerprint);
    if (!acceptsNewWork ||
        !await analysisService.retryAllowed(
            arxivId: paper.arxivId,
            contentHash: paper.contentHash,
            modelFingerprint: modelFingerprint,
            nowUtc: _nowUtc(),
            requestIdentity: identity)) {
      return;
    }
    if (buildAnalysisMessages(paper: paper, tasks: chunk).inputChars >
        analysisInputBudgetChars) {
      await analysisService.recordFailure(
          arxivId: paper.arxivId,
          contentHash: paper.contentHash,
          modelFingerprint: modelFingerprint,
          requestIdentity: identity,
          failureClass: 'input_too_large',
          attempt: 0);
      return;
    }
    // Reserve immediately before sending; checks above consumed no quota.
    // The effective limit is read inside the reservation transaction.
    final reservedDay = await analysisService.reserveQuota(
        fallbackDailyLimit: settings.dailyLimit);
    if (reservedDay == null) {
      throw AnalysisQuotaExceededException();
    }

    // A pause/shutdown that arrived while we queued must stop the send:
    // the request has not gone out, so the reservation is released.
    if (_shuttingDown || state.paused) {
      await analysisService.releaseUnsentQuota(reservedDay);
      return;
    }

    bool sent = false;
    try {
      final payload = await analysisService.analyze(
        paper: paper,
        tasks: chunk,
        provider: provider,
        modelOverride: settings.analysisModelOverride,
        onRequestSent: () {
          sent = true;
        },
      );
      // Merge with any cached pieces (translation reuse).
      final taskIdToProfile = {
        for (final t in chunk) t.taskId: t.profileHash,
      };
      final reusable = await analysisService.findReusable(
        paper: paper,
        taskIdToProfileHash: taskIdToProfile,
        modelFingerprint: modelFingerprint,
      );
      final merged = AnalysisResultPayload(
        titleZh: payload.titleZh ?? reusable.titleZh,
        abstractZh: payload.abstractZh ?? reusable.abstractZh,
        assessments: [
          ...reusable.assessments,
          ...payload.assessments,
        ],
      );
      // The saved row covers every assessment in the merged payload, so
      // its cache key lists all of their profile hashes.
      final allTasks = <String, (String, String)>{};
      for (final t in chunk) {
        allTasks[t.taskId] = (t.taskId, t.profileHash);
      }
      for (final a in reusable.assessments) {
        allTasks.putIfAbsent(a.taskId, () => (a.taskId, a.profileHash));
      }
      await analysisService.saveSuccess(
        paper: paper,
        payload: merged,
        modelFingerprint: modelFingerprint,
        tasks: allTasks.values
            .map((t) => (taskId: t.$1, profileHash: t.$2))
            .toList(),
        matches: matches,
        quotaDay: reservedDay,
      );
    } on AnalysisNotConfiguredException {
      // Not sent: configuration errors must not accumulate attempts or
      // consume quota. The user fixes the service selection.
      await analysisService.releaseUnsentQuota(reservedDay);
    } on AnalysisCancelledException {
      // Cancelled before dispatch: release. Cancelled mid-stream was sent
      // and keeps its metered reservation.
      if (!sent) {
        await analysisService.releaseUnsentQuota(reservedDay);
      }
    } on AnalysisValidationException catch (e) {
      AnxLog.warning(
          'PaperCollection: invalid analysis for ${paper.arxivId}: $e');
      final attempts = await analysisService.attemptCountFor(
        arxivId: paper.arxivId,
        contentHash: paper.contentHash,
        modelFingerprint: modelFingerprint,
        requestIdentity: identity,
      );
      await analysisService.recordFailure(
        arxivId: paper.arxivId,
        contentHash: paper.contentHash,
        modelFingerprint: modelFingerprint,
        failureClass: 'validation',
        attempt: attempts + 1,
        requestIdentity: identity,
      );
      // Sent requests keep their quota reservation even when invalid.
    } catch (e) {
      AnxLog.warning(
          'PaperCollection: analysis failed for ${paper.arxivId}: $e');
      final attempts = await analysisService.attemptCountFor(
        arxivId: paper.arxivId,
        contentHash: paper.contentHash,
        modelFingerprint: modelFingerprint,
        requestIdentity: identity,
      );
      await analysisService.recordFailure(
        arxivId: paper.arxivId,
        contentHash: paper.contentHash,
        modelFingerprint: modelFingerprint,
        failureClass: 'request_failed',
        attempt: attempts + 1,
        requestIdentity: identity,
      );
      if (!sent) {
        // Never-sent requests release the reservation (bound to its day).
        await analysisService.releaseUnsentQuota(reservedDay);
      }
    }
  }

  AiProvider? _resolveAnalysisProvider(PaperSettings settings) {
    final rawProviders = Prefs().getAiProviders();
    if (rawProviders.isEmpty) return null;
    final providers = rawProviders
        .map((json) =>
            AiProvider.fromJson(Map<String, dynamic>.from(json as Map)))
        .toList(growable: false);
    final wanted = settings.analysisProviderId;
    if (wanted != null && wanted.isNotEmpty) {
      for (final p in providers) {
        if (p.id == wanted && p.enabled) return p;
      }
      // The selected service was deleted: analysis is blocked, no silent
      // fallback to another service.
      return null;
    }
    final selectedId = Prefs().selectedAiService;
    for (final p in providers) {
      if (p.id == selectedId && p.enabled) return p;
    }
    for (final p in providers) {
      if (p.enabled) return p;
    }
    return null;
  }

  /// Request analysis for a single paper from the UI ("analyze this").
  /// Uses the same remaining quota; when the quota is exhausted the user
  /// may raise the daily setting — it is never silently bypassed.
  Future<void> analyzeNow(String arxivId) async {
    if (!acceptsNewWork) throw StateError('Paper collection is paused');
    if (_analysisDraining) {
      throw AnalysisQuotaExceededException();
    }
    _analysisDraining = true;
    try {
      await _runAnalysisBatch(arxivId);
    } finally {
      _analysisDraining = false;
      ref.read(paperDataVersion.notifier).state++;
    }
  }

  /// Register a user-selected download/import so shutdown can drain it.
  void registerImportInFlight() {
    if (!acceptsNewWork || !DbOperationLock.instance.acceptsNewWork) {
      throw StateError('Paper imports are paused');
    }
    _importsInFlight++;
    _metadataDraining = true;
  }

  void unregisterImportInFlight() {
    if (_importsInFlight > 0) _importsInFlight--;
    if (_importsInFlight == 0) _metadataDraining = false;
  }

  /// Wait (bounded) until every owned in-flight work item settles. Used by
  /// storage migration before closing the databases; returns false when
  /// work is still running after [timeout].
  Future<bool> drainInFlight({Duration? timeout}) async {
    final deadline = DateTime.now().add(timeout ?? drainTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!_anyBusy) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return !_anyBusy;
  }

  /// True while ANY owned work is unfinished: tracked futures (including
  /// UI-initiated ones), task runs, analysis drains, registered imports,
  /// the shared metadata queue and waiting main-library operations.
  bool get _anyBusy =>
      _citationDraining ||
      _metadataDraining ||
      _importsInFlight > 0 ||
      _inflight.isNotEmpty ||
      _runningTasks.isNotEmpty ||
      _analysisDraining ||
      metadataQueueDepth > 0 ||
      importWorkDepth > 0 ||
      DbOperationLock.instance.isBusy;

  /// Shutdown sequencing: stop the timer and new queue work, cancel HTTP
  /// and AI streams, persist interrupted state, drain ALL in-flight owned
  /// work (metadata saves, imports, runs, drains) within [drainTimeout],
  /// then close the paper database. Returns false when any such work is
  /// still unfinished after the deadline — shared resources (paper DB,
  /// reading server, WebView, main DB) must not be destroyed concurrently
  /// with writes.
  Future<bool> shutdown() async {
    _shuttingDown = true;
    DbOperationLock.instance.suspendNewWork();
    _tickTimer?.cancel();
    _tickTimer = null;

    for (final id in _execTokens.keys.toList()) {
      _execTokens[id] = (_execTokens[id] ?? 0) + 1;
    }
    analysisService.cancel();
    importService.cancelActiveDownloads();
    citationService.cancel();
    for (final client in _collectionClients.values) {
      client.cancelActiveRequests();
    }

    try {
      await PaperRunDao().markOpenRunsInterrupted();
      await markOpenSlicesInterrupted();
    } catch (_) {}

    final deadline = DateTime.now().add(drainTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!_anyBusy) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_anyBusy) {
      AnxLog.warning(
          'PaperCollection: shutdown drain incomplete; keeping shared resources');
      _shuttingDown = false;
      DbOperationLock.instance.resumeNewWork();
      state = state.copyWith(paused: true);
      _tickTimer ??= Timer.periodic(tickInterval, (_) => _track(tick()));
      return false;
    }

    await PaperDatabase.instance.close();
    _started = false;
    state = state.copyWith(enabled: false);
    return true;
  }
}

enum RunOutcome { succeeded, partial, failed, cancelled }

final paperCollectionProvider =
    NotifierProvider<PaperCollectionController, PaperCollectionState>(
        () => PaperCollectionController());
