#!/usr/bin/env python3
"""Validate the non-secret Kimi configuration facts used by provider readiness."""

from __future__ import annotations

import json
import math
import sys
import tomllib
from pathlib import Path
from typing import Any


PROVIDER_TYPES = {
    "kimi",
    "anthropic",
    "openai_legacy",
    "openai_responses",
    "google_genai",
    "gemini",
    "vertexai",
}

MODEL_CAPABILITIES = {"image_in", "video_in", "thinking", "always_thinking"}


def _string_dict_or_none(value: Any) -> bool:
    return value is None or (
        isinstance(value, dict)
        and all(
            isinstance(key, str) and isinstance(item, str)
            for key, item in value.items()
        )
    )


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _selected_provider(config_path: Path) -> dict[str, Any] | None:
    with config_path.open("rb") as config_file:
        config = tomllib.load(config_file)

    default_model = config.get("default_model")
    models = config.get("models")
    providers = config.get("providers")
    if not _nonempty_string(default_model):
        return None
    if not isinstance(models, dict) or not isinstance(providers, dict):
        return None

    model = models.get(default_model)
    if not isinstance(model, dict):
        return None
    provider_name = model.get("provider")
    model_name = model.get("model")
    context_size = model.get("max_context_size")
    if not _nonempty_string(provider_name) or not _nonempty_string(model_name):
        return None
    if isinstance(context_size, bool) or not isinstance(context_size, int) or context_size < 1:
        return None
    capabilities = model.get("capabilities")
    if capabilities is not None and (
        not isinstance(capabilities, list)
        or any(item not in MODEL_CAPABILITIES for item in capabilities)
    ):
        return None
    display_name = model.get("display_name")
    if display_name is not None and not isinstance(display_name, str):
        return None

    provider = providers.get(provider_name)
    if not isinstance(provider, dict):
        return None
    provider_type = provider.get("type")
    if provider_type not in PROVIDER_TYPES:
        return None
    if not _nonempty_string(provider.get("base_url")):
        return None
    if "api_key" not in provider or not isinstance(provider["api_key"], str):
        return None
    if not _string_dict_or_none(provider.get("env")):
        return None
    if not _string_dict_or_none(provider.get("custom_headers")):
        return None
    reasoning_key = provider.get("reasoning_key")
    if reasoning_key is not None and not isinstance(reasoning_key, str):
        return None
    return provider


def _credential_record(config_path: Path) -> str | None:
    provider = _selected_provider(config_path)
    if provider is None:
        return None

    api_key = provider.get("api_key", "")
    if not isinstance(api_key, str):
        return None
    if _nonempty_string(api_key):
        return "config:api-key"

    oauth = provider.get("oauth")
    if oauth is None:
        return "none"
    if not isinstance(oauth, dict):
        return None
    storage = oauth.get("storage", "file")
    key = oauth.get("key")
    if storage not in {"file", "keyring"} or not _nonempty_string(key):
        return None

    storage_name = key.removeprefix("oauth/").split("/")[-1] or key
    if storage_name in {".", ".."} or "/" in storage_name or "\x00" in storage_name:
        return None
    return f"oauth-{storage}:{storage_name}"


def _oauth_file_is_usable(credentials_path: Path) -> bool:
    try:
        with credentials_path.open(encoding="utf-8") as credentials_file:
            token = json.load(credentials_file)
    except (OSError, UnicodeError, json.JSONDecodeError):
        return False

    if not isinstance(token, dict):
        return False
    if not all(
        _nonempty_string(token.get(field))
        for field in ("access_token", "refresh_token", "token_type")
    ):
        return False
    if not isinstance(token.get("scope"), str):
        return False

    expires_at = token.get("expires_at")
    if isinstance(expires_at, bool) or not isinstance(expires_at, (int, float)):
        return False
    if not math.isfinite(float(expires_at)) or expires_at <= 0:
        return False

    expires_in = token.get("expires_in", 0)
    if isinstance(expires_in, bool) or not isinstance(expires_in, (int, float)):
        return False
    return math.isfinite(float(expires_in)) and expires_in >= 0


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        return 1
    operation, source = argv[1:]
    try:
        if operation == "config-record":
            record = _credential_record(Path(source))
            if record is None:
                return 1
            print(record)
            return 0
        if operation == "oauth-file-valid":
            return 0 if _oauth_file_is_usable(Path(source)) else 1
    # Readiness is fail-closed and intentionally silent: parser diagnostics can
    # include source lines containing credentials.
    except Exception:
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
