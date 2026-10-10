import 'package:dio/dio.dart';

Future<void> waitForPaperRequest(Duration delay, CancelToken token) async {
  if (token.isCancelled) throw token.cancelError!;
  await Future.any<void>([
    Future<void>.delayed(delay),
    token.whenCancel.then<void>((error) => throw error),
  ]);
}
