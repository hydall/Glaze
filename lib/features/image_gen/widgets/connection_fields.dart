import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';
import 'rows.dart' as rows;

/// Connection-field rows for the Naistera image-gen API.
///
/// The "Learn about Naistera" link is shown as an inert InkWell because
/// the original implementation did not actually wire a URL — preserved
/// here to avoid behavior change.
List<Widget> buildNaisteraConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_api_key'.tr(),
      value: s.naisteraApiKey,
      obscure: true,
      hint: 'sk-...',
      onChanged: (v) => onUpdate(s.copyWith(naisteraApiKey: v)),
    ),
    InkWell(
      onTap: () {},
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Text(
              'imggen_naistera_hint'.tr(),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.public, size: 14, color: Colors.blue),
            const SizedBox(width: 4),
            Text(
              'imggen_naistera_hint_here'.tr(),
              style: TextStyle(fontSize: 13, color: Colors.blue),
            ),
          ],
        ),
      ),
    ),
  ];
}

/// Connection-field rows for the rout.my image-gen API. Under the API key sits
/// the mirror picker: the global host is the default, the RU mirror is an
/// option. Both serve the same catalog and accept the same keys.
List<Widget> buildRoutmyConnectionFields(
  ImageGenSettings s,
  BuildContext context,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'rout.my API Key',
      value: s.routmyApiKey,
      obscure: true,
      hint: 'sk-...',
      onChanged: (v) => onUpdate(s.copyWith(routmyApiKey: v)),
    ),
    MenuSelectorItem(
      label: 'imggen_mirror'.tr(),
      currentValue: s.routmyMirror.label,
      onTap: () => rows.showImageGenOptions<RoutMyMirror>(
        context,
        title: 'imggen_mirror'.tr(),
        items: RoutMyMirror.values,
        labelBuilder: (mirror) => mirror.label,
        isSelected: (mirror) => s.routmyMirror == mirror,
        onSelected: (mirror) => onUpdate(s.copyWith(routmyMirror: mirror)),
      ),
    ),
  ];
}

/// Connection-field rows for OpenRouter. The endpoint is optional — empty
/// falls back to `https://openrouter.ai/api/v1`, so OpenRouter-compatible
/// proxies can be pointed at without any other change.
List<Widget> buildOpenRouterConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_api_key'.tr(),
      value: s.openrouter.apiKey,
      obscure: true,
      hint: 'sk-or-...',
      onChanged: (v) =>
          onUpdate(s.copyWith(openrouter: s.openrouter.copyWith(apiKey: v))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'imggen_endpoint'.tr(),
      value: s.openrouter.endpoint,
      hint: OpenRouterConstants.defaultEndpoint,
      onChanged: (v) =>
          onUpdate(s.copyWith(openrouter: s.openrouter.copyWith(endpoint: v))),
    ),
  ];
}

/// Connection-field rows for Electron Hub (OpenAI-compatible aggregator).
List<Widget> buildElectronHubConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_api_key'.tr(),
      value: s.electronhub.apiKey,
      obscure: true,
      hint: 'ek-...',
      onChanged: (v) =>
          onUpdate(s.copyWith(electronhub: s.electronhub.copyWith(apiKey: v))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'imggen_endpoint'.tr(),
      value: s.electronhub.endpoint,
      hint: ElectronHubConstants.defaultEndpoint,
      onChanged: (v) => onUpdate(
        s.copyWith(electronhub: s.electronhub.copyWith(endpoint: v)),
      ),
    ),
  ];
}

/// Connection-field rows for a local AUTOMATIC1111 / Forge server. The API key
/// is only needed when the server runs with `--api-auth user:password`.
List<Widget> buildA1111ConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    rows.ImageGenTextFieldItem(
      label: 'imggen_endpoint'.tr(),
      value: s.a1111.endpoint,
      hint: A1111Constants.defaultEndpoint,
      onChanged: (v) =>
          onUpdate(s.copyWith(a1111: s.a1111.copyWith(endpoint: v))),
    ),
    rows.ImageGenTextFieldItem(
      label: 'imggen_a1111_auth'.tr(),
      value: s.a1111.apiKey,
      obscure: true,
      hint: 'user:password',
      onChanged: (v) =>
          onUpdate(s.copyWith(a1111: s.a1111.copyWith(apiKey: v))),
    ),
  ];
}

/// Connection-field rows for the OpenAI-compatible path. If [useSame]
/// is true only the "Use LLM API" switch is shown — no endpoint or
/// key fields. Otherwise both endpoint URL and API key are visible.
List<Widget> buildOpenaiConnectionFields(
  ImageGenSettings s,
  ValueChanged<ImageGenSettings> onUpdate,
) {
  return [
    MenuSwitchItem(
      label: 'settings_use_llm_api'.tr(),
      description: 'settings_use_llm_api_desc'.tr(),
      value: s.useSameEndpoint,
      onChanged: (v) => onUpdate(s.copyWith(useSameEndpoint: v)),
    ),
    if (!s.useSameEndpoint) ...[
      rows.ImageGenTextFieldItem(
        label: 'imggen_endpoint'.tr(),
        value: s.customEndpoint,
        hint: 'https://api.openai.com/v1',
        onChanged: (v) => onUpdate(s.copyWith(customEndpoint: v)),
      ),
      rows.ImageGenTextFieldItem(
        label: 'imggen_api_key'.tr(),
        value: s.customApiKey,
        obscure: true,
        hint: 'sk-...',
        onChanged: (v) => onUpdate(s.copyWith(customApiKey: v)),
      ),
    ],
  ];
}
