import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/tokenizers/tokenizer_kind.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';

void main() {
  TokenizerKind auto(String model, {String protocol = LlmProtocol.openai}) =>
      resolveTokenizerKind(
        setting: kTokenizerAuto,
        model: model,
        protocol: protocol,
      );

  test('auto picks the family from the model name', () {
    const cases = {
      'claude-sonnet-4-5': TokenizerKind.claude,
      'anthropic/claude-3.5-sonnet': TokenizerKind.claude,
      'gpt-4o-mini': TokenizerKind.o200k,
      'gpt-4.1': TokenizerKind.o200k,
      'openai/gpt-5': TokenizerKind.o200k,
      'o3-mini': TokenizerKind.o200k,
      'openai/o1': TokenizerKind.o200k,
      'gpt-oss-120b': TokenizerKind.o200k,
      'gpt-4-turbo': TokenizerKind.cl100k,
      'gpt-3.5-turbo': TokenizerKind.cl100k,
      'google/gemini-2.5-pro': TokenizerKind.gemini,
      'gemma-3-27b-it': TokenizerKind.gemini,
      'deepseek-chat': TokenizerKind.deepseek,
      'deepseek/deepseek-r1': TokenizerKind.deepseek,
      'qwen/qwen3-235b-a22b': TokenizerKind.qwen,
      'meta-llama/llama-3.1-70b-instruct': TokenizerKind.llama3,
      'llama-4-maverick': TokenizerKind.llama3,
      'Llama-2-13b-chat': TokenizerKind.llama2,
      'mistral-large-latest': TokenizerKind.mistral,
      'mistralai/mistral-nemo': TokenizerKind.mistral,
      'mixtral-8x7b': TokenizerKind.mistral,
      'command-r-plus': TokenizerKind.commandR,
    };
    cases.forEach((model, kind) => expect(auto(model), kind, reason: model));
  });

  test('auto falls back to the protocol, then to o200k', () {
    expect(auto('', protocol: LlmProtocol.anthropic), TokenizerKind.claude);
    expect(
      auto('tunnel-7', protocol: LlmProtocol.gemini),
      TokenizerKind.gemini,
    );
    expect(auto('x-ai/grok-4'), TokenizerKind.o200k);
    expect(auto('moonshotai/kimi-k2'), TokenizerKind.o200k);
  });

  test('an explicit choice wins over the model name', () {
    expect(
      resolveTokenizerKind(
        setting: 'llama3',
        model: 'claude-3-opus',
        protocol: LlmProtocol.anthropic,
      ),
      TokenizerKind.llama3,
    );
    expect(
      resolveTokenizerKind(
        setting: 'approx',
        model: 'gpt-4o',
        protocol: LlmProtocol.openai,
      ),
      TokenizerKind.approx,
    );
    // An id this build does not know behaves like auto.
    expect(
      resolveTokenizerKind(
        setting: 'retired-kind',
        model: 'deepseek-chat',
        protocol: LlmProtocol.openai,
      ),
      TokenizerKind.deepseek,
    );
  });

  test('every downloadable kind has pinned sources', () {
    for (final kind in TokenizerKind.values) {
      final urls = tokenizerSourceUrls(kind);
      expect(urls.isEmpty, !kind.needsDownload, reason: kind.id);
      for (final url in urls) {
        expect(url, contains('@3.7.2/'), reason: url);
      }
      expect(TokenizerKind.fromId(kind.id), kind);
    }
  });
}
