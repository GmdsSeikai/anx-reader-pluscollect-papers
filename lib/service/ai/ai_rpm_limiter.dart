import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';

/// Shared AI requests-per-minute limiter.
///
/// Owns the rate quota only: callers own requests and cancellation.
/// Reservation happens when a request is about to be sent, so chat and
/// paper analysis share the same `Prefs().aiRpm` window without each
/// taking a full private quota.
class AiRpmLimiter {
  AiRpmLimiter._();

  static final AiRpmLimiter instance = AiRpmLimiter._();

  final List<DateTime> _requestTimestamps = <DateTime>[];
  Future<void>? _inFlight;

  /// Atomically wait for a slot and reserve it.
  ///
  /// Returns after the slot is recorded. Cancellation before the returned
  /// future completes simply aborts the wait; the caller must not send the
  /// request in that case, so no slot is consumed by an unsent request.
  Future<void> reserve({Future<void>? cancelWhen}) {
    var cancelled = false;
    cancelWhen?.then((_) => cancelled = true);
    // Serialize reserve callers so two requests cannot both observe a free
    // slot inside the same millisecond window.
    final previous = _inFlight;
    final Future<void> gate = previous == null
        ? Future<void>.value()
        : previous.then<void>((_) {}, onError: (_) {});
    final Future<void> task = gate.then((_) =>
        _waitAndRecord(isCancelled: () => cancelled, cancelWhen: cancelWhen));
    _inFlight = task;
    // Observe the queued task even when the caller cancels before its turn.
    void release() {
      if (identical(_inFlight, task)) _inFlight = null;
    }

    task.then((_) => release(),
        onError: (Object _, StackTrace __) => release());
    final awaited = cancelWhen == null
        ? task
        : Future.any<void>([
            task,
            cancelWhen.then<void>((_) => throw AiRateWaitCancelled()),
          ]);
    return awaited;
  }

  Future<void> _waitAndRecord({
    required bool Function() isCancelled,
    Future<void>? cancelWhen,
  }) async {
    if (isCancelled()) throw AiRateWaitCancelled();
    final int rpm = Prefs().aiRpm;
    if (rpm <= 0) {
      _requestTimestamps.add(DateTime.now());
      return;
    }
    while (true) {
      if (isCancelled()) throw AiRateWaitCancelled();
      final DateTime now = DateTime.now();
      final DateTime windowStart = now.subtract(const Duration(minutes: 1));
      _requestTimestamps.removeWhere((ts) => ts.isBefore(windowStart));
      if (_requestTimestamps.length < rpm) {
        _requestTimestamps.add(DateTime.now());
        return;
      }
      final DateTime oldest = _requestTimestamps.first;
      final Duration wait =
          oldest.add(const Duration(minutes: 1)).difference(DateTime.now());
      if (wait > Duration.zero) {
        await Future.any<void>([
          Future<void>.delayed(wait),
          if (cancelWhen != null)
            cancelWhen.then<void>((_) => throw AiRateWaitCancelled()),
        ]);
      }
    }
  }

  /// Testing helper: number of reservations currently inside the window.
  int get debugWindowCount {
    final DateTime windowStart =
        DateTime.now().subtract(const Duration(minutes: 1));
    return _requestTimestamps.where((ts) => !ts.isBefore(windowStart)).length;
  }

  /// Testing helper.
  void debugReset() {
    _requestTimestamps.clear();
    _inFlight = null;
  }
}

class AiRateWaitCancelled implements Exception {}
