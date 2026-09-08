import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Minimal Dio [HttpClientAdapter] that replays a canned SSE body for every
/// request. Used to exercise the streaming parse path of transports without a
/// real network round-trip.
class SseAdapter implements HttpClientAdapter {
  SseAdapter(this.body);
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(body));
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
