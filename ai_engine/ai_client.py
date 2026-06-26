"""
Thin client for a LOCALLY HOSTED AI model only.

Supported backends:
  - Ollama              (http://127.0.0.1:11434, POST /api/generate)
  - LM Studio / vLLM     (OpenAI-compatible, POST /v1/chat/completions)

No cloud endpoints are ever contacted by this module - the whole point
of the project is that strategy evolution happens on data that never
leaves the local machine.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Optional

import requests

from .config import Config

log = logging.getLogger(__name__)


@dataclass
class AIResponse:
    ok: bool
    text: str
    raw: Optional[dict] = None
    error: Optional[str] = None


class LocalAIClient:
    def __init__(self, cfg: Config):
        self.cfg = cfg

    def generate(self, prompt: str, system: str = "") -> AIResponse:
        try:
            if self.cfg.ai_provider == "ollama":
                return self._generate_ollama(prompt, system)
            return self._generate_openai_compatible(prompt, system)
        except requests.RequestException as exc:
            log.warning("Local AI request failed: %s", exc)
            return AIResponse(ok=False, text="", error=str(exc))

    def _generate_ollama(self, prompt: str, system: str) -> AIResponse:
        url = f"{self.cfg.ai_base_url.rstrip('/')}/api/generate"
        payload = {
            "model": self.cfg.ai_model,
            "prompt": prompt,
            "system": system,
            "stream": False,
        }
        resp = requests.post(url, json=payload, timeout=self.cfg.ai_timeout_seconds)
        resp.raise_for_status()
        data = resp.json()
        return AIResponse(ok=True, text=data.get("response", ""), raw=data)

    def _generate_openai_compatible(self, prompt: str, system: str) -> AIResponse:
        url = f"{self.cfg.ai_base_url.rstrip('/')}/v1/chat/completions"
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        payload = {"model": self.cfg.ai_model, "messages": messages, "stream": False}
        resp = requests.post(url, json=payload, timeout=self.cfg.ai_timeout_seconds)
        resp.raise_for_status()
        data = resp.json()
        text = data["choices"][0]["message"]["content"]
        return AIResponse(ok=True, text=text, raw=data)

    @staticmethod
    def extract_json(text: str) -> Optional[dict]:
        """Best-effort extraction of a JSON object from a model response that
        may wrap it in markdown fences or surrounding prose."""
        text = text.strip()
        if text.startswith("```"):
            text = text.strip("`")
            if text.lower().startswith("json"):
                text = text[4:]
        start = text.find("{")
        end = text.rfind("}")
        if start < 0 or end < 0 or end <= start:
            return None
        try:
            return json.loads(text[start:end + 1])
        except json.JSONDecodeError:
            return None
