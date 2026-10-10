import 'dart:async';

/// Scope tag for main-library write operations that must be mutually
/// exclusive (import commit, full-library sync replacement, storage
/// migration). Ordinary reading queries are intentionally not covered.
enum DbOperationScope { import, sync, migration }

/// Scope-aware mutual exclusion for operations that write or replace the
/// main book database.
///
/// A plain `isSyncing` flag only covers part of a sync run and leaves a
/// check-then-write gap; this lock is held from the point an operation
/// decides to touch the main library until it finishes or fails.
class DbOperationLock {
  DbOperationLock._();

  static final DbOperationLock instance = DbOperationLock._();

  Future<void> _tail = Future<void>.value();
  DbOperationScope? _holder;
  int _pending = 0;
  bool _accepting = true;

  DbOperationScope? get currentHolder => _holder;

  bool get isLocked => _holder != null;
  bool get isBusy => _pending > 0;
  bool get acceptsNewWork => _accepting;

  void suspendNewWork() => _accepting = false;
  void resumeNewWork() => _accepting = true;

  void requireAdmission() {
    if (!_accepting) throw StateError('Library operations are paused');
  }

  /// Run [action] with the lock held for [scope].
  ///
  /// Waits for any in-flight operation to finish first. Nested calls are not
  /// supported and would deadlock; callers must not invoke [runLocked] from
  /// inside another [runLocked] callback.
  Future<T> runLocked<T>(
    DbOperationScope scope,
    Future<T> Function() action,
  ) async {
    if (scope != DbOperationScope.migration) requireAdmission();
    _pending++;
    final Completer<void> release = Completer<void>();
    final Future<void> previous = _tail;
    _tail = release.future;
    await previous;
    _holder = scope;
    try {
      return await action();
    } finally {
      _pending--;
      _holder = null;
      if (!release.isCompleted) {
        release.complete();
      }
    }
  }

  /// Wait until no operation holds the lock (used before closing the DB).
  Future<void> waitForIdle() {
    return _tail;
  }
}
