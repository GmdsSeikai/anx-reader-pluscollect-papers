import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/models/papers/paper_records.dart';
import 'package:anx_reader/providers/paper_collection.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/widgets/settings/settings_section.dart';
import 'package:anx_reader/widgets/settings/settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Paper collection settings: daily analysis quota, the analysis service
/// and model override selection, and the optional Semantic Scholar key
/// (masked, excluded from settings export/import).
class PaperCollectionSettings extends ConsumerStatefulWidget {
  const PaperCollectionSettings({super.key});

  @override
  ConsumerState<PaperCollectionSettings> createState() =>
      _PaperCollectionSettingsState();
}

class _PaperCollectionSettingsState
    extends ConsumerState<PaperCollectionSettings> {
  final TextEditingController _s2Key =
      TextEditingController(text: Prefs().semanticScholarApiKey);
  final TextEditingController _dailyLimit = TextEditingController();
  final TextEditingController _modelOverride = TextEditingController();
  int _dailyLimitValue = 100;
  int _usedToday = 0;
  String? _analysisProviderId;
  List<AiProvider> _providers = const [];

  @override
  void initState() {
    super.initState();
    _dailyLimit.text = '$_dailyLimitValue';
    _loadState();
  }

  Future<void> _loadState() async {
    // AI providers come from existing prefs; no new credential storage.
    try {
      final raw = Prefs().getAiProviders();
      final providers = raw
          .map((json) =>
              AiProvider.fromJson(Map<String, dynamic>.from(json as Map)))
          .toList(growable: false);
      if (mounted) setState(() => _providers = providers);
    } catch (_) {}
    if (!AnxPlatform.isWindows) return;
    try {
      final settings = await PaperSettingsDao().get();
      if (!mounted) return;
      setState(() {
        _dailyLimitValue = settings.dailyLimit;
        _dailyLimit.text = '$_dailyLimitValue';
        _analysisProviderId = settings.analysisProviderId;
        _modelOverride.text = settings.analysisModelOverride ?? '';
        final day = PaperSettings.quotaDayOf(DateTime.now().toUtc());
        _usedToday = settings.quotaDay == day ? settings.reservedCount : 0;
      });
    } catch (_) {
      // Paper database not available; the section stays inert.
    }
  }

  @override
  void dispose() {
    _s2Key.dispose();
    _dailyLimit.dispose();
    _modelOverride.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    if (!AnxPlatform.isWindows) return const SizedBox.shrink();

    // Live quota: collection commits bump paperDataVersion.
    ref.listen(paperDataVersion, (previous, next) {
      if (previous != next) _loadState();
    });

    // A deleted service must show a recoverable state instead of asserting
    // a Dropdown value that no longer exists in items.
    final selectedExists =
        _analysisProviderId == null ||
        _providers.any((p) => p.id == _analysisProviderId);
    final dropdownValue = selectedExists ? _analysisProviderId : null;

    return SettingsSection(
      title: Text(l10n.papersSettingsSection),
      tiles: [
        SettingsTile(
          title: Text(l10n.papersDailyQuota),
          description: Text(l10n.papersQuotaUsed(_dailyLimitValue, _usedToday)),
          trailing: SizedBox(
            width: 80,
            child: TextField(
              controller: _dailyLimit,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (value) async {
                final parsed = int.tryParse(value.trim());
                if (parsed == null || parsed < 0) return;
                try {
                  await PaperSettingsDao().updateDailyLimit(parsed);
                  await _loadState();
                } catch (_) {}
              },
            ),
          ),
        ),
        if (_providers.isNotEmpty)
          SettingsTile(
            title: Text(l10n.papersAiProvider),
            description: selectedExists
                ? null
                : Text(l10n.papersTranslationPending),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<String?>(
                  value: dropdownValue,
                  items: [
                    DropdownMenuItem<String?>(
                      child: Text(l10n.papersAiFollowService),
                    ),
                    for (final provider in _providers)
                      DropdownMenuItem<String?>(
                        value: provider.id,
                        child: Text(provider.title),
                      ),
                  ],
                  onChanged: (value) async {
                    try {
                      await PaperSettingsDao().updateAnalysisService(
                        providerId: value,
                        modelOverride: _modelOverride.text.trim().isEmpty
                            ? null
                            : _modelOverride.text.trim(),
                      );
                      await _loadState();
                    } catch (_) {}
                  },
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _modelOverride,
                    decoration: InputDecoration(
                      labelText: l10n.papersAiModelOverride,
                      hintText: l10n.papersAiFollowService,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (value) async {
                      try {
                        await PaperSettingsDao().updateAnalysisService(
                          providerId: _analysisProviderId,
                          modelOverride:
                              value.trim().isEmpty ? null : value.trim(),
                        );
                        await _loadState();
                      } catch (_) {}
                    },
                  ),
                ),
              ],
            ),
          ),
        SettingsTile(
          title: Text(l10n.papersSemanticScholarKey),
          description: Text(l10n.papersSemanticScholarKeyMasked),
          trailing: SizedBox(
            width: 220,
            child: TextField(
              controller: _s2Key,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: '********',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (value) {
                // The citation client reads the key per request, so an
                // updated key takes effect on the next lookup.
                Prefs().semanticScholarApiKey = value;
              },
            ),
          ),
        ),
      ],
    );
  }
}
