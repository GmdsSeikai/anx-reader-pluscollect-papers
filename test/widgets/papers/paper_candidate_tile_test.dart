import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/providers/paper_list.dart';
import 'package:anx_reader/widgets/papers/paper_candidate_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PaperListItem candidate({int? citations}) {
  final date = DateTime.utc(2026, 10, 10);
  return PaperListItem(
    paper: Paper(
      arxivId: '2610.01234',
      latestVersion: 1,
      title: 'A newly discovered paper',
      authors: [const PaperAuthor(name: 'Fixture Author')],
      abstractText: 'A fixture abstract.',
      categories: ['cs.CV'],
      publishedAt: date,
      updatedAt: date,
      contentHash: 'fixture',
      firstSeenAt: date,
      lastSeenAt: date,
    ),
    ruleScore: 40,
    aiScore: null,
    assessmentPending: true,
    assessmentTaskName: null,
    citationCount: citations,
    citationUnknown: citations == null,
    citationStale: false,
    imported: false,
    authorWatch: true,
    lowRelevance: false,
    taskNames: ['Vision'],
  );
}

void main() {
  testWidgets('unknown and zero citations stay distinct and actionable',
      (tester) async {
    final selected = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            for (final entry in {'unknown': null, 'zero': 0}.entries)
              PaperCandidateTile(
                item: candidate(citations: entry.value),
                selected: false,
                onTap: () => opened.add(entry.key),
                onSelectionChanged: (value) {
                  if (value == true) selected.add(entry.key);
                },
              ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('引用统计待补充'), findsOneWidget);
    expect(find.text('尚无引用'), findsOneWidget);
    expect(find.text('待分析'), findsNWidgets(2));
    expect(find.byType(Checkbox), findsNWidgets(2));
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(selected, ['unknown']);
    expect(opened, isEmpty);
    await tester.tap(find.text('A newly discovered paper').first);
    await tester.pump();
    expect(opened, ['unknown']);
    expect(tester.takeException(), isNull);
  });
}
