import 'package:freezed_annotation/freezed_annotation.dart';

part 'extra_request_parameter.freezed.dart';
part 'extra_request_parameter.g.dart';

@freezed
abstract class ExtraRequestParameter with _$ExtraRequestParameter {
  const factory ExtraRequestParameter({
    @Default('') String key,
    @Default('') String value,
    @Default(true) bool enabled,
  }) = _ExtraRequestParameter;

  factory ExtraRequestParameter.fromJson(Map<String, dynamic> json) =>
      _$ExtraRequestParameterFromJson(json);
}
