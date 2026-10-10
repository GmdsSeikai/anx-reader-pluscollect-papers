import 'dart:async';
import 'dart:io';

import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/page/papers/paper_detail_page.dart';
import 'package:anx_reader/page/papers/task_form_page.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/paper_collection.dart';
import 'package:anx_reader/providers/paper_list.dart';
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:anx_reader/service/papers/collection_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/widgets/papers/paper_candidate_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

/// The Papers home page. It only observes the application-level collection
/// controller: switching away from this page or minimizing the window never
/// stops collection.
class PapersPage extends ConsumerStatefulWidget {
  const PapersPage({super.key, this.controller});

  final ScrollController? controller;

  @override
  ConsumerState<PapersPage> createState() => _PapersPageState();
}

class _PapersPageState extends ConsumerState<PapersPage> {
  PaperListView _view = PaperListView.latest;
  PaperListSort _sort = PaperListSort.relevance;
  PaperListFilter _filter = PaperListFilter.all;
  String? _taskFilterId;
  final Set<String> _selected = <String>{};
  final TextEditingController _search = TextEditingController();
  List<PaperTask> _tasks = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Idempotent; the app lifecycle owner normally started it already.
      ref.read(paperCollectionProvider.notifier).start();
      _reloadTasks();
    });
  }

  Future<void> _reloadTasks() async {
    final tasks = await PaperTaskDao().selectAll();
    if (mounted) setState(() => _tasks = tasks);
  }

  PaperListQuery get _query {
    // View windows follow the selected task's adjustable windows. With
    // enabled tasks but no filter, the window IS the widest configured
    // among them (narrowing tasks shrinks the view); the 30d/12mo defaults
    // apply only when no task exists.
    int latestDays = 30;
    int hotMonths = 12;
    if (_taskFilterId != null) {
      for (final t in _tasks) {
        if (t.taskId == _taskFilterId) {
          latestDays = t.config.latestWindowDays;
          hotMonths = t.config.hotWindowMonths;
        }
      }
    } else {
      final enabled = _tasks.where((t) => t.enabled).toList();
      if (enabled.isNotEmpty) {
        latestDays = enabled
            .map((t) => t.config.latestWindowDays)
            .reduce((a, b) => a > b ? a : b);
        hotMonths = enabled
            .map((t) => t.config.hotWindowMonths)
            .reduce((a, b) => a > b ? a : b);
      }
    }
    return PaperListQuery(
      view: _view,
      sort: _sort,
      filter: _filter,
      taskId: _taskFilterId,
      searchText: _search.text,
      showLowRelevance: _filter == PaperListFilter.lowRelevance,
      latestWindowDays: latestDays,
      hotWindowMonths: hotMonths,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final collection = ref.watch(paperCollectionProvider);
    // Refresh when collection commits land so new candidates show without
    // reopening the page.
    ref.listen(paperDataVersion, (previous, next) {
      if (previous != next) {
        if (_view != PaperListView.tasks) {
          ref.read(paperListProvider(_query).notifier).refresh();
        }
        _reloadTasks();
      }
    });
    final list = ref.watch(paperListProvider(_query));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.papersTitle),
        actions: [
          if (collection.initialized && collection.enabled)
            TextButton(
              onPressed: () {
                final notifier = ref.read(paperCollectionProvider.notifier);
                if (collection.paused) {
                  notifier.resumeAll();
                } else {
                  notifier.pauseAll();
                }
                setState(() {});
              },
              child: Text(
                  collection.paused ? l10n.papersResume : l10n.papersPause),
            ),
          TextButton(
            onPressed: _runAll,
            child: Text(l10n.papersRunTasks),
          ),
          TextButton(
            onPressed: _openNewTask,
            child: Text(l10n.papersNewTask),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: l10n.papersSearchHint,
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                  ),
                  onSubmitted: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<PaperListFilter>(
                value: _filter,
                items: [
                  DropdownMenuItem(
                      value: PaperListFilter.all,
                      child: Text(l10n.papersFilterAll)),
                  DropdownMenuItem(
                      value: PaperListFilter.pendingAnalysis,
                      child: Text(l10n.papersFilterPendingAnalysis)),
                  DropdownMenuItem(
                      value: PaperListFilter.lowRelevance,
                      child: Text(l10n.papersFilterLowRelevance)),
                  DropdownMenuItem(
                      value: PaperListFilter.ignored,
                      child: Text(l10n.papersFilterIgnored)),
                  DropdownMenuItem(
                      value: PaperListFilter.imported,
                      child: Text(l10n.papersFilterImported)),
                ],
                onChanged: (v) =>
                    setState(() => _filter = v ?? PaperListFilter.all),
              ),
            ]),
          ),
          SegmentedButton<PaperListView>(
            segments: [
              ButtonSegment(
                  value: PaperListView.latest,
                  label: Text(l10n.papersViewLatest)),
              ButtonSegment(
                  value: PaperListView.hot, label: Text(l10n.papersViewHot)),
              ButtonSegment(
                  value: PaperListView.tasks,
                  label: Text(l10n.papersViewTasks)),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() {
              _view = s.first;
              if (_view == PaperListView.hot) {
                _sort = PaperListSort.citations;
              } else if (_view == PaperListView.latest) {
                _sort = PaperListSort.relevance;
              }
            }),
          ),
          if (_view != PaperListView.tasks)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                DropdownButton<PaperListSort>(
                  value: _sort,
                  items: [
                    DropdownMenuItem(
                        value: PaperListSort.relevance,
                        child: Text(l10n.papersRelevance)),
                    DropdownMenuItem(
                        value: PaperListSort.newest,
                        child: Text(l10n.papersLatest)),
                    if (_view == PaperListView.hot)
                      DropdownMenuItem(
                          value: PaperListSort.citations,
                          child: Text(l10n.papersCitations)),
                  ],
                  onChanged: (v) =>
                      setState(() => _sort = v ?? PaperListSort.relevance),
                ),
                const SizedBox(width: 8),
                DropdownButton<String?>(
                  value: _taskFilterId,
                  items: [
                    DropdownMenuItem<String?>(
                      child: Text(l10n.papersViewTasks),
                    ),
                    for (final task in _tasks)
                      DropdownMenuItem<String?>(
                        value: task.taskId,
                        child: Text(task.name),
                      ),
                  ],
                  onChanged: (v) => setState(() => _taskFilterId = v),
                ),
                const Spacer(),
                Text(l10n.papersSelectedCount(_selected.length),
                    style: Theme.of(context).textTheme.bodySmall),
                TextButton(
                  onPressed: _selected.isEmpty ||
                          !ref
                              .read(paperCollectionProvider.notifier)
                              .acceptsNewWork
                      ? null
                      : _downloadSelected,
                  child: Text(l10n.papersDownloadSelected),
                ),
              ]),
            ),
          if (collection.errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                collection.errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          Expanded(
            child: _view == PaperListView.tasks
                ? _taskList(l10n)
                : list.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('$e')),
                    data: (result) => _candidateList(l10n, result),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              l10n.papersSyncScopeNote,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _candidateList(L10n l10n, PaperListResult result) {
    final allEmpty = result.items.isEmpty && result.lowRelevanceItems.isEmpty;
    if (allEmpty && result.totalCount == 0) {
      return Center(
        child: Text(_tasks.isEmpty
            ? l10n.papersEmptyNoTasks
            : l10n.papersEmptyNoResults),
      );
    }
    return ListView(
      controller: widget.controller,
      children: [
        if (result.lowRelevanceCount > 0)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              l10n.papersLowRelevanceHidden(result.lowRelevanceCount),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final item in result.items) _tile(item),
        // The low-relevance group is reachable even when every page item
        // was grouped out; nothing gets stuck behind an empty first page.
        for (final item in result.lowRelevanceItems)
          if (_filter == PaperListFilter.lowRelevance ||
              _filter == PaperListFilter.ignored)
            _tile(item),
        if (result.lowRelevanceItems.isNotEmpty &&
            _filter != PaperListFilter.lowRelevance)
          TextButton(
            onPressed: () {
              setState(() {
                _filter = PaperListFilter.lowRelevance;
              });
            },
            child: Text(l10n.papersShowLowRelevance),
          ),
        if (result.hasMore)
          TextButton(
            onPressed: () =>
                ref.read(paperListProvider(_query).notifier).loadMore(),
            child: Text('↓ ${result.items.length}/${result.totalCount}'),
          ),
      ],
    );
  }

  Widget _tile(PaperListItem item) {
    return PaperCandidateTile(
      item: item,
      selected: _selected.contains(item.paper.arxivId),
      onSelectionChanged: (checked) {
        setState(() {
          if (checked == true) {
            _selected.add(item.paper.arxivId);
          } else {
            _selected.remove(item.paper.arxivId);
          }
        });
      },
      onTap: () => _openDetail(item.paper.arxivId),
    );
  }

  Widget _taskList(L10n l10n) {
    if (_tasks.isEmpty) {
      return Center(child: Text(l10n.papersEmptyNoTasks));
    }
    return ListView(
      children: [
        for (final task in _tasks)
          FutureBuilder(
            future: _taskProgress(task),
            builder: (context, snapshot) {
              final progress = snapshot.data ?? '';
              return ListTile(
                title: Text(task.name),
                subtitle: Text(
                  '${l10n.papersTaskPriority}: ${task.priority}  '
                  '${task.enabled ? '✓' : '✗'}  '
                  '${l10n.papersFrequencyHours(task.config.frequencyHours)}  '
                  '${l10n.papersNextRun}: ${task.nextRunAt?.toLocal().toString().split('.').first ?? '-'}'
                  '${progress.isEmpty ? '' : '\n$progress'}',
                ),
                isThreeLine: progress.isNotEmpty,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => _runSingle(task.taskId),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () => _openEditTask(task),
                    ),
                  ],
                ),
                onTap: () => _openEditTask(task),
              );
            },
          ),
      ],
    );
  }

  /// Coverage/progress summary for one task. Split parents and source
  /// limited slices are NOT counted as completed; affected ranges are
  /// shown so the visible completion never overstates real coverage.
  Future<String> _taskProgress(PaperTask task) async {
    final l10n = L10n.of(context);
    try {
      final slices = await PaperSliceDao().selectByTask(task.taskId);
      final now = DateTime.now().toUtc();
      final latestFrom =
          now.subtract(Duration(days: task.config.latestWindowDays));
      final hotFrom = subtractCalendarMonths(now, task.config.hotWindowMonths);
      var latestDone = 0, latestTotal = 0, hotDone = 0, hotTotal = 0;
      final limitedRanges = <String>[];
      var failed = 0;
      for (final s in slices) {
        if (s.revision != task.queryRevision) continue;
        final from = s.channel == PaperChannel.latest ? latestFrom : hotFrom;
        if (!s.toUtc.isAfter(from) || !s.fromUtc.isBefore(now)) continue;
        // Split parents defer to their children; limited slices are open.
        final countedDone = s.status == PaperSliceStatus.completed &&
            !s.sourceLimit &&
            s.failureClass != 'split';
        if (s.channel == PaperChannel.latest) {
          if (!s.sourceLimit && s.failureClass != 'split') latestTotal++;
          if (countedDone) latestDone++;
        } else {
          if (!s.sourceLimit && s.failureClass != 'split') hotTotal++;
          if (countedDone) hotDone++;
        }
        if (s.sourceLimit) {
          limitedRanges.add('${s.fromUtc.toIso8601String().substring(0, 16)}~'
              '${s.toUtc.toIso8601String().substring(0, 16)}');
        }
        if (s.status == PaperSliceStatus.failed) failed++;
      }
      final buffer = StringBuffer();
      buffer.write(
          '${l10n.papersWindowLatestProgress}: $latestDone/$latestTotal  ');
      buffer.write('${l10n.papersWindowHotProgress}: $hotDone/$hotTotal');
      if (failed > 0 || limitedRanges.isNotEmpty) {
        buffer.write('  (${l10n.papersStatusFailed}: $failed');
        if (limitedRanges.isNotEmpty) {
          buffer.write(', source_limit: ${limitedRanges.take(2).join('; ')}');
        }
        buffer.write(')');
      }
      return buffer.toString();
    } catch (_) {
      return '';
    }
  }

  void _runSingle(String taskId) {
    final notifier = ref.read(paperCollectionProvider.notifier);
    unawaited(notifier.runTask(taskId).then((_) async {
      await _reloadTasks();
      if (mounted) {
        await ref.read(paperListProvider(_query).notifier).refresh();
      }
    }));
  }

  Future<void> _runAll() async {
    final notifier = ref.read(paperCollectionProvider.notifier);
    for (final task in _tasks.where((t) => t.enabled)) {
      unawaited(notifier.runTask(task.taskId).then((_) async {
        if (mounted) {
          await ref.read(paperListProvider(_query).notifier).refresh();
        }
      }));
    }
    await _reloadTasks();
  }

  Future<void> _openEditTask(PaperTask task) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PaperTaskFormPage(existing: task),
      ),
    );
    if (changed == true) {
      await _reloadTasks();
      if (mounted) {
        await ref.read(paperListProvider(_query).notifier).refresh();
      }
    }
  }

  Future<void> _openNewTask() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PaperTaskFormPage()),
    );
    if (changed == true) {
      await _reloadTasks();
      if (mounted) {
        await ref.read(paperListProvider(_query).notifier).refresh();
      }
    }
  }

  void _openDetail(String arxivId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PaperDetailPage(arxivId: arxivId),
      ),
    );
  }

  /// Batch import runs through the same import service as single downloads;
  /// a failure of one paper never cancels the rest of the batch. Books that
  /// already exist (including soft-deleted or multiple MD5 matches) are
  /// surfaced to the user instead of silently bound or replaced.
  Future<void> _downloadSelected() async {
    final l10n = L10n.of(context);
    final controller = ref.read(paperCollectionProvider.notifier);
    if (!controller.acceptsNewWork) return;
    final ids = List<String>.from(_selected);
    _selected.clear();
    setState(() {});

    for (final arxivId in ids) {
      if (!controller.acceptsNewWork) break;
      controller.registerImportInFlight();
      try {
        final paper = await PaperDao().selectById(arxivId);
        if (paper == null) continue;
        final requestId = const Uuid().v4();
        final record = await controller.importService.startImport(
          paper: paper,
          downloadVersion: paper.latestVersion,
          requestId: requestId,
          nowUtc: DateTime.now().toUtc(),
        );
        if (record == null) continue; // duplicate click / already in flight
        if (record.status == PaperImportStatus.imported) continue;

        try {
          // Resume path: a recovered record may already hold a verified
          // download, so the cache file is reused instead of re-fetched.
          File? file = await controller.importService.reusableCachedPdf(record);
          if (!controller.acceptsNewWork) {
            await controller.importService
                .settleFailed(record: record, failureClass: 'cancelled');
            continue;
          }
          file ??= await controller.importService.downloadPdf(
            paper: paper,
            record: record,
          );
          if (record.pdfMd5 == null) {
            await controller.importService.recordMd5(
              record: record,
              file: file,
              nowUtc: DateTime.now().toUtc(),
            );
          }

          // Pre-check outside the lock for messaging; the import step
          // re-reconciles under the lock before committing.
          final reconcile = await controller.importService
              .reconcileWithMainLibrary(record: record);
          switch (reconcile.kind) {
            case ImportReconcileKind.alreadyInLibrary:
              await controller.importService.linkBook(
                record: record,
                book: reconcile.matches.first,
                nowUtc: DateTime.now().toUtc(),
                verifiedPdf: file,
              );
              continue;
            case ImportReconcileKind.multipleActive:
              final chosen = await _pickBook(l10n, reconcile.matches);
              if (chosen == null) {
                // User cancelled: settle so the paper stays retryable.
                await controller.importService.settleFailed(
                    record: record, failureClass: 'user_cancelled');
                continue;
              }
              await controller.importService.linkBook(
                record: record,
                book: chosen,
                nowUtc: DateTime.now().toUtc(),
                verifiedPdf: file,
              );
              continue;
            case ImportReconcileKind.restorable:
              final restore = await _confirmRestore(l10n, reconcile.matches);
              if (restore == null) {
                await controller.importService.settleFailed(
                    record: record, failureClass: 'user_cancelled');
                continue;
              }
              await controller.importService.restoreBook(restore,
                  expectedMd5: record.pdfMd5, verifiedPdf: file);
              await controller.importService.linkBook(
                record: record,
                book: restore,
                nowUtc: DateTime.now().toUtc(),
                verifiedPdf: file,
              );
              continue;
            case ImportReconcileKind.notInLibrary:
              break;
          }

          await controller.importService.importDownloadedPdf(
            paper: paper,
            record: record,
            pdfFile: file,
          );
          ref.read(bookListProvider.notifier).refresh();
        } catch (e) {
          AnxLog.severe('PapersPage: import failed for $arxivId: $e');
          // Settle the record so the next attempt is not blocked by a
          // stale downloaded/importing state.
          try {
            final current = await PaperImportDao().selectById(arxivId);
            if (current != null &&
                current.status != PaperImportStatus.imported) {
              await controller.importService
                  .settleFailed(record: current, failureClass: 'import_failed');
            }
          } catch (_) {}
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${l10n.papersDownloadFailed}: $arxivId')),
            );
          }
        } finally {
          controller.importService.endRequest(arxivId, record.requestId);
        }
      } finally {
        controller.unregisterImportInFlight();
      }
    }
    if (mounted) {
      await ref.read(paperListProvider(_query).notifier).refresh();
    }
  }

  /// Explicit user choice when several active books share the MD5.
  Future<Book?> _pickBook(L10n l10n, List<Book> matches) {
    return showDialog<Book>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.papersImported),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final book in matches)
              ListTile(
                title: Text(book.title),
                subtitle: Text(book.author),
                onTap: () => Navigator.of(context).pop(book),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.papersCancel),
          ),
        ],
      ),
    );
  }

  /// Explicit restore choice for a soft-deleted match (keeps notes and
  /// progress; never auto-revives).
  Future<Book?> _confirmRestore(L10n l10n, List<Book> matches) {
    return showDialog<Book>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.papersImported),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final book in matches)
              ListTile(
                title: Text(book.title),
                subtitle: Text(book.author),
                onTap: () => Navigator.of(context).pop(book),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.papersCancel),
          ),
        ],
      ),
    );
  }
}
