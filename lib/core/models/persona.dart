import 'package:freezed_annotation/freezed_annotation.dart';

part 'persona.freezed.dart';
part 'persona.g.dart';

@freezed
abstract class Persona with _$Persona {
  const factory Persona({
    required String id,
    required String name,
    String? displayName,
    String? prompt,
    String? avatarPath,
    @Default(0) int createdAt,
  }) = _Persona;

  factory Persona.fromJson(Map<String, dynamic> json) =>
      _$PersonaFromJson(json);
}

@freezed
abstract class PersonaConnections with _$PersonaConnections {
  const factory PersonaConnections({
    @Default({}) Map<String, String> character,
    @Default({}) Map<String, String> chat,
  }) = _PersonaConnections;

  factory PersonaConnections.fromJson(Map<String, dynamic> json) =>
      _$PersonaConnectionsFromJson(json);
}
