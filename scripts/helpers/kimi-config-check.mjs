#!/usr/bin/env node
/**
 * Read non-secret Kimi readiness facts through Kimi Code's own runtime.
 *
 * The shell wrapper loads this file with Kimi's official
 * `__plugin_run_node` bridge. This works for both the native executable and
 * the npm launcher without requiring a separate Node or Python installation.
 */

import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname } from 'node:path';

const MAX_CONFIG_OUTPUT = 8 * 1024 * 1024;
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
    windowsHide: true,
  });
  if (result.error !== undefined || result.status !== 0) return undefined;
  return typeof result.stdout === 'string' ? result.stdout : '';
}

function inspectConfig(binary, configPath) {
  if (runKimi(binary, ['doctor', 'config', configPath], configPath) === undefined) {
    return undefined;
  }

  const summary = runKimi(binary, ['provider', 'list'], configPath);
  const raw = runKimi(binary, ['provider', 'list', '--json'], configPath);
  if (summary === undefined || raw === undefined) return undefined;

  const match = summary.match(/^Default model: ([^\r\n]+)\r?$/m);
  if (match === null || !nonBlank(match[1])) {
    return { defaultModel: undefined, providers: {}, models: {} };
  }

  let listed;
  try {
    listed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!plainObject(listed) || !plainObject(listed.providers) || !plainObject(listed.models)) {
    return undefined;
  }
  return {
    defaultModel: match[1],
    providers: listed.providers,
    models: listed.models,
  };
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
  if (!nonBlank(config.defaultModel)) return undefined;
  const model = config.models[config.defaultModel];
  if (!plainObject(model)) return undefined;
  if (!nonBlank(model.provider) || !nonBlank(model.model)) return undefined;
  if (!Number.isInteger(model.maxContextSize) || model.maxContextSize < 1) return undefined;

  const provider = config.providers[model.provider];
  if (!plainObject(provider) || !nonBlank(provider.type)) return undefined;
  const envKeys = PROVIDER_ENV_KEYS.get(provider.type);
  if (envKeys === undefined) return undefined;

  if (nonBlank(provider.apiKey)) return 'config:api-key';
  if (
    plainObject(provider.env) &&
    envKeys.some((key) => nonBlank(provider.env[key]))
  ) {
    return 'config:api-key';
  }

  if (provider.oauth === undefined) return 'none';
  if (!plainObject(provider.oauth)) return undefined;
  if (provider.oauth.storage !== 'file' && provider.oauth.storage !== 'keyring') return undefined;
  const name = storageName(provider.oauth.key);
  if (name === undefined) return undefined;
  return `oauth-${provider.oauth.storage}:${name}`;
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
  if (operation === 'has-model') return nonBlank(config.defaultModel) ? 0 : 1;
  if (operation !== 'config-record') return 1;
  if (!nonBlank(config.defaultModel)) {
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
