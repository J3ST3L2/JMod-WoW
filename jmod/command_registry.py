from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Iterable


@dataclass(frozen=True)
class CommandSpec:
    name: str
    usage: str
    description: str
    mutates_state: bool = False
    permission: str = "gm"


COMMANDS: Dict[str, CommandSpec] = {
    "help": CommandSpec("help", "/jc help [command]", "Show command help", False, "player"),
    "info": CommandSpec("info", "/jc info", "Show server information", False, "gm"),
    "players": CommandSpec("players", "/jc players", "List online players", False, "gm"),
    "announce": CommandSpec("announce", "/jc announce <message>", "Broadcast a server message", True, "gm"),
    "level": CommandSpec("level", "/jc level <character> <level>", "Set a character level", True, "gm"),
    "gold": CommandSpec("gold", "/jc gold <character> <gold>", "Set character gold", True, "gm"),
    "item": CommandSpec("item", "/jc item <character> <item> [count]", "Give or mail an item", True, "gm"),
    "mount": CommandSpec("mount", "/jc mount <character> <mount>", "Teach a mount spell", True, "gm"),
    "mounts": CommandSpec("mounts", "/jc mounts <character>", "List known or available mounts", False, "gm"),
    "train": CommandSpec("train", "/jc train <character> <package>", "Apply a training package", True, "gm"),
    "preset": CommandSpec("preset", "/jc preset <character> <preset>", "Apply a provisioning preset", True, "gm"),
}


def get_command(name: str) -> CommandSpec | None:
    return COMMANDS.get(name.strip().lower())


def iter_commands() -> Iterable[CommandSpec]:
    return COMMANDS.values()
