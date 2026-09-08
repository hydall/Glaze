import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'picks_models.dart';

const kPicksBaseUrl =
    'https://raw.githubusercontent.com/hydall/Glaze/master/picks';

final _dio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(seconds: 30),
));

final picksIndexProvider = FutureProvider<PicksIndex>((ref) async {
  final res = await _dio.get<String>('$kPicksBaseUrl/index.json');
  final json = jsonDecode(res.data!) as Map<String, dynamic>;
  return PicksIndex.fromJson(json);
});

Future<List<int>> fetchPicksCharacterPng(String relativePath) async {
  final res = await _dio.get<List<int>>(
    '$kPicksBaseUrl/$relativePath',
    options: Options(responseType: ResponseType.bytes),
  );
  return res.data ?? [];
}
