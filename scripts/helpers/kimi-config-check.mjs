#!/usr/bin/env node
/**
 * Read non-secret Kimi readiness facts through Kimi Code's own runtime.
 *
 * The shell wrapper loads this file with Kimi's official
 * `__plugin_run_node` bridge. This works for both the native executable and
 * the npm launcher without requiring a separate Node or Python installation.
 */

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const MAX_CONFIG_OUTPUT = 8 * 1024 * 1024;
const configuredTimeout = Number.parseInt(process.env.OCTOPUS_KIMI_HEALTH_TIMEOUT_MS ?? '', 10);
const CONFIG_CHECK_TIMEOUT_MS = Number.isInteger(configuredTimeout)
  ? Math.min(Math.max(configuredTimeout, 250), 30_000)
  : 5_000;
const PROVIDER_ENV_KEYS = new Map([
  ['anthropic', ['ANTHROPIC_API_KEY']],
  ['openai', ['OPENAI_API_KEY']],
  ['openai_responses', ['OPENAI_API_KEY']],
  ['kimi', ['KIMI_API_KEY']],
  ['google-genai', ['GOOGLE_API_KEY']],
  ['vertexai', ['VERTEXAI_API_KEY', 'GOOGLE_API_KEY']],
]);

function nonBlank(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function plainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function runKimi(binary, args, configPath) {
  const result = spawnSync(binary, args, {
    encoding: 'utf8',
    env: { ...process.env, KIMI_CODE_HOME: dirname(configPath) },
    maxBuffer: MAX_CONFIG_OUTPUT,
    timeout: CONFIG_CHECK_TIMEOUT_MS,
    windowsHide: true,
  });
  if (result.error !== undefined || result.status !== 0) return undefined;
  return typeof result.stdout === 'string' ? result.stdout : '';
}

function skipTomlPadding(source, start) {
  let index = start;
  while (index < source.length) {
    const char = source[index];
    if (char === ' ' || char === '\t' || char === '\r' || char === '\n') {
      index += 1;
      continue;
    }
    if (char !== '#') break;
    const newline = source.indexOf('\n', index);
    index = newline === -1 ? source.length : newline + 1;
  }
  return index;
}

function tomlAssignmentEquals(source, start) {
  let quote;
  let escaped = false;
  for (let index = start; index < source.length; index += 1) {
    const char = source[index];
    if (quote === '"' && escaped) {
      escaped = false;
      continue;
    }
    if (quote === '"' && char === '\\') {
      escaped = true;
      continue;
    }
    if (quote !== undefined) {
      if (char === quote) quote = undefined;
      continue;
    }
    if (char === '"' || char === "'") quote = char;
    else if (char === '=') return index;
    else if (char === '\r' || char === '\n') return -1;
  }
  return -1;
}

function tomlValueEnd(source, start) {
  let quote;
  let escaped = false;
  let squareDepth = 0;
  let curlyDepth = 0;
  for (let index = start; index < source.length; index += 1) {
    const char = source[index];
    if ((quote === 'basic' || quote === 'multiline-basic') && escaped) {
      escaped = false;
      continue;
    }
    if ((quote === 'basic' || quote === 'multiline-basic') && char === '\\') {
      escaped = true;
      continue;
    }
    if (quote === 'basic' && char === '"') quote = undefined;
    else if (quote === 'literal' && char === "'") quote = undefined;
    else if (quote === 'multiline-basic' && char === '"') {
      let runLength = 1;
      while (source[index + runLength] === '"') runLength += 1;
      if (runLength >= 3) quote = undefined;
      index += runLength - 1;
    } else if (quote === 'multiline-literal' && char === "'") {
      let runLength = 1;
      while (source[index + runLength] === "'") runLength += 1;
      if (runLength >= 3) quote = undefined;
      index += runLength - 1;
    } else if (quote === undefined) {
      if (source.startsWith('"""', index)) {
        quote = 'multiline-basic';
        index += 2;
      } else if (source.startsWith("'''", index)) {
        quote = 'multiline-literal';
        index += 2;
      } else if (char === '"') quote = 'basic';
      else if (char === "'") quote = 'literal';
      else if (char === '[') squareDepth += 1;
      else if (char === ']') squareDepth -= 1;
      else if (char === '{') curlyDepth += 1;
      else if (char === '}') curlyDepth -= 1;
      else if (char === '#') {
        const newline = source.indexOf('\n', index);
        if (squareDepth === 0 && curlyDepth === 0) return newline === -1 ? source.length : newline;
        index = newline === -1 ? source.length : newline;
      } else if (char === '\n' && squareDepth === 0 && curlyDepth === 0) {
        return index;
      }
    }
  }
  return quote === undefined && squareDepth === 0 && curlyDepth === 0 ? source.length : -1;
}

function decodeTomlBasicString(body, multiline) {
  let source = body.replaceAll('\r\n', '\n');
  if (multiline && source.startsWith('\n')) source = source.slice(1);
  let result = '';
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (char !== '\\') {
      result += char;
      continue;
    }
    const escaped = source[index + 1];
    const replacements = {
      b: '\b',
      t: '\t',
      n: '\n',
      f: '\f',
      r: '\r',
      '"': '"',
      '\\': '\\',
    };
    if (Object.prototype.hasOwnProperty.call(replacements, escaped)) {
      result += replacements[escaped];
      index += 1;
      continue;
    }
    if (escaped === 'u' || escaped === 'U') {
      const width = escaped === 'u' ? 4 : 8;
      const digits = source.slice(index + 2, index + 2 + width);
      if (!new RegExp(`^[0-9A-Fa-f]{${width}}$`).test(digits)) return undefined;
      const codePoint = Number.parseInt(digits, 16);
      try {
        result += String.fromCodePoint(codePoint);
      } catch {
        return undefined;
      }
      index += width + 1;
      continue;
    }
    if (multiline && /[ \t\r\n]/u.test(escaped ?? '')) {
      let next = index + 1;
      let sawNewline = false;
      while (next < source.length && /[ \t\r\n]/u.test(source[next])) {
        if (source[next] === '\n') sawNewline = true;
        next += 1;
      }
      if (!sawNewline) return undefined;
      index = next - 1;
      continue;
    }
    return undefined;
  }
  return result;
}

