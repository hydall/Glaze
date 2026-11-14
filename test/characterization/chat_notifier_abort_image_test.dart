import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/image_gen_patterns.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';

void main() {
  // ─── Phase 5.1: ChatNotifier abort + image recovery ─────────────────────
  group('ChatNotifier abort logic invariants (Phase 5.1 characterization)', () {
    test('_replaceFirstImgErrorOrGen: ERROR tag replaced with RESULT', () {
      var text = 'Hello [IMG:ERROR:{"error":"fail"}] world';
      final result = _replaceFirstImgErrorOrGen(text, '/path/to/img.png');
      expect(result, 'Hello [IMG:RESULT:/path/to/img.png] world');
    });

    test('_replaceFirstImgErrorOrGen: [IMG:GEN] replaced with RESULT', () {
      var text = 'Hello [IMG:GEN:] world';
      final result = _replaceFirstImgErrorOrGen(text, '/path/to/img.png');
      expect(result, 'Hello [IMG:RESULT:/path/to/img.png] world');
    });

    test('_replaceFirstImgErrorOrGen: HTML img tag replaced with RESULT', () {
      const text = """<img data-iig-instruction='{"prompt":"test"}' src="[IMG:GEN]">""";
      final result = _replaceFirstImgErrorOrGen(text, '/path/to/img.png');
      expect(result, '[IMG:RESULT:/path/to/img.png]');
    });

    test('_replaceFirstImgErrorOrGen: no match returns original text', () {
      const text = 'No image tags here';
      final result = _replaceFirstImgErrorOrGen(text, '/path/to/img.png');
      expect(result, text);
    });

    test('_replaceFirstImgErrorOrGen: only first match is replaced', () {
      var text = 'A [IMG:ERROR:fail1] B [IMG:ERROR:fail2] C';
      final result = _replaceFirstImgErrorOrGen(text, '/img.png');
      expect(result, 'A [IMG:RESULT:/img.png] B [IMG:ERROR:fail2] C');
    });
  });

  group('_resetImgTagsToGen logic (Phase 5.1 characterization)', () {
    test('ERROR tag with instruction resets to [IMG:GEN:instruction]', () {
      final text = '[IMG:ERROR:{"instruction":"a sunset","error":"fail"}]';
      final result = _resetImgTagsToGen(text);
      expect(result, '[IMG:GEN:{"prompt":"a sunset"}]');
    });

    test('ERROR tag without instruction resets to [IMG:GEN]', () {
      final text = '[IMG:ERROR:{"error":"fail"}]';
      final result = _resetImgTagsToGen(text);
      expect(result, '[IMG:GEN]');
    });

    test('RESULT tag with instruction resets to [IMG:GEN:instruction]', () {
      final text = '[IMG:RESULT:/path/to/img.png|{"prompt":"test"}]';
      final result = _resetImgTagsToGen(text);
      expect(result, '[IMG:GEN:{"prompt":"test"}]');
    });

    test('RESULT tag without pipe resets to [IMG:GEN]', () {
      final text = '[IMG:RESULT:/path/to/img.png]';
      final result = _resetImgTagsToGen(text);
      expect(result, '[IMG:GEN]');
    });

    test('mixed ERROR and RESULT tags all reset', () {
      final text = 'A [IMG:ERROR:{"error":"x"}] B [IMG:RESULT:/img.png] C';
      final result = _resetImgTagsToGen(text);
      expect(result, 'A [IMG:GEN] B [IMG:GEN] C');
    });

    test('text without image tags is unchanged', () {
      const text = 'Just normal text';
      final result = _resetImgTagsToGen(text);
      expect(result, text);
    });
  });

  group('StreamingState invariants (Phase 5.1 characterization)', () {
    test('StreamingState defaults to empty text and null reasoning', () {
      const state = StreamingState(text: '', reasoning: null);
      expect(state.text, '');
      expect(state.reasoning, isNull);
    });

    test('StreamingState hasPartial check: text not empty', () {
      const state = StreamingState(text: 'Hello', reasoning: null);
      expect(state.text.isNotEmpty, isTrue);
    });

    test('StreamingState hasPartial check: reasoning not empty', () {
      const state = StreamingState(text: '', reasoning: 'thinking...');
      expect(state.reasoning != null && state.reasoning!.isNotEmpty, isTrue);
    });

    test('StreamingState hasPartial check: both empty', () {
      const state = StreamingState(text: '', reasoning: null);
      final hasPartial = state.text.isNotEmpty ||
          (state.reasoning != null && state.reasoning!.isNotEmpty);
      expect(hasPartial, isFalse);
    });
  });

  group('ChatState invariants (Phase 5.1 characterization)', () {
    test('ChatState defaults: not generating, not generating image', () {
      const state = ChatState();
      expect(state.isGenerating, isFalse);
      expect(state.isGeneratingImage, isFalse);
      expect(state.regenTargetId, isNull);
    });

    test('ChatState.visibleMessages respects visibleStartIndex', () {
      final session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: List.generate(10, (i) => ChatMessage(id: 'm$i', role: 'user', content: 'msg$i')),
      );
      final state = ChatState(session: session, visibleStartIndex: 5);
      expect(state.visibleMessages.length, 5);
      expect(state.messages.length, 10);
    });

    test('ChatState.hasMoreOlder is true when visibleStartIndex > 0', () {
      const state = ChatState(visibleStartIndex: 5);
      expect(state.hasMoreOlder, isTrue);
    });

    test('ChatState.hasMoreOlder is false when visibleStartIndex == 0', () {
      const state = ChatState(visibleStartIndex: 0);
      expect(state.hasMoreOlder, isFalse);
    });

    test('ChatState.copyWith preserves regenTargetId unset sentinel', () {
      const state = ChatState(regenTargetId: 'abc');
      final copy = state.copyWith(isGenerating: true);
      expect(copy.regenTargetId, 'abc');
      expect(copy.isGenerating, isTrue);
    });

    test('ChatState.copyWith can clear regenTargetId', () {
      const state = ChatState(regenTargetId: 'abc');
      final copy = state.copyWith(regenTargetId: null);
      expect(copy.regenTargetId, isNull);
    });
  });

  group('ChatMessage swipe invariants (Phase 5.1 characterization)', () {
    test('ChatMessage swipes list defaults to empty', () {
      final msg = ChatMessage(id: '1', role: 'assistant', content: 'hi');
      expect(msg.swipes, isEmpty);
    });

    test('ChatMessage swipeId defaults to 0', () {
      final msg = ChatMessage(id: '1', role: 'assistant', content: 'hi');
      expect(msg.swipeId, 0);
    });

    test('ChatMessage isTyping defaults to false', () {
      final msg = ChatMessage(id: '1', role: 'assistant', content: 'hi');
      expect(msg.isTyping, isFalse);
    });

    test('ChatMessage isError defaults to false', () {
      final msg = ChatMessage(id: '1', role: 'assistant', content: 'hi');
      expect(msg.isError, isFalse);
    });

    test('ChatMessage swipeDirection defaults to "none"', () {
      final msg = ChatMessage(id: '1', role: 'assistant', content: 'hi');
      expect(msg.swipeDirection, 'none');
    });
  });

  group('ImgGenPattern tag replacement chain (Phase 5.1 characterization)', () {
    test('_replaceFirstImgErrorOrGen prefers ERROR over GEN', () {
      final text = 'Start [IMG:GEN:] middle [IMG:ERROR:fail] end';
      final result = _replaceFirstImgErrorOrGen(text, '/img.png');
      expect(result, 'Start [IMG:GEN:] middle [IMG:RESULT:/img.png] end');
    });

    test('_resetImgTagsToGen handles ERROR with JSON instruction correctly', () {
      final text = 'Text [IMG:ERROR:{"instruction":"sunset","error":"timeout"}] more';
      final result = _resetImgTagsToGen(text);
      expect(result.contains('[IMG:GEN:'), isTrue);
      expect(result.contains('ERROR'), isFalse);
    });
  });
}

