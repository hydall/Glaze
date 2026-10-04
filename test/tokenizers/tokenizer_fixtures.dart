import 'package:glaze_flutter/core/llm/tokenizers/bpe_tokenizer.dart';

/// A GPT-style byte-level `tokenizer.json`: the 256-symbol byte alphabet plus
/// a handful of merges, split by the cl100k pattern (with its `(?i:…)` group).
Map<String, dynamic> byteLevelTokenizerJson() {
  final vocab = <String, int>{};
  for (var b = 0; b < 256; b++) {
    vocab[String.fromCharCode(byteLevelChar(b))] = b;
  }
  final merges = <String>[];
  void merge(String left, String right) {
    merges.add('$left $right');
    vocab.putIfAbsent('$left$right', () => vocab.length);
  }

  merge('h', 'e');
  merge('l', 'l');
  merge('he', 'll');
  merge('hell', 'o');
  merge('Ġ', 'w');
  merge("'", 'S');
  return {
    'normalizer': null,
    'pre_tokenizer': {
      'type': 'Sequence',
      'pretokenizers': [
        {
          'type': 'Split',
          'pattern': {
            'Regex':
                r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|"
                r"\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+",
          },
          'behavior': 'Isolated',
          'invert': false,
        },
        {'type': 'ByteLevel', 'add_prefix_space': false, 'use_regex': false},
      ],
    },
    'model': {'type': 'BPE', 'vocab': vocab, 'merges': merges},
  };
}

/// A SentencePiece-style character BPE (Gemma/Llama 2 shape): spaces become
/// `▁`, no pre-tokenizer, unknown characters fall back to `<0xXX>` bytes.
/// Merges come in the newer `[left, right]` list form.
Map<String, dynamic> charLevelTokenizerJson() {
  final vocab = <String, int>{'<unk>': 0};
  for (var b = 0; b < 256; b++) {
    final hex = b.toRadixString(16).toUpperCase().padLeft(2, '0');
    vocab['<0x$hex>'] = vocab.length;
  }
  for (final ch in const ['▁', 'a', 'b', 'c']) {
    vocab[ch] = vocab.length;
  }
  final merges = <List<String>>[];
  for (final (left, right) in charLevelMerges) {
    merges.add([left, right]);
    vocab.putIfAbsent('$left$right', () => vocab.length);
  }
  return {
    'normalizer': {
      'type': 'Replace',
      'pattern': {'String': ' '},
      'content': '▁',
    },
    'pre_tokenizer': null,
    'model': {
      'type': 'BPE',
      'vocab': vocab,
      'merges': merges,
      'byte_fallback': true,
      'unk_token': '<unk>',
    },
  };
}

/// Merge rules of [charLevelTokenizerJson], in rank order.
const charLevelMerges = <(String, String)>[
  ('▁', 'a'),
  ('a', 'b'),
  ('▁a', 'b'),
  ('b', 'c'),
  ('ab', 'c'),
  ('c', 'c'),
  ('▁ab', 'c'),
];