function parseTomlString(source) {
  const value = source.trim();
  if (value.startsWith('"""') && value.endsWith('"""') && value.length >= 6) {
    return decodeTomlBasicString(value.slice(3, -3), true);
  }
  if (value.startsWith("'''") && value.endsWith("'''") && value.length >= 6) {
    const body = value.slice(3, -3).replaceAll('\r\n', '\n');
    return body.startsWith('\n') ? body.slice(1) : body;
  }
  if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
    return decodeTomlBasicString(value.slice(1, -1), false);
  }
  if (value.startsWith("'") && value.endsWith("'") && value.length >= 2) {
    return value.slice(1, -1);
  }
  return undefined;
}

function parseTomlKey(source) {
  const key = source.trim();
  if (/^[A-Za-z0-9_-]+$/u.test(key)) return key;
  return parseTomlString(key);
}

function readRoutingKeys(configPath) {
  let source;
  try {
    source = readFileSync(configPath, 'utf8');
  } catch {
    return { valid: false };
  }
  const result = { valid: true, defaultModel: undefined, defaultProvider: undefined };
  let index = 0;
  while ((index = skipTomlPadding(source, index)) < source.length) {
    if (source[index] === '[') return result;
    const equals = tomlAssignmentEquals(source, index);
    if (equals === -1) return { valid: false };
    const end = tomlValueEnd(source, equals + 1);
    if (end === -1) return { valid: false };
    const key = parseTomlKey(source.slice(index, equals));
    if (key === 'default_model' || key === 'default_provider') {
      const value = parseTomlString(source.slice(equals + 1, end));
      if (value === undefined) return { valid: false };
      if (key === 'default_model') result.defaultModel = value;
      else result.defaultProvider = value;
    }
    index = end + 1;
  }
  return result;
}

