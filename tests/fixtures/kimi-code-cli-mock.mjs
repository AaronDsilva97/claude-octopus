#!/usr/bin/env node
/** Offline Kimi Code config-command fixture used by shell unit tests. */

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const CAMEL_KEYS = new Map([
  ['api_key', 'apiKey'],
  ['base_url', 'baseUrl'],
  ['custom_headers', 'customHeaders'],
  ['default_model', 'defaultModel'],
  ['display_name', 'displayName'],
  ['max_context_size', 'maxContextSize'],
  ['max_input_size', 'maxInputSize'],
  ['max_output_size', 'maxOutputSize'],
  ['oauth_host', 'oauthHost'],
  ['provider_id', 'providerId'],
  ['reasoning_key', 'reasoningKey'],
]);

function plainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function stringMap(value) {
  return plainObject(value) && Object.entries(value).every(
    ([key, item]) => typeof key === 'string' && typeof item === 'string',
  );
}

function nonBlank(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function withoutComment(line) {
  let quote;
  let escaped = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
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
    else if (char === '#') return line.slice(0, i);
  }
  if (quote !== undefined) throw new Error('unterminated string');
  return line;
}

function splitOutside(source, delimiter) {
  const parts = [];
  let start = 0;
  let quote;
  let escaped = false;
  let brackets = 0;
  for (let i = 0; i < source.length; i += 1) {
    const char = source[i];
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
    if (char === '"' || char === "'") {
      quote = char;
    } else if (char === '[') {
      brackets += 1;
    } else if (char === ']') {
      brackets -= 1;
      if (brackets < 0) throw new Error('unbalanced array');
    } else if (char === delimiter && brackets === 0) {
      parts.push(source.slice(start, i));
      start = i + 1;
    }
  }
  if (quote !== undefined || brackets !== 0) throw new Error('unterminated value');
  parts.push(source.slice(start));
  return parts;
}

function parseKeyPath(source) {
  const parts = splitOutside(source, '.').map((part) => part.trim());
  if (parts.length === 0 || parts.some((part) => part.length === 0)) {
    throw new Error('invalid key');
  }
  return parts.map((part) => {
    if (part.startsWith('"')) {
      const value = JSON.parse(part);
      if (typeof value !== 'string') throw new Error('invalid quoted key');
      return value;
    }
    if (part.startsWith("'") && part.endsWith("'") && part.length >= 2) {
      return part.slice(1, -1);
    }
    if (!/^[A-Za-z0-9_-]+$/.test(part)) throw new Error('invalid bare key');
    return part;
  });
}

function parseValue(source) {
  const value = source.trim();
  if (value.length === 0) throw new Error('missing value');
  if (value.startsWith('"')) {
    const parsed = JSON.parse(value);
    if (typeof parsed !== 'string') throw new Error('invalid string');
    return parsed;
  }
  if (value.startsWith("'") && value.endsWith("'") && value.length >= 2) {
    return value.slice(1, -1);
  }
  if (value === 'true') return true;
  if (value === 'false') return false;
  if (/^[+-]?\d(?:_?\d)*$/.test(value)) return Number(value.replaceAll('_', ''));
  if (value.startsWith('[') && value.endsWith(']')) {
    const body = value.slice(1, -1).trim();
    if (body.length === 0) return [];
    return splitOutside(body, ',').map((part) => parseValue(part));
  }
  throw new Error('unsupported or malformed value');
}

function tableAt(root, path, arrayTable, declared) {
  const identity = JSON.stringify(path);
  if (declared.has(identity) && !arrayTable) throw new Error('duplicate table');
  let target = root;
  for (let i = 0; i < path.length; i += 1) {
    const key = path[i];
    const last = i === path.length - 1;
    if (last && arrayTable) {
      if (target[key] === undefined) target[key] = [];
      if (!Array.isArray(target[key])) throw new Error('table type conflict');
      const item = {};
      target[key].push(item);
      declared.add(identity);
      return item;
    }
    if (target[key] === undefined) target[key] = {};
    if (!plainObject(target[key])) throw new Error('table type conflict');
    target = target[key];
  }
  declared.add(identity);
  return target;
}

function assign(target, path, value) {
  let cursor = target;
  for (let i = 0; i < path.length - 1; i += 1) {
    const key = path[i];
    if (cursor[key] === undefined) cursor[key] = {};
    if (!plainObject(cursor[key])) throw new Error('key type conflict');
    cursor = cursor[key];
  }
  const key = path[path.length - 1];
  if (Object.prototype.hasOwnProperty.call(cursor, key)) throw new Error('duplicate key');
  cursor[key] = value;
}

function parseToml(source) {
  const root = {};
  const declared = new Set();
  let table = root;
  for (const rawLine of source.split(/\r?\n/u)) {
    const line = withoutComment(rawLine).trim();
    if (line.length === 0) continue;
    const arrayTable = line.startsWith('[[') && line.endsWith(']]');
    const normalTable = line.startsWith('[') && line.endsWith(']') && !arrayTable;
    if (arrayTable || normalTable) {
      const inner = line.slice(arrayTable ? 2 : 1, arrayTable ? -2 : -1).trim();
      table = tableAt(root, parseKeyPath(inner), arrayTable, declared);
      continue;
    }
    const assignment = splitOutside(line, '=');
    if (assignment.length !== 2) throw new Error('invalid assignment');
    assign(table, parseKeyPath(assignment[0].trim()), parseValue(assignment[1]));
  }
  return root;
}

