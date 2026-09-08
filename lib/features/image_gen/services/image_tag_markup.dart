import 'dart:convert';

import '../../../core/constants/image_gen_patterns.dart';

/// Pure text transformations for `[IMG:GEN]` / `[IMG:RESULT:]` / `[IMG:ERROR]`
/// image-gen tag markup. Has no dependency on image generation, file I/O, or
/// network — only on [ImgGenPatterns] and JSON encoding.
class ImageTagMarkup {
  ImageTagMarkup._();

  static bool hasImageGenTags(String text) {
    if (ImgGenPatterns.htmlIigTagRegex.hasMatch(text) ||
        ImgGenPatterns.htmlIigTagDoubleRegex.hasMatch(text)) {
      return true;
    }
    final stripped = ImgGenPatterns.stripHtmlImgTags(text);
    return ImgGenPatterns.imgGenRegex.hasMatch(stripped);
  }

  static List<Map<String, dynamic>> extractImageGenInstructions(String text) {
    final results = <Map<String, dynamic>>[];

    for (final m in ImgGenPatterns.htmlIigTagRegex.allMatches(text)) {
      final payload = m.group(1);
      if (payload == null || payload.isEmpty) continue;
      try {
        results.add(jsonDecode(payload) as Map<String, dynamic>);
      } catch (_) {
        results.add(<String, dynamic>{'prompt': payload});
      }
    }

    for (final m in ImgGenPatterns.htmlIigTagDoubleRegex.allMatches(text)) {
      final payload = m.group(1);
      if (payload == null || payload.isEmpty) continue;
      try {
        results.add(jsonDecode(payload) as Map<String, dynamic>);
      } catch (_) {
        results.add(<String, dynamic>{'prompt': payload});
      }
    }

    final stripped = ImgGenPatterns.stripHtmlImgTags(text);
    for (final m in ImgGenPatterns.imgGenRegex.allMatches(stripped)) {
      final payload = m.group(1);
      if (payload == null || payload.isEmpty) {
        results.add(<String, dynamic>{'prompt': ''});
        continue;
      }
      try {
        results.add(jsonDecode(payload) as Map<String, dynamic>);
      } catch (_) {
        results.add(<String, dynamic>{'prompt': payload});
      }
    }

    return results;
  }

  static String replaceTagWithResult(String text, int index, String imagePath) {
    final instructions = extractImageGenInstructions(text);
    final instruction =
        index < instructions.length ? instructions[index] : null;
    final instrJson = instruction != null && instruction.isNotEmpty
        ? jsonEncode(instruction)
        : '';
    final payload = instrJson.isNotEmpty ? '$imagePath|$instrJson' : imagePath;
    int count = 0;
    var result = text.replaceAllMapped(ImgGenPatterns.htmlIigTagRegex, (m) {
      if (count++ == index) return '[IMG:RESULT:$payload]';
      return m.group(0)!;
    });
    result = result.replaceAllMapped(ImgGenPatterns.htmlIigTagDoubleRegex, (m) {
      if (count++ == index) return '[IMG:RESULT:$payload]';
      return m.group(0)!;
    });
    result = result.replaceAllMapped(ImgGenPatterns.imgSrcGenRegex, (m) {
      if (count++ == index) return '[IMG:RESULT:$payload]';
      return m.group(0)!;
    });
    final stripped = ImgGenPatterns.stripHtmlImgTags(result);
    final needStrip = stripped != result;
    result = result.replaceAllMapped(ImgGenPatterns.imgGenRegex, (m) {
      if (count++ == index) return '[IMG:RESULT:$payload]';
      return m.group(0)!;
    });
    if (count <= index) return text;
    return needStrip ? ImgGenPatterns.stripHtmlImgTags(result) : result;
  }