function inspectConfig(binary, configPath) {
  const absoluteConfigPath = resolve(configPath);
  const configExists = existsSync(absoluteConfigPath);
  if (
    configExists &&
    runKimi(binary, ['doctor', 'config', absoluteConfigPath], absoluteConfigPath) === undefined
  ) {
    return undefined;
  }
  if (!configExists && !nonBlank(process.env.KIMI_MODEL_NAME)) return undefined;
  const routing = configExists
    ? readRoutingKeys(absoluteConfigPath)
    : { valid: true, defaultModel: undefined, defaultProvider: undefined };
  if (!routing.valid) return undefined;

  const raw = runKimi(binary, ['provider', 'list', '--json'], absoluteConfigPath);
  if (raw === undefined) return undefined;

  let listed;
  try {
    listed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!plainObject(listed) || !plainObject(listed.providers) || !plainObject(listed.models)) {
    return undefined;
  }
  const dispatchedModel = process.env.OCTOPUS_KIMI_MODEL;
  const configuredDefaultModel = nonBlank(process.env.KIMI_MODEL_NAME)
    ? '__kimi_env_model__'
    : nonBlank(routing.defaultModel)
      ? routing.defaultModel
      : undefined;
  const config = {
    defaultModel: configuredDefaultModel,
    credentialModel:
      nonBlank(dispatchedModel) && dispatchedModel !== 'default'
        ? dispatchedModel
        : configuredDefaultModel,
    defaultProvider: nonBlank(routing.defaultProvider) ? routing.defaultProvider : undefined,
    providers: listed.providers,
    models: listed.models,
  };
  return configSemanticsAreValid(config) ? config : undefined;
}

function providerHasApiKey(provider) {
  if (nonBlank(provider.apiKey)) return true;
  if (!plainObject(provider.env)) return false;
  const envKeys = PROVIDER_ENV_KEYS.get(provider.type);
  return envKeys !== undefined && envKeys.some((key) => nonBlank(provider.env[key]));
}

function vertexLocationIsConfigured(provider) {
  if (!plainObject(provider.env)) return false;
  if (nonBlank(provider.env.GOOGLE_CLOUD_LOCATION)) return true;
  const baseUrl = nonBlank(provider.baseUrl)
    ? provider.baseUrl
    : provider.env.GOOGLE_VERTEX_BASE_URL;
  if (!nonBlank(baseUrl)) return false;
  try {
    const hostname = new URL(baseUrl).hostname;
    const suffix = '-aiplatform.googleapis.com';
    return hostname.endsWith(suffix) && hostname.length > suffix.length;
  } catch {
    return false;
  }
}

function configSemanticsAreValid(config) {
  for (const provider of Object.values(config.providers)) {
    if (!plainObject(provider)) return false;
    if (provider.oauth !== undefined && providerHasApiKey(provider)) return false;
  }
  for (const model of Object.values(config.models)) {
    if (!plainObject(model)) return false;
    if (model.oauth !== undefined && nonBlank(model.apiKey)) return false;
    const providerName = modelProviderName(model, config.defaultProvider);
    if (
      providerName !== undefined &&
      (!nonBlank(providerName) ||
        !Object.prototype.hasOwnProperty.call(config.providers, providerName))
    ) {
      return false;
    }
  }
  if (
    nonBlank(config.defaultModel) &&
    resolveModelConfiguration(config, config.defaultModel) === undefined
  ) {
    return false;
  }
  return true;
}

function modelProviderName(model, defaultProvider) {
  if (model.providerId !== undefined) return model.providerId;
  if (model.provider !== undefined) return model.provider;
  return defaultProvider;
}