function validConfig(config) {
  if (!plainObject(config)) return false;
  if (config.default_model !== undefined && typeof config.default_model !== 'string') return false;
  const providers = config.providers ?? {};
  const models = config.models ?? {};
  if (!plainObject(providers) || !plainObject(models)) return false;
  for (const provider of Object.values(providers)) {
    if (!plainObject(provider)) return false;
    for (const key of ['type', 'api_key', 'base_url', 'default_model']) {
      if (provider[key] !== undefined && typeof provider[key] !== 'string') return false;
    }
    for (const key of ['env', 'custom_headers']) {
      if (provider[key] !== undefined && !stringMap(provider[key])) return false;
    }
    if (provider.oauth !== undefined) {
      if (!plainObject(provider.oauth)) return false;
      if (!['file', 'keyring'].includes(provider.oauth.storage)) return false;
      if (!nonBlank(provider.oauth.key)) return false;
    }
  }
  for (const model of Object.values(models)) {
    if (!plainObject(model)) return false;
    for (const key of ['provider', 'provider_id', 'model', 'name', 'protocol']) {
      if (model[key] !== undefined && typeof model[key] !== 'string') return false;
    }
    if (
      model.max_context_size !== undefined &&
      (!Number.isInteger(model.max_context_size) || model.max_context_size < 1)
    ) {
      return false;
    }
    if (
      model.capabilities !== undefined &&
      (!Array.isArray(model.capabilities) || model.capabilities.some((item) => typeof item !== 'string'))
    ) {
      return false;
    }
  }
  return true;
}

function applyEnvModel(config) {
  const name = process.env.KIMI_MODEL_NAME?.trim();
  if (!name) return config;
  const apiKey = process.env.KIMI_MODEL_API_KEY?.trim();
  if (!apiKey) throw new Error('missing env model API key');
  const providerType = process.env.KIMI_MODEL_PROVIDER_TYPE?.trim().toLowerCase() || 'kimi';
  if (!['kimi', 'anthropic', 'openai'].includes(providerType)) {
    throw new Error('invalid env model provider type');
  }
  const rawContext = process.env.KIMI_MODEL_MAX_CONTEXT_SIZE?.trim();
  const maxContextSize = rawContext ? Number(rawContext) : 262144;
  if (!Number.isInteger(maxContextSize) || maxContextSize < 1) {
    throw new Error('invalid env model context');
  }
  const providers = { ...(config.providers ?? {}) };
  const models = { ...(config.models ?? {}) };
  providers.__kimi_env__ = {
    type: providerType,
    api_key: apiKey,
    ...(process.env.KIMI_MODEL_BASE_URL?.trim()
      ? { base_url: process.env.KIMI_MODEL_BASE_URL.trim() }
      : {}),
  };
  models.__kimi_env_model__ = {
    provider: '__kimi_env__',
    model: name,
    max_context_size: maxContextSize,
    capabilities: (process.env.KIMI_MODEL_CAPABILITIES ?? 'image_in,thinking')
      .split(',')
      .map((item) => item.trim())
      .filter(Boolean),
  };
  return { ...config, providers, models, default_model: '__kimi_env_model__' };
}

function camelize(value) {
  if (Array.isArray(value)) return value.map(camelize);
  if (!plainObject(value)) return value;
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [CAMEL_KEYS.get(key) ?? key, camelize(item)]),
  );
}

function load(path, allowMissing = false) {
  if (!existsSync(path) && !allowMissing) throw new Error('missing config');
  const parsed = parseToml(existsSync(path) ? readFileSync(path, 'utf8') : '');
  if (!validConfig(parsed)) throw new Error('invalid config');
  return applyEnvModel(parsed);
}

function main(argv) {
  if (argv[0] === 'doctor' && argv[1] === 'config' && argv.length === 3) {
    load(argv[2]);
    return 0;
  }
  if (argv[0] === 'provider' && argv[1] === 'list' && [2, 3].includes(argv.length)) {
    const config = load(join(process.env.KIMI_CODE_HOME, 'config.toml'), true);
    const providers = config.providers ?? {};
    const models = config.models ?? {};
    if (argv[2] === '--json') {
      process.stdout.write(`${JSON.stringify({ providers: camelize(providers), models: camelize(models) })}\n`);
    } else {
      if (Object.keys(providers).length === 0) {
        process.stdout.write('No providers configured.\n');
        return 0;
      }
      for (const [providerId, provider] of Object.entries(providers)) {
        const count = Object.values(models).filter((model) => model.provider === providerId).length;
        process.stdout.write(`${providerId}  type=${provider.type ?? ''}  models=${count}  source=inline\n`);
      }
      if (typeof config.default_model === 'string') {
        process.stdout.write(`\nDefault model: ${config.default_model}\n`);
      }
    }
    return 0;
  }
  return 1;
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch {
  process.exitCode = 1;
}
