import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/papers/paper_task.dart';
import 'package:anx_reader/service/papers/arxiv_client.dart';
import 'package:anx_reader/service/papers/collection_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// The five editable templates. They are never auto-enabled: the user must
/// select, edit and save before anything is collected.
class PaperTaskTemplate {
  const PaperTaskTemplate({
    required this.nameKey,
    required this.priority,
    required this.keywordGroups,
  });

  final String nameKey;
  final int priority;
  final List<List<String>> keywordGroups;
}

final List<PaperTaskTemplate> paperTaskTemplates = [
  const PaperTaskTemplate(
    nameKey: 'papersTemplateVision',
    priority: 1,
    keywordGroups: [
      ['object detection'],
      ['semantic segmentation'],
      ['instance segmentation'],
      ['knowledge distillation'],
    ],
  ),
  const PaperTaskTemplate(
    nameKey: 'papersTemplateIndustrialVision',
    priority: 2,
    keywordGroups: [
      ['industrial anomaly detection'],
      ['defect detection'],
      ['surface defect'],
      ['aircraft engine inspection'],
    ],
  ),
  const PaperTaskTemplate(
    nameKey: 'papersTemplateDeepLearning',
    priority: 3,
    keywordGroups: [
      ['deep learning'],
      ['representation learning'],
      ['self-supervised learning'],
      ['foundation model'],
    ],
  ),
  const PaperTaskTemplate(
    nameKey: 'papersTemplateMaterials',
    priority: 4,
    keywordGroups: [
      ['materials property prediction'],
      ['metal organic framework'],
      ['machine learning materials'],
      ['graph neural network materials'],
    ],
  ),
  const PaperTaskTemplate(
    nameKey: 'papersTemplateNetworkEdge',
    priority: 5,
    keywordGroups: [
      ['deep reinforcement learning routing'],
      ['edge intelligence'],
      ['computation offloading'],
      ['network optimization learning'],
    ],
  ),
];

/// Create/edit a collection task: search conditions, windows, frequency and
/// module-level AI selection. The UI never asks the user to write arXiv
/// query syntax; a preview shows the actual query and sample results.
class PaperTaskFormPage extends StatefulWidget {
  const PaperTaskFormPage({super.key, this.existing});

  final PaperTask? existing;

  @override
  State<PaperTaskFormPage> createState() => _PaperTaskFormPageState();
}

class _PaperTaskFormPageState extends State<PaperTaskFormPage> {
  late final TextEditingController _name;
  late final TextEditingController _topic;
  late final TextEditingController _keywords;
  late final TextEditingController _authors;
  late final TextEditingController _categories;
  late final TextEditingController _notInterested;
  late final TextEditingController _latestDays;
  late final TextEditingController _hotMonths;
  late final TextEditingController _modelOverride;

  bool _enabled = true;
  bool _groupAnd = false;
  int _priority = 3;
  int _frequencyHours = 24;
  String? _aiProviderId;

  String _queryPreview = '';
  List<ArxivEntry> _previewEntries = const [];
  bool _previewing = false;
  String? _error;
  final ArxivClient _previewClient = ArxivClient();

  @override
  void initState() {
    super.initState();
    final task = widget.existing;
    final config = task?.config ?? const PaperTaskConfig();
    _name = TextEditingController(text: task?.name ?? '');
    _topic = TextEditingController(text: config.researchTopic);
    _keywords = TextEditingController(
        text:
            config.keywordGroups.map((g) => g.synonyms.join(', ')).join('\n'));
    _authors = TextEditingController(
        text: config.authors
            .map((a) => a.aliases.isEmpty
                ? a.name
                : '${a.name} (${a.aliases.join(', ')})')
            .join('\n'));
    _categories = TextEditingController(text: config.categories.join(', '));
    _notInterested = TextEditingController(text: config.notInterested);
    _latestDays = TextEditingController(text: '${config.latestWindowDays}');
    _hotMonths = TextEditingController(text: '${config.hotWindowMonths}');
    _modelOverride = TextEditingController(text: config.aiModelOverride ?? '');
    _enabled = task?.enabled ?? true;
    _groupAnd = !config.groupOperatorOr;
    _priority = task?.priority ?? 3;
    _frequencyHours = config.frequencyHours;
    _aiProviderId = config.aiProviderId;
    _updateQueryPreview();
  }

