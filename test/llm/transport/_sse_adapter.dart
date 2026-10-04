import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Minimal Dio [HttpClientAdapter] that replays a canned SSE body for every
/// request. Used to exercise the streaming parse path of transports without a
/// real network round-trip.
class SseAdapter implements HttpClientAdapter {
  SseAdapter(this.body, {this.chunkSizes = const []});
  final String body;
  final List<int> chunkSizes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(body));
    final chunks = <Uint8List>[];
    var offset = 0;
    for (final size in chunkSizes) {
      if (offset >= bytes.length) break;
      final end = (offset + size).clamp(offset, bytes.length);
      chunks.add(Uint8List.fromList(bytes.sublist(offset, end)));
      offset = end;
    }
    if (offset < bytes.length) {
      chunks.add(Uint8List.fromList(bytes.sublist(offset)));
    }
    return ResponseBody(
      Stream<Uint8List>.fromIterable(chunks),
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
