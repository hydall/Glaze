import 'package:freezed_annotation/freezed_annotation.dart';

part 'tracker.freezed.dart';
part 'tracker.g.dart';

@freezed
abstract class Tracker with _$Tracker {
  const factory Tracker({
    required String sessionId,
    required String name,
    @Default('') String value,
    @Default('chat') String scope,
    @Default('') String provenance,
    @Default(0) int updatedAt,
  }) = _Tracker;

  factory Tracker.fromJson(Map<String, dynamic> json) =>
      _$TrackerFromJson(json);
}
