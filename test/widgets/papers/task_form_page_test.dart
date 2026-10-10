import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/papers/paper_dao.dart';
import 'package:anx_reader/dao/papers/paper_database.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/papers/task_form_page.dart';
import 'package:anx_reader/service/papers/collection_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('paper-form-test');
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    PaperDatabase.instance.debugDbPathOverride = p.join(root.path, 'papers.db');
    await PaperDatabase.instance.open();
  });
  tearDown(() async {
    await PaperDatabase.instance.close();
    PaperDatabase.instance.debugDbPathOverride = null;
    await root.delete(recursive: true);
  });
  testWidgets('templates require explicit save and persist independent authors',
      (tester) async {
    try {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => const PaperTaskFormPage())),
                      child: const Text('Create')),
                )),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.byType(ActionChip), findsNWidgets(5));
      expect(await tester.runAsync(() => PaperTaskDao().selectAll()), isEmpty);
      await tester.tap(find.byType(ActionChip).first);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => PaperTaskDao().selectAll()), isEmpty);
      final authors = find.byWidgetPredicate((widget) =>
          widget is TextField && widget.decoration?.labelText == '关注作者');
      await tester.scrollUntilVisible(authors, 250,
          scrollable: find.byType(Scrollable).first);
      await tester.enterText(authors, 'Ashish Vaswani');
      final enabled = find.byWidgetPredicate((widget) =>
          widget is SwitchListTile &&
          widget.title is Text &&
          (widget.title as Text).data == '自动运行');
      await tester.scrollUntilVisible(enabled, -250,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(enabled);
      await tester.pump();
      await tester.tap(find
          .descendant(
              of: find.byType(AppBar), matching: find.byType(TextButton))
          .last);
      await tester.pumpAndSettle();
      final task =
          (await tester.runAsync(() => PaperTaskDao().selectAll()))!.single;
      expect(task.enabled, isFalse);
      expect(task.priority, 1);
      expect(task.config.latestWindowDays, 30);
      expect(task.config.hotWindowMonths, 12);
      final branches = buildTaskBranches(task.config);
      expect(
          branches.any((branch) => branch.name.startsWith('author:')), isTrue);
      expect(branches.any((branch) => branch.name == 'topic'), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });
}
