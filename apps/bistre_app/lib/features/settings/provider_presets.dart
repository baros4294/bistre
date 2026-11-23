/// Provider registry presets: the ONE runtime location allowed to name concrete model IDs
/// (`just guard` exempts only this file). Suggested models are editable starting points; the
/// live `/models` fetch is authoritative.
library;

/// Starter provider preset (name, API format, server URL, suggested model, icon).
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.dialect,
    required this.baseUrl,
    required this.defaultModel,
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
    defaultModel: 'gpt-4o-mini',
    iconSlug: 'openai',
  ),
  ProviderPreset(
    name: 'Google Gemini',
    dialect: 'gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-2.5-flash',
    iconSlug: 'gemini',
  ),
  ProviderPreset(
    name: 'Anthropic',
    dialect: 'anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-sonnet-4-5',
    iconSlug: 'claude',
  ),
  ProviderPreset(
    name: 'Ollama (Local)',
    dialect: 'custom_openai',
    baseUrl: 'http://127.0.0.1:11434/v1',
    defaultModel: 'llama3.2',
    iconSlug: 'ollama',
  ),
  ProviderPreset(
    name: 'OpenRouter',
    dialect: 'custom_openai',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4o-mini',
    iconSlug: 'openrouter',
  ),
  ProviderPreset(
    name: 'DeepSeek',
    dialect: 'custom_openai',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    iconSlug: 'deepseek',
  ),
  ProviderPreset(
    name: 'Groq',
    dialect: 'custom_openai',
    baseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'llama-3.3-70b-versatile',
    iconSlug: 'groq',
  ),
  ProviderPreset(
    name: 'Mistral',
    dialect: 'custom_openai',
    baseUrl: 'https://api.mistral.ai/v1',
    defaultModel: 'mistral-large-latest',
    iconSlug: 'mistral',
  ),
];
