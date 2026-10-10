import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/models/papers/paper.dart';
import 'package:anx_reader/service/ai/ai_rpm_limiter.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/papers/analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Real model factories and HTTP clients, with a controlled local SSE server.
// This verifies stream ownership, not the quality of a remote model's output.
class ModelFixture {
  late HttpServer server;
  final chat = Completer<HttpResponse>();
  final paper = Completer<HttpResponse>();
  int requests = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests++;
      final response = request.response;
      response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      final isPaper = body.contains('research-paper screening assistant');
      await emit(response, isPaper ? '{' : 'reading');
      (isPaper ? paper : chat).complete(response);
    });
  }

  Future<void> emit(HttpResponse response, String content) async {
    response.write('data: ${jsonEncode({
          'id': 'fixture',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'fixture-model',
          'choices': [
            {
              'index': 0,
              'delta': {'content': content},
              'finish_reason': null,
            }
          ],
        })}\n\n');
    await response.flush();
  }

  Future<void> finish(HttpResponse response, String content) async {
    await emit(response, content);
    response.write('data: [DONE]\n\n');
    await response.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Module integration uses only our loopback server; disable the widget
  // binding's unconditional HTTP 400 fixture for this test isolate.
  HttpOverrides.global = null;
  for (final cancelPaper in [true, false]) {
    test(
        cancelPaper
            ? 'paper cancellation leaves reading chat running'
            : 'reading cancellation leaves paper analysis running', () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs().initPrefs();
      Prefs().aiRpm = 100;
      AiRpmLimiter.instance.debugReset();
      final fixture = ModelFixture();
      await fixture.start();
      final provider = AiProvider(
        id: 'fixture',
        title: 'fixture',
        url: 'http://127.0.0.1:${fixture.server.port}/v1',
        protocol: AiProtocol.openai,
        model: 'fixture-model',
        apiKeys: const [AiApiKey(id: 'fixture', key: 'fixture-only')],
      );
      Prefs().saveAiProviders([provider]);
      final now = DateTime.utc(2026);
      final paper = Paper(
        arxivId: '2601.12345',
        latestVersion: 1,
        title: 'Detection',
        abstractText: 'Object detection.',
        authors: const [],
        categories: const ['cs.CV'],
        contentHash: 'body',
        publishedAt: now,
        updatedAt: now,
        firstSeenAt: now,
        lastSeenAt: now,
      );
      final service = AnalysisService();
      final values = <String>[];
      final chatDone = Completer<void>();
      final chatStream = aiGenerateStream(
        [ChatMessage.humanText('reading')],
        identifier: provider.id,
      ).listen(values.add, onDone: chatDone.complete);
      final analysis = service.analyze(
          paper: paper,
          tasks: const [],
          provider: provider,
          onRequestSent: () {});
      final cancelled = cancelPaper
          ? expectLater(analysis, throwsA(isA<AnalysisCancelledException>()))
          : null;
      try {
        final responses = await Future.wait([
          fixture.chat.future,
          fixture.paper.future,
        ]).timeout(const Duration(seconds: 5));
        expect(fixture.requests, 2);
        // Both production model clients have dispatched before cancellation.
        expect(AiRpmLimiter.instance.debugWindowCount, 2);
        if (cancelPaper) {
          service.cancel();
          await cancelled!.timeout(const Duration(seconds: 2));
          await fixture.finish(responses[0], ' continues');
          await chatDone.future.timeout(const Duration(seconds: 2));
          expect(values.last, 'reading continues');
        } else {
          cancelActiveAiRequest();
          await chatStream.cancel();
          await fixture.finish(
              responses[1],
              '"schema_version":1,"title_zh":"检测",'
              '"abstract_zh":"摘要","assessments":[]}');
          final result = await analysis.timeout(const Duration(seconds: 2));
          expect(result.titleZh, '检测');
          expect(result.assessments, isEmpty);
        }
        expect(fixture.requests, 2, reason: 'No fallback request was sent');
      } finally {
        service.cancel();
        cancelActiveAiRequest();
        await fixture.server.close(force: true);
        await chatStream.cancel().timeout(const Duration(seconds: 2));
        AiRpmLimiter.instance.debugReset();
      }
    });
  }
}
