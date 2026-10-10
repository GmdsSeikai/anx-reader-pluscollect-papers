import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/ai/ai_rpm_limiter.dart';
import 'package:anx_reader/service/db_operation_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiRpmLimiter', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs().initPrefs();
      AiRpmLimiter.instance.debugReset();
    });

    test('rpm 0 means unlimited: reservations do not block', () async {
      Prefs().aiRpm = 0;
      for (var i = 0; i < 5; i++) {
        await AiRpmLimiter.instance.reserve();
      }
      expect(AiRpmLimiter.instance.debugWindowCount, 5);
    });

    test('P09-style: chat and collection share one quota', () async {
      Prefs().aiRpm = 2;
      await AiRpmLimiter.instance.reserve();
      await AiRpmLimiter.instance.reserve();
      expect(AiRpmLimiter.instance.debugWindowCount, 2);

      // A third reservation within the window must wait; verify it does
      // not complete within a short delay (it is waiting on the window).
      var completed = false;
      final cancellation = Completer<void>();
      final waiting =
          AiRpmLimiter.instance.reserve(cancelWhen: cancellation.future);
      final expectation =
          expectLater(waiting, throwsA(isA<AiRateWaitCancelled>()));
      waiting.then((_) {
        completed = true;
      }, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(completed, isFalse,
          reason: 'the third request must wait for the RPM window');
      cancellation.complete();
      await expectation;
      expect(AiRpmLimiter.instance.debugWindowCount, 2,
          reason: 'an unsent cancelled request never consumes a reservation');
    });

    test('serialized reservation is atomic under concurrency', () async {
      Prefs().aiRpm = 3;
      await Future.wait([
        AiRpmLimiter.instance.reserve(),
        AiRpmLimiter.instance.reserve(),
        AiRpmLimiter.instance.reserve(),
      ]);
      expect(AiRpmLimiter.instance.debugWindowCount, 3);
    });
  });

  group('DbOperationLock', () {
    test('suspension rejects new work while accepted waiters drain', () async {
      final lock = DbOperationLock.instance;
      final release = Completer<void>();
      final first =
          lock.runLocked(DbOperationScope.import, () => release.future);
      final queued = lock.runLocked(DbOperationScope.sync, () async {});
      lock.suspendNewWork();
      try {
        expect(lock.isBusy, isTrue);
        await expectLater(lock.runLocked(DbOperationScope.import, () async {}),
            throwsStateError);
        release.complete();
        await Future.wait([first, queued]);
        expect(lock.isBusy, isFalse);
        await lock.runLocked(DbOperationScope.migration, () async {});
      } finally {
        lock.resumeNewWork();
      }
    });
    test('mutual exclusion across scopes', () async {
      final order = <String>[];
      final first =
          DbOperationLock.instance.runLocked(DbOperationScope.import, () async {
        order.add('import-start');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add('import-end');
        return 1;
      });
      final second =
          DbOperationLock.instance.runLocked(DbOperationScope.sync, () async {
        order.add('sync-start');
        return 2;
      });

      final results = await Future.wait([first, second]);
      expect(results, [1, 2]);
      expect(order, ['import-start', 'import-end', 'sync-start']);
      expect(DbOperationLock.instance.isLocked, isFalse);
    });

    test('migration scope also excludes imports', () async {
      final order = <String>[];
      final migration = DbOperationLock.instance
          .runLocked(DbOperationScope.migration, () async {
        order.add('migration');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      final import =
          DbOperationLock.instance.runLocked(DbOperationScope.import, () async {
        order.add('import');
      });
      await Future.wait([migration, import]);
      expect(order, ['migration', 'import']);
    });

    test('waitForIdle resolves when the lock is free', () async {
      final running =
          DbOperationLock.instance.runLocked(DbOperationScope.sync, () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await DbOperationLock.instance.waitForIdle();
      await running;
      expect(DbOperationLock.instance.isLocked, isFalse);
    });
  });
}
