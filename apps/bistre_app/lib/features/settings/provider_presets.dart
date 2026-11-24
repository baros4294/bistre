/// Starter provider presets (strictly the Big 3 + Custom).
/// Models are never hardcoded; users pick or fetch models dynamically from each provider's live
/// `/models` endpoint, and any third-party or local server connects through `Custom`.
library;

/// Starter provider preset (name, API format, server URL, optional initial model, icon).
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.dialect,
    required this.baseUrl,
    this.defaultModel = '',
    required this.iconSlug,
  });

  final String name;
  final String dialect;
  final String baseUrl;
  final String defaultModel;
  final String iconSlug;
}

const String kExampleBaseUrl = 'https://api.openai.com/v1';
const String kExampleHeadersJson = '{"X-Title": "Bistre"}';
const String kExampleBodyJson = '{"seed": 42}';

const List<ProviderPreset> kProviderPresets = <ProviderPreset>[
  ProviderPreset(
    name: 'OpenAI',
    dialect: 'openai',
    baseUrl: 'https://api.openai.com/v1',
    iconSlug: 'openai',
  ),
  ProviderPreset(
    name: 'Google Gemini',
    dialect: 'gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    iconSlug: 'gemini',
  ),
  ProviderPreset(
    name: 'Anthropic',
    dialect: 'anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    iconSlug: 'claude',
  ),
  ProviderPreset(
    name: 'Custom',
    dialect: 'custom_openai',
    baseUrl: '',
    iconSlug: 'server',
  ),
];
