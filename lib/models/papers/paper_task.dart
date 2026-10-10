import 'dart:convert';
import 'package:crypto/crypto.dart';

/// One keyword group: synonyms OR-ed together inside the group.
class PaperKeywordGroup {
  const PaperKeywordGroup({required this.synonyms});

  final List<String> synonyms;

  static const int configVersion = 1;

  factory PaperKeywordGroup.fromJson(Map<String, dynamic> json) {
    final version = json['v'] as int? ?? 1;
    if (version != configVersion) {
      throw FormatException('Unsupported keyword group version: $version');
    }
    final raw = json['synonyms'];
    if (raw is! List || raw.isEmpty) {
      throw FormatException('Keyword group requires synonyms');
    }
    final synonyms = raw
        .map((e) => (e as String).trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (synonyms.isEmpty) {
      throw FormatException('Keyword group requires synonyms');
    }
    return PaperKeywordGroup(synonyms: synonyms);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': configVersion,
        'synonyms': synonyms,
      };
}

class PaperAuthorWatch {
  const PaperAuthorWatch({required this.name, this.aliases = const []});

  final String name;
  final List<String> aliases;

  static const int configVersion = 1;

  factory PaperAuthorWatch.fromJson(Map<String, dynamic> json) {
    final version = json['v'] as int? ?? 1;
    if (version != configVersion) {
      throw FormatException('Unsupported author watch version: $version');
    }
    final name = (json['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      throw FormatException('Author watch requires a name');
    }
    final rawAliases = json['aliases'];
    final aliases = rawAliases is List
        ? rawAliases
            .map((e) => (e as String).trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    return PaperAuthorWatch(name: name, aliases: aliases);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': configVersion,
        'name': name,
        'aliases': aliases,
      };
}

/// Versioned task configuration stored as JSON in `paper_tasks.config_json`.
class PaperTaskConfig {
  const PaperTaskConfig({
    this.researchTopic = '',
    this.keywordGroups = const [],
    this.authors = const [],
    this.categories = const [],
    this.notInterested = '',
    this.groupOperatorOr = true,
    this.frequencyHours = 24,
    this.latestWindowDays = 30,
    this.hotWindowMonths = 12,
    this.aiProviderId,
    this.aiModelOverride,
  });

  final String researchTopic;
  final List<PaperKeywordGroup> keywordGroups;
  final List<PaperAuthorWatch> authors;
  final List<String> categories;
  final String notInterested;

  /// Groups combine with OR when true, AND when false (advanced mode).
  final bool groupOperatorOr;
  final int frequencyHours;
  final int latestWindowDays;
  final int hotWindowMonths;
  final String? aiProviderId;
  final String? aiModelOverride;

  static const int configVersion = 1;

  static const List<int> allowedFrequencyHours = [6, 12, 24, 48];

  /// Search conditions that make a task saveable: at least one keyword
  /// group, category, or watched author. Natural-language topic alone is
  /// not an executable search condition.
  bool get hasExecutableCondition =>
      keywordGroups.isNotEmpty || categories.isNotEmpty || authors.isNotEmpty;

  bool get wantsRelevance =>
      researchTopic.trim().isNotEmpty || keywordGroups.isNotEmpty;

  String get semanticHash =>
      sha256.convert(utf8.encode(semanticProfileSource())).toString();

  factory PaperTaskConfig.fromJson(Map<String, dynamic> json) {
    final version = json['v'] as int? ?? 1;
    if (version != configVersion) {
      throw FormatException('Unsupported task config version: $version');
    }
    List<T> mapList<T>(String key, T Function(Map<String, dynamic>) mapper) {
      final raw = json[key];
      if (raw is! List) return const [];
      return raw
          .map((e) => mapper(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false);
    }

    final frequency = json['frequency_hours'] as int? ?? 24;
    if (!allowedFrequencyHours.contains(frequency)) {
      throw FormatException('Invalid frequency hours: $frequency');
    }
    final latestDays = json['latest_window_days'] as int? ?? 30;
    if (latestDays <= 0) {
      throw FormatException('Invalid latest window days: $latestDays');
    }
    final hotMonths = json['hot_window_months'] as int? ?? 12;
    if (hotMonths <= 0) {
      throw FormatException('Invalid hot window months: $hotMonths');
    }

    return PaperTaskConfig(
      researchTopic: json['research_topic'] as String? ?? '',
      keywordGroups: mapList('keyword_groups', PaperKeywordGroup.fromJson),
      authors: mapList('authors', PaperAuthorWatch.fromJson),
      categories: (json['categories'] as List? ?? const [])
          .map((e) => (e as String).trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      notInterested: json['not_interested'] as String? ?? '',
      groupOperatorOr: json['group_operator_or'] as bool? ?? true,
      frequencyHours: frequency,
      latestWindowDays: latestDays,
      hotWindowMonths: hotMonths,
      aiProviderId: json['ai_provider_id'] as String?,
      aiModelOverride: json['ai_model_override'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': configVersion,
        'research_topic': researchTopic,
        'keyword_groups':
            keywordGroups.map((g) => g.toJson()).toList(growable: false),
        'authors': authors.map((a) => a.toJson()).toList(growable: false),
        'categories': categories,
        'not_interested': notInterested,
        'group_operator_or': groupOperatorOr,
        'frequency_hours': frequencyHours,
        'latest_window_days': latestWindowDays,
        'hot_window_months': hotWindowMonths,
        'ai_provider_id': aiProviderId,
        'ai_model_override': aiModelOverride,
      };

  /// Normalized text used for the task semantic hash. Window sizes, name,
  /// schedule and AI provider choice are intentionally excluded: they do
  /// not change what "relevant" means for this task.
  String semanticProfileSource() {
    return jsonEncode(<String, dynamic>{
      'research_topic': researchTopic.trim(),
      'keyword_groups': keywordGroups
          .map((g) => g.synonyms.map((s) => s.trim().toLowerCase()).toList())
          .toList(),
      'authors': authors
          .map((a) => {
                'name': a.name.trim().toLowerCase(),
                'aliases':
                    a.aliases.map((s) => s.trim().toLowerCase()).toList(),
              })
          .toList(),
      'categories': categories.map((c) => c.trim().toLowerCase()).toList(),
      'not_interested': notInterested.trim(),
    });
  }
}

/// Fields whose change increments `query_revision`.
bool taskConfigChangesQuery(PaperTaskConfig a, PaperTaskConfig b) {
  return a.researchTopic.trim() != b.researchTopic.trim() ||
      a.groupOperatorOr != b.groupOperatorOr ||
      a.notInterested.trim() != b.notInterested.trim() ||
      _jsonDiffers(
        a.keywordGroups.map((g) => g.toJson()).toList(),
        b.keywordGroups.map((g) => g.toJson()).toList(),
      ) ||
      _jsonDiffers(
        a.authors.map((e) => e.toJson()).toList(),
        b.authors.map((e) => e.toJson()).toList(),
      ) ||
      _jsonDiffers(a.categories, b.categories);
}

bool _jsonDiffers(Object a, Object b) => jsonEncode(a) != jsonEncode(b);

class PaperTask {
  PaperTask({
    required this.taskId,
    required this.name,
    required this.enabled,
    required this.priority,
    required this.config,
    required this.queryRevision,
    required this.createTime,
    required this.modifyTime,
    this.nextRunAt,
  });

  final String taskId;
  String name;
  bool enabled;

  /// 1 is the highest priority; valid range 1..5.
  int priority;
  PaperTaskConfig config;
  int queryRevision;
  final DateTime createTime;
  DateTime modifyTime;
  DateTime? nextRunAt;

  static const int configVersion = PaperTaskConfig.configVersion;

  factory PaperTask.fromDb(Map<String, dynamic> row) {
    final config = PaperTaskConfig.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(row['config_json'] as String) as Map,
      ),
    );
    final priority = row['priority'] as int? ?? 3;
    if (priority < 1 || priority > 5) {
      throw FormatException('Invalid task priority: $priority');
    }
    return PaperTask(
      taskId: row['task_id'] as String,
      name: row['name'] as String,
      enabled: (row['enabled'] as int? ?? 1) == 1,
      priority: priority,
      config: config,
      queryRevision: row['query_revision'] as int? ?? 1,
      createTime: DateTime.parse(row['create_time'] as String),
      modifyTime: DateTime.parse(row['modify_time'] as String),
      nextRunAt: row['next_run_at'] == null
          ? null
          : DateTime.parse(row['next_run_at'] as String),
    );
  }

  Map<String, dynamic> toDb() => <String, dynamic>{
        'task_id': taskId,
        'name': name,
        'enabled': enabled ? 1 : 0,
        'priority': priority,
        'config_json': jsonEncode(config.toJson()),
        'config_version': PaperTaskConfig.configVersion,
        'query_revision': queryRevision,
        'create_time': createTime.toIso8601String(),
        'modify_time': modifyTime.toIso8601String(),
        'next_run_at': nextRunAt?.toIso8601String(),
      };
}
