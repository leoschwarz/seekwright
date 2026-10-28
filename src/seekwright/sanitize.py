"""Escaping model special-token literals out of text that leaves the proxy.

An open-weight or aggregated backend\'s tokenizer parses certain literals as
*structural* chat-template tokens: ``<|endoftext|>`` from a scraped GitHub
issue becomes the end-of-text marker and the whole request is rejected with a
400. The fix is content hygiene at the proxy: strip nothing, rename nothing --
insert one U+200B (zero-width space) after the opening delimiter of every such
literal. A tokenizer no longer recognises the string and the model reads it
exactly as written.

The escape is **reversible** (dropping every U+200B restores the source text),
**idempotent** (escaped text no longer matches, so a cached and re-served
response escapes once) and **deterministic** (the same input yields the same
output, which keeps any cache of responses or extracted pages valid).

The match set is deliberately tight: the two ``<|\u2026|>`` shapes cover the
ChatML / Qwen / GLM / Mistral / Phi / GPT-OSS / Llama-3 family (DeepSeek spells
the same shape with the fullwidth vertical line), and a short literal list
covers the rest. ``<s>``/``</s>``, `` thinking``, comparisons and math (the
spaces keep them out of the ``<|`` shape) and unterminated fragments like
``<|endoftext`` stay untouched -- a tokenizer that rejected those would reject a
large part of the web.
"""

from __future__ import annotations

import re

from pydantic import BaseModel

ZWSP = "\u200b"
"""The escape: a zero-width space, invisible to a reader, unrecognised by a
tokenizer, and the only character the escaping adds."""

# A token name is one word and a literal that spans a line is prose that merely
# starts like a token, so neither shape may cross a newline.
_ANGLE_ASCII = re.compile(r"<\|[^<>|\n]{1,64}\|>")
# DeepSeek spells the same delimiters with U+FF5C FULLWIDTH VERTICAL LINE;
# the content class excludes both the ASCII and the fullwidth bar so the two shapes can never overlap.
_ANGLE_FULLWIDTH = re.compile(r"<｜[^<>|｜\n]{1,64}｜>")

# Literal markers that do not fit the <|...|> shape.
_LITERAL_TOKENS = (
    "<start_of_turn>",
    "<end_of_turn>",  # Gemma
    "[INST]",
    "[/INST]",  # Llama 2 / Mistral
    "<<SYS>>",
    "<</SYS>>",  # Llama 2
)
_LITERAL_ESCAPED = tuple(t[0] + ZWSP + t[1:] for t in _LITERAL_TOKENS)


def _escape_match(m: re.Match[str]) -> str:
    s = m.group(0)
    return s[0] + ZWSP + s[1:]


def sanitize_text(text: str) -> tuple[str, int]:
    """Escape every special-token literal in ``text``.

    Returns the escaped text and the number of literals escaped. The fast path
    is the common one: text without ``<`` or ``[`` comes back as the same object.
    """
    if "<" not in text and "[" not in text:
        return text, 0
    count = 0
    text, n = _ANGLE_ASCII.subn(_escape_match, text)
    count += n
    text, n = _ANGLE_FULLWIDTH.subn(_escape_match, text)
    count += n
    for marker, escaped in zip(_LITERAL_TOKENS, _LITERAL_ESCAPED):
        c = text.count(marker)
        if c:
            count += c
            text = text.replace(marker, escaped)
    return text, count


# The wire-model fields carrying provider-originated text. The caller's own strings
# (`query`, `url`) are excluded: escaping what the caller wrote would be a surprise.
TEXT_FIELDS = frozenset({"title", "snippet", "text", "answer"})


def sanitize_model(model: BaseModel) -> int:
    """Escape every text-bearing field of a response model, in place.

    Walks the model\'s own fields and recurses into nested response models (the
    ``results`` / ``matches`` / ``sources`` lists), so one call at the engine
    covers a whole response. Returns the number of literals escaped: the
    caller logs that count, never the content.
    """
    count = 0
    for name in type(model).model_fields:
        value = getattr(model, name)
        if isinstance(value, str):
            if name in TEXT_FIELDS:
                escaped, n = sanitize_text(value)
                if n:
                    setattr(model, name, escaped)
                    count += n
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, BaseModel):
                    count += sanitize_model(item)
        elif isinstance(value, BaseModel):
            count += sanitize_model(value)
    return count