  PaperTaskConfig _buildConfig() {
    final groups = _keywords.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => line
            .split(RegExp(r'[,，;；]'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false))
        .where((synonyms) => synonyms.isNotEmpty)
        .map((synonyms) => PaperKeywordGroup(synonyms: synonyms))
        .toList(growable: false);

    final authors = _authors.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) {
      final match = RegExp(r'^(.*?)\s*\((.*)\)\s*$').firstMatch(line);
      if (match != null) {
        final name = match.group(1)!.trim();
        final aliases = match
            .group(2)!
            .split(RegExp(r'[,，;；]'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
        return PaperAuthorWatch(name: name, aliases: aliases);
      }
      return PaperAuthorWatch(name: line);
    }).toList(growable: false);

    final categories = _categories.text
        .split(RegExp(r'[,，;；\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    return PaperTaskConfig(
      researchTopic: _topic.text.trim(),
      keywordGroups: groups,
      authors: authors,
      categories: categories,
      notInterested: _notInterested.text.trim(),
      groupOperatorOr: !_groupAnd,
      frequencyHours: _frequencyHours,
      latestWindowDays: int.tryParse(_latestDays.text.trim()) ?? 30,
      hotWindowMonths: int.tryParse(_hotMonths.text.trim()) ?? 12,
      aiProviderId: _aiProviderId,
      aiModelOverride: _modelOverride.text.trim().isEmpty
          ? null
          : _modelOverride.text.trim(),
    );
  }

  @override
  void dispose() {
    _previewClient.cancelActiveRequests();
    for (final controller in [
      _name,
      _topic,
      _keywords,
      _authors,
      _categories,
      _notInterested,
      _latestDays,
      _hotMonths,
      _modelOverride
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _updateQueryPreview() {
    final config = _buildConfig();
    final branches = buildTaskBranches(config);
    setState(() {
      _queryPreview = branches.isEmpty
          ? ''
          : branches.map((b) => '[${b.name}] ${b.searchQuery}').join('\n\n');
    });
  }

  Future<void> _runPreview() async {
    final config = _buildConfig();
    final branches = buildTaskBranches(config);
    if (branches.isEmpty) {
      setState(() => _error = L10n.of(context).papersNeedSearchCondition);
      return;
    }
    setState(() {
      _previewing = true;
      _error = null;
      _previewEntries = const [];
    });
    try {
      final client = _previewClient;
      final all = <ArxivEntry>[];
      for (final branch in branches) {
        final query = ArxivQueryBuilder.withDateRange(
          branch.searchQuery,
          DateTime.now()
              .toUtc()
              .subtract(Duration(days: config.latestWindowDays)),
          DateTime.now().toUtc(),
        );
        final page = await client.preview(query);
        if (!mounted) return;
        all.addAll(page.entries);
      }
      if (mounted) setState(() => _previewEntries = all);
    } catch (e) {
      AnxLog.warning('Task preview failed: $e');
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _save() async {
    final l10n = L10n.of(context);
    final config = _buildConfig();
    if (!config.hasExecutableCondition) {
      setState(() => _error = l10n.papersNeedSearchCondition);
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _error = l10n.papersTaskName);
      return;
    }

    final now = DateTime.now().toUtc();
    final existing = widget.existing;
    PaperTask task;
    if (existing != null) {
      final changedQuery = taskConfigChangesQuery(existing.config, config);
      task = PaperTask(
        taskId: existing.taskId,
        name: _name.text.trim(),
        enabled: _enabled,
        priority: _priority,
        config: config,
        queryRevision:
            changedQuery ? existing.queryRevision + 1 : existing.queryRevision,
        createTime: existing.createTime,
        modifyTime: now,
        nextRunAt: existing.nextRunAt,
      );
    } else {
      task = PaperTask(
        taskId: const Uuid().v4(),
        name: _name.text.trim(),
        enabled: _enabled,
        priority: _priority,
        config: config,
        queryRevision: 1,
        createTime: now,
        modifyTime: now,
      );
    }
    await PaperTaskDao().upsert(task);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.existing == null ? l10n.papersNewTask : l10n.papersTaskName),
        actions: [
          if (widget.existing != null)
            TextButton(
              onPressed: () async {
                // Deletion is archival: the task is disabled and its
                // discovered candidates and evidence are kept.
                await PaperTaskDao().setEnabled(widget.existing!.taskId, false);
                if (context.mounted) {
                  Navigator.of(context).pop(true);
                }
              },
              child: Text(l10n.papersDeleteTask),
            ),
          TextButton(onPressed: _save, child: Text(l10n.papersSave)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.existing == null) _templates(l10n),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: l10n.papersTaskName),
          ),
          SwitchListTile(
            title: Text(l10n.papersTaskEnabled),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          DropdownButtonFormField<int>(
            initialValue: _priority,
            decoration: InputDecoration(labelText: l10n.papersTaskPriority),
            items: [
              for (var i = 1; i <= 5; i++)
                DropdownMenuItem(value: i, child: Text('$i')),
            ],
            onChanged: (v) => setState(() => _priority = v ?? 3),
          ),
          TextField(
            controller: _topic,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l10n.papersResearchTopic,
              helperText: l10n.papersResearchTopicHint,
            ),
          ),
          TextField(
            controller: _keywords,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: l10n.papersKeywordGroups,
              helperText: l10n.papersKeywordGroupHint,
            ),
          ),
          SwitchListTile(
            title: Text(l10n.papersGroupOperator),
            value: _groupAnd,
            onChanged: (v) {
              setState(() => _groupAnd = v);
              _updateQueryPreview();
            },
          ),
          TextField(
            controller: _authors,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l10n.papersAuthors,
              helperText: l10n.papersAuthorsHint,
            ),
          ),
          TextField(
            controller: _categories,
            decoration: InputDecoration(
              labelText: l10n.papersCategories,
              helperText: l10n.papersCategoriesHint,
            ),
          ),
          TextField(
            controller: _notInterested,
            decoration: InputDecoration(labelText: l10n.papersNotInterested),
          ),
          DropdownButtonFormField<int>(
            initialValue:
                PaperTaskConfig.allowedFrequencyHours.contains(_frequencyHours)
                    ? _frequencyHours
                    : 24,
            decoration: InputDecoration(labelText: l10n.papersFrequency),
            items: [
              for (final hours in PaperTaskConfig.allowedFrequencyHours)
                DropdownMenuItem(
                  value: hours,
                  child: Text(l10n.papersFrequencyHours(hours)),
                ),
            ],
            onChanged: (v) => setState(() => _frequencyHours = v ?? 24),
          ),
          TextField(
            controller: _latestDays,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l10n.papersLatestWindowDays),
          ),
          TextField(
            controller: _hotMonths,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l10n.papersHotWindowMonths),
          ),
          TextField(
            controller: _modelOverride,
            decoration: InputDecoration(
              labelText: l10n.papersAiModelOverride,
              helperText: l10n.papersAiFollowService,
            ),
          ),
          const SizedBox(height: 12),
          _sectionTitle(l10n.papersQueryPreview),
          if (_queryPreview.isNotEmpty)
            SelectableText(
              _queryPreview,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          Row(children: [
            ElevatedButton(
              onPressed: _previewing ? null : _runPreview,
              child: Text(l10n.papersPreviewRun),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                _updateQueryPreview();
                _save();
              },
              child: Text(l10n.papersSave),
            ),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          if (_previewing) const CircularProgressIndicator(),
          if (_previewEntries.isNotEmpty) ...[
            const SizedBox(height: 8),
            _sectionTitle(l10n.papersPreviewResults),
            for (final entry in _previewEntries.take(5))
              ListTile(
                title: Text(entry.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(entry.arxivId),
              ),
          ],
        ],
      ),
    );
  }

  Widget _templates(L10n l10n) {
    String nameOf(PaperTaskTemplate t) {
      switch (t.nameKey) {
        case 'papersTemplateVision':
          return l10n.papersTemplateVision;
        case 'papersTemplateIndustrialVision':
          return l10n.papersTemplateIndustrialVision;
        case 'papersTemplateDeepLearning':
          return l10n.papersTemplateDeepLearning;
        case 'papersTemplateMaterials':
          return l10n.papersTemplateMaterials;
        default:
          return l10n.papersTemplateNetworkEdge;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l10n.papersNewTask),
        Wrap(
          spacing: 8,
          children: [
            for (final template in paperTaskTemplates)
              ActionChip(
                label: Text(nameOf(template)),
                onPressed: () {
                  setState(() {
                    _name.text = nameOf(template);
                    _priority = template.priority;
                    _keywords.text = template.keywordGroups
                        .map((g) => g.join(', '))
                        .join('\n');
                  });
                  _updateQueryPreview();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _sectionTitle(String text) =>
      Text(text, style: Theme.of(context).textTheme.titleMedium);
}
