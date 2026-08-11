from __future__ import annotations

import shlex
from dataclasses import dataclass


@dataclass(frozen=True)
class ParsedCommand:
    name: str
    args: list[str]
    raw: str


class CommandParseError(ValueError):
    pass


def parse_jc_command(raw: str) -> ParsedCommand:
    text = raw.strip()
    if text.startswith("/jc"):
        text = text[3:].strip()

    if not text:
        return ParsedCommand(name="help", args=[], raw=raw)

    try:
        parts = shlex.split(text)
    except ValueError as exc:
        raise CommandParseError(str(exc)) from exc

    return ParsedCommand(name=parts[0].lower(), args=parts[1:], raw=raw)
