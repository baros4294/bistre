/// Starter provider presets (strictly the Big 3 + Custom).
/// Models are never hardcoded; users pick or fetch models dynamically from each provider's live
/// `/models` endpoint, and any third-party or local server connects through `Custom`.
library;

/// Starter provider preset (name, API format id, optional initial model, icon). The server
/// URL and endpoint come from core's dialect descriptor, never from a copy here.
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.dialect,
    this.defaultModel = '',
    required this.iconSlug,
  });

  final String name;
  final String dialect;
  final String defaultModel;
  final String iconSlug;
}

const List<ProviderPreset> kProviderPresets = <ProviderPreset>[
  ProviderPreset(name: 'OpenAI', dialect: 'openai', iconSlug: 'openai'),
  ProviderPreset(
    name: 'Google Gemini',
    dialect: 'google_gemini',
    iconSlug: 'gemini',
  ),
  ProviderPreset(name: 'Anthropic', dialect: 'anthropic', iconSlug: 'claude'),
  ProviderPreset(name: 'Custom', dialect: 'custom_openai', iconSlug: 'server'),
];
