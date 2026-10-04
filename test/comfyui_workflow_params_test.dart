import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/comfyui_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/comfyui_workflow_params.dart';

const _qwenGraph = r'''
{
  "1": {
    "class_type": "UNETLoader",
    "inputs": {"unet_name": "qwen_image.safetensors", "weight_dtype": "default"}
  },
  "3": {
    "class_type": "VAELoader",
    "inputs": {"vae_name": "qwen_vae.safetensors"}
  },
  "5": {
    "class_type": "TextEncodeQwenImage21",
    "inputs": {
      "prompt": "a neon shop sign",
      "negative_prompt": "",
      "resolution": 1024
    }
  },
  "6": {
    "class_type": "EmptyLatentImage",
    "inputs": {"width": 1024, "height": 1024, "batch_size": 1}
  },
  "7": {
    "class_type": "KSampler",
    "inputs": {
      "seed": 42,
      "steps": 25,
      "cfg": 1,
      "sampler_name": "euler",
      "scheduler": "simple",
      "denoise": 1,
      "positive": ["5", 0],
      "negative": ["5", 1],
      "latent_image": ["6", 0]
    }
  }
}
''';

void main() {
  group('ComfyUiWorkflowParams.read', () {
    test('extracts the sampler, size and loaders from a graph', () {
      final params = ComfyUiWorkflowParams.read(_qwenGraph);

      expect(params.sampler, 'euler');
      expect(params.scheduler, 'simple');
      expect(params.steps, 25);
      expect(params.cfgScale, 1.0);
      expect(params.seed, 42);
      expect(params.denoise, 1.0);
      expect(params.width, 1024);
      expect(params.height, 1024);
      expect(params.model, 'qwen_image.safetensors');
      expect(params.vae, 'qwen_vae.safetensors');
      expect(params.clipSkip, isNull);
    });

    test('ignores %token% placeholders', () {
      final params = ComfyUiWorkflowParams.read(
        ComfyUiConstants.defaultWorkflow,
      );

      expect(params.sampler, isNull);
      expect(params.scheduler, isNull);
      expect(params.steps, isNull);
      expect(params.cfgScale, isNull);
      expect(params.seed, isNull);
      expect(params.width, isNull);
      expect(params.height, isNull);
      expect(params.model, isNull);
    });

    test('returns empty params for invalid JSON', () {
      expect(
        ComfyUiWorkflowParams.read('not json'),
        ComfyUiWorkflowParams.empty,
      );
    });
  });

  group('ComfyUiWorkflowParams.applyTo', () {
    test('overwrites the fields found in the graph', () {
      final next = ComfyUiWorkflowParams.read(
        _qwenGraph,
      ).applyTo(const ComfyUiImageSettings());

      expect(next.sampler, 'euler');
      expect(next.scheduler, 'simple');
      expect(next.steps, 25);
      expect(next.cfgScale, 1.0);
      expect(next.seed, 42);
      expect(next.width, 1024);
      expect(next.height, 1024);
      expect(next.model, 'qwen_image.safetensors');
      expect(next.vae, 'qwen_vae.safetensors');
      // 1024x1024 is a shipped preset, so the custom-size flag stays off.
      expect(next.customSize, isFalse);
    });

    test('flags a non-preset size as custom', () {
      const graph = r'''
{
  "6": {
    "class_type": "EmptyLatentImage",
    "inputs": {"width": 900, "height": 1100, "batch_size": 1}
  }
}
''';
      final next = ComfyUiWorkflowParams.read(
        graph,
      ).applyTo(const ComfyUiImageSettings());

      expect(next.width, 900);
      expect(next.height, 1100);
      expect(next.customSize, isTrue);
    });
  });

  group('ComfyUiImageProvider writes settings into a token-less graph', () {
    test('applies the UI fields to the sampler and latent nodes', () {
      final settings = ComfyUiImageSettings(
        workflows: const [
          ComfyUiWorkflow(id: 'w', name: 'w', json: _qwenGraph),
        ],
        activeWorkflowId: 'w',
        sampler: 'ddim',
        scheduler: 'karras',
        steps: 30,
        cfgScale: 4.5,
        seed: 7,
        denoise: 0.8,
        width: 832,
        height: 1216,
        negativePrompt: 'lowres',
      );

      final workflow = ComfyUiImageProvider.buildWorkflow(
        settings,
        prompt: 'a cat',
      );

      final sampler = (workflow['7'] as Map)['inputs'] as Map;
      expect(sampler['sampler_name'], 'ddim');
      expect(sampler['scheduler'], 'karras');
      expect(sampler['steps'], 30);
      expect(sampler['cfg'], 4.5);
      expect(sampler['seed'], 7);
      expect(sampler['denoise'], 0.8);

      final latent = (workflow['6'] as Map)['inputs'] as Map;
      expect(latent['width'], 832);
      expect(latent['height'], 1216);

      final text = (workflow['5'] as Map)['inputs'] as Map;
      expect(text['prompt'], 'a cat');
      expect(text['negative_prompt'], 'lowres');
    });

    test('leaves the model loader alone when the field is empty', () {
      final settings = ComfyUiImageSettings(
        workflows: const [
          ComfyUiWorkflow(id: 'w', name: 'w', json: _qwenGraph),
        ],
        activeWorkflowId: 'w',
      );

      final workflow = ComfyUiImageProvider.buildWorkflow(
        settings,
        prompt: 'a cat',
      );

      expect(
        ((workflow['1'] as Map)['inputs'] as Map)['unet_name'],
        'qwen_image.safetensors',
      );
    });
  });
}
