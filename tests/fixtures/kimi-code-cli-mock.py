#!/usr/bin/env python3
"""Offline Kimi Code CLI config-command fixture used by shell unit tests."""

from __future__ import annotations

import json
import os
import sys
import tomllib
from pathlib import Path
from typing import Any


CAMEL_KEYS = {
    "api_key": "apiKey",
    "base_url": "baseUrl",
    "custom_headers": "customHeaders",
    "default_model": "defaultModel",
    "display_name": "displayName",
    "max_context_size": "maxContextSize",
    "max_input_size": "maxInputSize",
    "max_output_size": "maxOutputSize",
    "oauth_host": "oauthHost",
    "reasoning_key": "reasoningKey",
}


def _is_string_map(value: Any) -> bool:
    return isinstance(value, dict) and all(
        isinstance(key, str) and isinstance(item, str) for key, item in value.items()
    )


def _valid_config(config: Any) -> bool:
    if not isinstance(config, dict):
        return False
    providers = config.get("providers", {})
    models = config.get("models", {})
    if not isinstance(providers, dict) or not isinstance(models, dict):
        return False
    for provider in providers.values():
        if not isinstance(provider, dict):
            return False
        for key in ("type", "api_key", "base_url", "default_model"):
            if key in provider and not isinstance(provider[key], str):
                return False
        for key in ("env", "custom_headers"):
            if key in provider and not _is_string_map(provider[key]):
                return False
        oauth = provider.get("oauth")
        if oauth is not None:
            if not isinstance(oauth, dict):
                return False
            if oauth.get("storage") not in {"file", "keyring"}:
                return False
            if not isinstance(oauth.get("key"), str) or not oauth["key"]:
                return False
    for model in models.values():
        if not isinstance(model, dict):
            return False
        for key in ("provider", "model"):
            if key in model and not isinstance(model[key], str):
                return False
        if "max_context_size" in model:
            size = model["max_context_size"]
            if isinstance(size, bool) or not isinstance(size, int) or size < 1:
                return False
        if "capabilities" in model and (
            not isinstance(model["capabilities"], list)
            or not all(isinstance(item, str) for item in model["capabilities"])
        ):
            return False
    return True


def _camelize(value: Any) -> Any:
    if isinstance(value, list):
        return [_camelize(item) for item in value]
    if not isinstance(value, dict):
        return value
    return {CAMEL_KEYS.get(key, key): _camelize(item) for key, item in value.items()}


def _load(path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        config = tomllib.load(stream)
    if not _valid_config(config):
        raise ValueError("invalid config")
    return config


def main(argv: list[str]) -> int:
    if argv[:2] == ["doctor", "config"] and len(argv) == 3:
        try:
            _load(Path(argv[2]))
        except Exception:
            return 1
        return 0

    if argv[:2] == ["provider", "list"] and len(argv) in {2, 3}:
        try:
            config = _load(Path(os.environ["KIMI_CODE_HOME"]) / "config.toml")
        except Exception:
            return 1
        providers = config.get("providers", {})
        models = config.get("models", {})
        if argv[2:] == ["--json"]:
            print(json.dumps({"providers": _camelize(providers), "models": _camelize(models)}))
        else:
            for provider_id, provider in providers.items():
                provider_type = provider.get("type", "")
                count = sum(1 for model in models.values() if model.get("provider") == provider_id)
                print(f"{provider_id}  type={provider_type}  models={count}  source=inline")
            default_model = config.get("default_model")
            if isinstance(default_model, str):
                print(f"\nDefault model: {default_model}")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