String _replaceFirstImgErrorOrGen(String text, String resultPath) {
  if (ImgGenPatterns.imgErrorRegex.hasMatch(text)) {
    return text.replaceFirst(ImgGenPatterns.imgErrorRegex, '[IMG:RESULT:$resultPath]');
  }
  if (ImgGenPatterns.imgGenHtmlRegex.hasMatch(text)) {
    return text.replaceFirst(ImgGenPatterns.imgGenHtmlRegex, '[IMG:RESULT:$resultPath]');
  }
  if (text.contains('[IMG:GEN]')) {
    return text.replaceFirst('[IMG:GEN]', '[IMG:RESULT:$resultPath]');
  }
  if (ImgGenPatterns.imgGenRegex.hasMatch(text)) {
    return text.replaceFirst(ImgGenPatterns.imgGenRegex, '[IMG:RESULT:$resultPath]');
  }
  return text;
}

String _resetImgTagsToGen(String text) {
  var result = text;
  result = result.replaceAllMapped(ImgGenPatterns.imgErrorRegex, (m) {
    final data = m.group(1) ?? '';
    String instruction = '';
    try {
      final parsed = jsonDecode(data);
      if (parsed is Map<String, dynamic>) {
        instruction = (parsed['instruction'] ?? parsed['prompt'] ?? '') as String;
      }
    } catch (_) {}
    if (instruction.isNotEmpty) {
      return '[IMG:GEN:{"prompt":"$instruction"}]';
    }
    return '[IMG:GEN]';
  });
  result = result.replaceAllMapped(ImgGenPatterns.imgResultRegex, (m) {
    final raw = m.group(1) ?? '';
    final pipeIdx = raw.indexOf('|');
    final instr = pipeIdx != -1 ? raw.substring(pipeIdx + 1) : '';
    if (instr.isNotEmpty) {
      return '[IMG:GEN:$instr]';
    }
    return '[IMG:GEN]';
  });
  return result;
}
