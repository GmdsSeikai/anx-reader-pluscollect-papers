import 'dart:convert';

import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/models/papers/paper_enums.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/papers/import_service.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:anx_reader/providers/paper_collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Full paper record: original material, Chinese translation, source links,
/// discovery evidence and relevance evidence with quotes.
class PaperDetailPage extends ConsumerStatefulWidget {
  const PaperDetailPage({super.key, required this.arxivId});

  final String arxivId;

  @override
  ConsumerState<PaperDetailPage> createState() => _PaperDetailPageState();
}

class _PaperDetailPageState extends ConsumerState<PaperDetailPage> {
  Paper? _paper;
  List<PaperTaskMatch> _matches = const [];
  final Map<String, PaperAnalysis> _analyses = {};
  Map<String, String> _profileHashes = const {};
  PaperCitation? _citation;
  PaperImportRecord? _import;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _loadGeneration = 0;

  Future<void> _load() async {
    final int generation = ++_loadGeneration;
    try {
      final paper = await PaperDao().selectById(widget.arxivId);
      if (paper == null) {
        if (mounted && generation == _loadGeneration) {
          setState(() => _error = 'not found');
        }
        return;
      }
      final matches = await PaperMatchDao().selectForPaper(widget.arxivId);
      final tasks = await PaperTaskDao().selectAll();
      final currentMatches = matches
          .where((match) => tasks.any((task) =>
              task.taskId == match.taskId &&
              task.queryRevision == match.queryRevision))
          .toList();
      final model = await currentAnalysisModelFingerprint();
      // Current-valid analyses only: body hash must match the paper as it
      // is now, so a v2 refresh cannot keep showing translations and
      // evidence derived from the old abstract. Historical rows stay out
      // of the current view rather than masquerading as current.
      final rows =
          await PaperAnalysisDao().selectSucceededForPaper(widget.arxivId);
      final analyses = <String, PaperAnalysis>{};
      for (final row in rows) {
        if (!isCurrentAnalysis(row, paper, model)) continue;
        analyses[row.cacheKey] = row;
      }
      final citation = await PaperCitationDao().selectById(widget.arxivId);
      final importRecord = await PaperImportDao().selectById(widget.arxivId);
      // Publish only if this is still the newest request and the page is
      // alive — a stale reload must never overwrite fresher state.
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _paper = paper;
        _error = null;
        _profileHashes = {
          for (final task in tasks) task.taskId: task.config.semanticHash
        };
        _matches = currentMatches;
        _analyses
          ..clear()
          ..addAll(analyses);
        _citation = citation;
        _import = importRecord;
      });
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    // Reload when collection commits land so translation/citations appear
    // without leaving the page.
    ref.listen(paperDataVersion, (previous, next) {
      if (previous != next) _load();
    });
    final paper = _paper;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.papersTitle)),
      body: paper == null
          ? Center(
              child: _error != null
                  ? Text(_error!)
                  : const CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(paper.title,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  paper.authors
                      .map((a) => a.affiliation == null
                          ? a.name
                          : '${a.name} (${a.affiliation})')
                      .join(', '),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${l10n.papersLatest}: '
                  '${paper.publishedAt.toLocal().toString().split('.').first}   '
                  '${l10n.papersUpdated}: '
                  '${paper.updatedAt.toLocal().toString().split('.').first}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (paper.categories.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('${l10n.papersCategoriesLabel}: '
                      '${paper.categories.join(', ')}'),
                ],
                if (paper.journalRef != null &&
                    paper.journalRef!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Journal: ${paper.journalRef}'),
                ],
                const SizedBox(height: 12),
                _sectionTitle(context, l10n.papersAbstract),
                SelectableText(paper.abstractText),
                const SizedBox(height: 12),
                _buildTranslation(context, l10n),
                const SizedBox(height: 12),
                _buildCitations(context, l10n),
                const SizedBox(height: 12),
                _buildSourceLinks(context, l10n, paper),
                const SizedBox(height: 12),
                _buildDiscovery(context, l10n),
                const SizedBox(height: 12),
                _buildRelevance(context, l10n),
              ],
            ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _buildTranslation(BuildContext context, L10n l10n) {
    String? titleZh;
    String? abstractZh;
    for (final analysis in _analyses.values) {
      if (analysis.status != PaperAnalysisStatus.succeeded) continue;
      titleZh ??= analysis.titleZh;
      abstractZh ??= analysis.abstractZh;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, l10n.papersAbstractZh),
        if (titleZh == null && abstractZh == null)
          Text(l10n.papersTranslationPending)
        else ...[
          if (titleZh != null) Text(titleZh),
          if (abstractZh != null) SelectableText(abstractZh),
        ],
      ],
    );
  }

  Widget _buildCitations(BuildContext context, L10n l10n) {
    final citation = _citation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, l10n.papersCitations),
        if (citation == null || citation.isUnknown)
          Text(l10n.papersCitationsUnknown)
        else ...[
          Text(
            citation.citationCount == 0
                ? l10n.papersCitationsZero
                : '${l10n.papersCitations}: ${citation.citationCount}',
          ),
          Text(l10n.papersCitationsSource),
          if (citation.lastSuccessAt != null)
            Text(
                '${l10n.papersCitationsUpdated}: ${citation.lastSuccessAt!.toLocal().toString().split('.').first}'),
          if (citation.isStale) Text(l10n.papersCitationsStale),
        ],
      ],
    );
  }

  Widget _buildSourceLinks(BuildContext context, L10n l10n, Paper paper) {
    final absUrl = paper.absUrl;
    final pdfUrl = paper.pdfUrl;
    final imported = _import?.status == PaperImportStatus.imported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, l10n.papersSourceLinks),
        Wrap(spacing: 12, children: [
          if (absUrl != null)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(absUrl)),
              child: Text(l10n.papersOpenArxiv),
            ),
          if (pdfUrl != null)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(pdfUrl)),
              child: const Text('PDF'),
            ),
          if (imported)
            TextButton(
              onPressed: _openInBookshelf,
              child: Text(l10n.papersOpenPdf),
            ),
          TextButton(
            onPressed: _analyzeNow,
            child: Text(l10n.papersAnalyzeNow),
          ),
        ]),
      ],
    );
  }

  /// Manual per-paper analysis using the shared quota; a quota failure or a
  /// missing service is surfaced instead of silently swallowed.
  Future<void> _analyzeNow() async {
    try {
      await ref
          .read(paperCollectionProvider.notifier)
          .analyzeNow(widget.arxivId);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  /// Open the imported PDF after verifying both the stored book id and the
  /// PDF MD5 — a main-library sync that reassigned ids must never open a
  /// different book that happens to share the old id.
  Future<void> _openInBookshelf() async {
    final l10n = L10n.of(context);
    final record = _import;
    if (record == null) return;
    try {
      final book = await PaperImportService().resolveOpenTarget(record);
      if (book == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.papersEmptyNoResults)),
          );
        }
        return;
      }
      if (!mounted) return;
      await pushToReadingPage(ref, context, book);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Widget _buildDiscovery(BuildContext context, L10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, l10n.papersDiscovery),
        for (final match in _matches)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${l10n.papersDiscoveryTask}: ${match.taskId} (${l10n.papersDiscoveryBranch}: ${match.branch.code})'),
                  Text(
                      '${l10n.papersLatest}: ${match.firstSeenAt.toLocal().toString().split('.').first}'),
                  _evidenceText(l10n, match.evidenceJson),
                ],
              ),
            ),
          ),
        if (_matches.isEmpty) Text(l10n.papersEmptyNoResults),
      ],
    );
  }

  Widget _evidenceText(L10n l10n, String evidenceJson) {
    try {
      final decoded = jsonDecode(evidenceJson);
      if (decoded is! Map) return const SizedBox.shrink();
      final map = Map<String, dynamic>.from(decoded);
      final lines = <String>[];
      for (final field in ['title', 'abstract']) {
        final hits = map[field];
        if (hits is Map) {
          for (final entry in hits.entries) {
            final phrases = entry.value;
            if (phrases is List && phrases.isNotEmpty) {
              lines.add('$field: ${phrases.join(' | ')}');
            }
          }
        }
      }
      final sourceOnly = map['source_returned_only'];
      if (sourceOnly is List && sourceOnly.isNotEmpty) {
        lines.add(l10n.papersDiscoverySourceReturned);
      }
      return Text(
        lines.isEmpty
            ? l10n.papersDiscoverySourceReturned
            : '${l10n.papersDiscoveryPhrases}: ${lines.join('; ')}',
      );
    } catch (_) {
      return Text(l10n.papersDiscoverySourceReturned);
    }
  }

  Widget _buildRelevance(BuildContext context, L10n l10n) {
    final entries = <Widget>[];
    for (final analysis in _analyses.values) {
      if (analysis.status != PaperAnalysisStatus.succeeded) continue;
      for (final assessment in analysis.assessments) {
        if (_profileHashes[assessment.taskId] != assessment.profileHash) {
          continue;
        }
        if (!_matches.any((match) =>
            match.taskId == assessment.taskId &&
            match.analysisCacheKey == analysis.cacheKey)) {
          continue;
        }
        entries.add(Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${l10n.papersRelevance}: ${assessment.relevanceScore}'
                    '  (${l10n.papersBasedOnAbstract})'),
                Text(assessment.reasonZh),
                if (assessment.evidence.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _sectionTitle(context, l10n.papersEvidence),
                  for (final quote in assessment.evidence)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '${quote.field}: "${quote.quote}"',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, l10n.papersRelevanceReason),
        if (entries.isEmpty) Text(l10n.papersRelevancePending),
        ...entries,
      ],
    );
  }
}