  static String replaceTagWithError(String text, int index, String error) {
    final instructions = extractImageGenInstructions(text);
    final instructionJson = index < instructions.length
        ? jsonEncode(instructions[index])
        : '';
    final encoded = jsonEncode({
      'error': error,
      if (instructionJson.isNotEmpty) 'instruction': instructionJson,
    });
    int count = 0;
    var result = text.replaceAllMapped(ImgGenPatterns.htmlIigTagRegex, (m) {
      if (count++ == index) return '[IMG:ERROR:$encoded]';
      return m.group(0)!;
    });
    result = result.replaceAllMapped(ImgGenPatterns.htmlIigTagDoubleRegex, (m) {
      if (count++ == index) return '[IMG:ERROR:$encoded]';
      return m.group(0)!;
    });
    result = result.replaceAllMapped(ImgGenPatterns.imgSrcGenRegex, (m) {
      if (count++ == index) return '[IMG:ERROR:$encoded]';
      return m.group(0)!;
    });
    final stripped = ImgGenPatterns.stripHtmlImgTags(result);
    final needStrip = stripped != result;
    result = result.replaceAllMapped(ImgGenPatterns.imgGenRegex, (m) {
      if (count++ == index) return '[IMG:ERROR:$encoded]';
      return m.group(0)!;
    });
    if (count <= index) return text;
    return needStrip ? ImgGenPatterns.stripHtmlImgTags(result) : result;
  }

  static String resetErrorTags(String text) {
    var result = text.replaceAllMapped(ImgGenPatterns.imgErrorRegex, (m) {
      try {
        final json = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        final instruction = json['instruction'] as String?;
        if (instruction != null && instruction.isNotEmpty) {
          return '[IMG:GEN:$instruction]';
        }
      } catch (_) {}
      return '[IMG:GEN]';
    });
    result = result.replaceAllMapped(ImgGenPatterns.imgResultRegex, (m) {
      final raw = m.group(1) ?? '';
      final pipeIdx = raw.indexOf('|');
      final instr = pipeIdx != -1 ? raw.substring(pipeIdx + 1) : null;
      if (instr != null && instr.isNotEmpty) {
        return '[IMG:GEN:$instr]';
      }
      return '[IMG:GEN]';
    });
    return result;
  }

  static List<String> extractImageResultPaths(String text) {
    return ImgGenPatterns.imgResultRegex
        .allMatches(text)
        .map((m) => normalizeImageResultPayload(m.group(1) ?? ''))
        .where((p) => p.isNotEmpty)
        .toList();
  }

  /// Strips optional `|instructionJson` suffix from [IMG:RESULT:…] payloads.
  static String normalizeImageResultPayload(String payload) {
    final pipeIdx = payload.indexOf('|');
    return pipeIdx != -1 ? payload.substring(0, pipeIdx) : payload;
  }

  /// [contentsNewestFirst] — text blobs ordered newest → oldest (e.g. ext-block bodies).
  static List<String> collectRecentImageResultPaths(
    Iterable<String> contentsNewestFirst, {
    int maxPaths = 3,
  }) {
    final collected = <String>[];
    for (final content in contentsNewestFirst) {
      if (collected.length >= maxPaths) break;
      for (final path in extractImageResultPaths(content)) {
        if (collected.length >= maxPaths) break;
        collected.add(path);
      }
    }
    return collected.reversed.toList();
  }

  /// Reads image instructions from pending [IMG:GEN] tags or finished
  /// [IMG:RESULT:path|json] tokens inside ext-block HTML.
  static List<Map<String, dynamic>> extractInstructionsFromImageContent(
    String text,
  ) {
    final fromGen = extractImageGenInstructions(text);
    if (fromGen.isNotEmpty) return fromGen;

    final fromResult = <Map<String, dynamic>>[];
    for (final match in ImgGenPatterns.imgResultRegex.allMatches(text)) {
      final raw = match.group(1) ?? '';
      final pipeIdx = raw.indexOf('|');
      if (pipeIdx < 0 || pipeIdx >= raw.length - 1) continue;
      try {
        fromResult.add(
          jsonDecode(raw.substring(pipeIdx + 1)) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    return fromResult;
  }

  /// Replaces the [index]-th [IMG:RESULT:…] token, preserving instruction JSON.
  static String replaceExtBlockImageResult(
    String text,
    String newPath, {
    int index = 0,
  }) {
    var count = 0;
    return text.replaceAllMapped(ImgGenPatterns.imgResultRegex, (match) {
      if (count++ != index) return match.group(0)!;
      final raw = match.group(1)!;
      final pipeIdx = raw.indexOf('|');
      final suffix = pipeIdx != -1 ? raw.substring(pipeIdx) : '';
      return '[IMG:RESULT:$newPath$suffix]';
    });
  }
}