function resolveModelConfiguration(config, alias) {
  if (!nonBlank(alias)) return undefined;
  const model = config.models[alias];
  if (!plainObject(model)) return undefined;

  const providerName = modelProviderName(model, config.defaultProvider);
  const modelName = model.name !== undefined ? model.name : model.model;
  if (!nonBlank(modelName)) return undefined;
  if (!Number.isInteger(model.maxContextSize) || model.maxContextSize < 1) return undefined;

  const provider = nonBlank(providerName) ? config.providers[providerName] : undefined;
  if (provider === undefined) {
    if (!nonBlank(model.baseUrl) || !nonBlank(model.protocol)) return undefined;
  } else if (!plainObject(provider)) {
    return undefined;
  }
  return { model, provider };
}

function oauthRecord(oauth) {
  if (!plainObject(oauth)) return undefined;
  if (oauth.storage !== 'file' && oauth.storage !== 'keyring') return undefined;
  const name = storageName(oauth.key);
  return name === undefined ? undefined : `oauth-${oauth.storage}:${name}`;
}

function storageName(oauthKey) {
  if (!nonBlank(oauthKey)) return undefined;
  if (oauthKey === 'kimi-code' || oauthKey === 'oauth/kimi-code') return 'kimi-code';
  if (oauthKey.startsWith('oauth/')) {
    const name = oauthKey.slice('oauth/'.length);
    return name.length > 0 && !name.includes('/') && !name.startsWith('.') ? name : undefined;
  }
  return !oauthKey.includes('/') && !oauthKey.startsWith('.') ? oauthKey : undefined;
}

function credentialRecord(config) {
  const resolved = resolveModelConfiguration(config, config.credentialModel);
  if (resolved === undefined) return undefined;
  const { model, provider } = resolved;

  if (nonBlank(model.apiKey)) return 'config:api-key';
  if (model.oauth !== undefined) return oauthRecord(model.oauth);

  if (provider === undefined) return 'none';
  if (!nonBlank(model.protocol) && !PROVIDER_ENV_KEYS.has(provider.type)) return undefined;

  const hasApiKey = providerHasApiKey(provider);
  if (hasApiKey) return 'config:api-key';

  if (provider.oauth === undefined) {
    if (
      provider.type === 'vertexai' &&
      plainObject(provider.env) &&
      nonBlank(provider.env.GOOGLE_CLOUD_PROJECT) &&
      vertexLocationIsConfigured(provider)
    ) {
      return 'vertex-adc-unsupported';
    }
    return 'none';
  }
  return oauthRecord(provider.oauth);
}

function oauthFileIsUsable(path) {
  let token;
  try {
    token = JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return false;
  }
  if (!plainObject(token)) return false;
  if (!nonBlank(token.access_token) || !nonBlank(token.refresh_token) || !nonBlank(token.token_type)) {
    return false;
  }
  if (typeof token.scope !== 'string') return false;
  if (typeof token.expires_at !== 'number' || !Number.isFinite(token.expires_at) || token.expires_at <= 0) {
    return false;
  }
  if (
    typeof token.expires_in !== 'number' ||
    !Number.isFinite(token.expires_in) ||
    token.expires_in < 0
  ) {
    return false;
  }
  return true;
}

function main(argv) {
  const [operation, source, binary] = argv;
  if (operation === 'self-test') return 0;
  if (!nonBlank(source) || !nonBlank(binary)) return 1;

  if (operation === 'oauth-file-valid') {
    return oauthFileIsUsable(source) ? 0 : 1;
  }

  const config = inspectConfig(binary, source);
  if (config === undefined) return 1;
  if (operation === 'has-model') {
    return resolveModelConfiguration(config, config.credentialModel) === undefined ? 1 : 0;
  }
  if (operation !== 'config-record') return 1;
  if (!nonBlank(config.credentialModel)) {
    process.stdout.write('model-missing\n');
    return 0;
  }

  const record = credentialRecord(config);
  if (record === undefined) return 1;
  process.stdout.write(`${record}\n`);
  return 0;
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch {
  // Fail closed and stay silent: diagnostics could contain credential values.
  process.exitCode = 1;
}
