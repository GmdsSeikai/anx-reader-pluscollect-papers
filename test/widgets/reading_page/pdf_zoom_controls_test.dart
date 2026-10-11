import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/pdf_zoom_state.dart';
import 'package:anx_reader/widgets/reading_page/pdf_zoom_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.delegate.load(const Locale('en'));
    await L10n.delegate.load(const Locale('zh'));
  });
  Future<void> pumpControls(
      WidgetTester tester, PdfZoomState state, List<String> actions) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: PdfZoomControls(state: state, onZoom: actions.add)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('only PDF exposes zoom controls; loading disables every action',
      (tester) async {
    final actions = <String>[];
    await pumpControls(tester, const PdfZoomState(), actions);
    expect(find.byType(IconButton), findsNothing);
    await pumpControls(tester, const PdfZoomState(isPdf: true), actions);
    expect(find.text('100%'), findsOneWidget);
    expect(
        tester
            .widgetList<IconButton>(find.byType(IconButton))
            .every((button) => button.onPressed == null),
        isTrue);
    await tester.tap(find.byIcon(Icons.add));
    expect(actions, isEmpty);
  });

  testWidgets('reports current scale, sends actions and enforces both limits',
      (tester) async {
    final actions = <String>[];
    await pumpControls(tester,
        const PdfZoomState(isPdf: true, ready: true, percent: 175), actions);
    expect(find.text('175%'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.remove));
    await tester.tap(find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.fit_screen));
    expect(actions, ['out', 'in', 'reset']);

    await pumpControls(tester,
        const PdfZoomState(isPdf: true, ready: true, percent: 50), actions);
    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
            .onPressed,
        isNotNull);
    await pumpControls(tester,
        const PdfZoomState(isPdf: true, ready: true, percent: 300), actions);
    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.fit_screen))
            .onPressed,
        isNotNull);
  });

  testWidgets('fits in a narrow toolbar and uses Chinese tooltips',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
          body: Center(
              child: PdfZoomControls(
        state: const PdfZoomState(isPdf: true, ready: true),
        onZoom: (_) {},
      ))),
    ));
    await tester.pumpAndSettle();
    expect(find.byTooltip('重置为自动适配（Ctrl+0）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pan mode follows reader state and can switch to text selection',
      (tester) async {
    final actions = <String>[];
    await pumpControls(
        tester,
        const PdfZoomState(
            isPdf: true, ready: true, percent: 150, panMode: true),
        actions);
    final pan = find.byIcon(Icons.pan_tool);
    expect(pan, findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.ancestor(of: pan, matching: find.byType(IconButton)))
            .isSelected,
        isTrue);
    await tester.tap(pan);
    expect(actions, ['togglePan']);

    await pumpControls(tester,
        const PdfZoomState(isPdf: true, ready: true, percent: 150), actions);
    await tester.tap(find.byIcon(Icons.pan_tool_outlined));
    expect(actions, ['togglePan', 'togglePan']);

    await pumpControls(
        tester, const PdfZoomState(isPdf: true, ready: true), actions);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.pan_tool_outlined))
            .onPressed,
        isNull);
  });

  test('bridge state reads pan mode and defaults older messages to selection',
      () {
    expect(
        PdfZoomState.fromMap({
          'isPdf': true,
          'ready': true,
          'percent': 150,
          'panMode': true,
        }).panMode,
        isTrue);
    expect(
        PdfZoomState.fromMap({
          'isPdf': true,
          'ready': true,
          'percent': 100,
        }).panMode,
        isFalse);
  });
}
