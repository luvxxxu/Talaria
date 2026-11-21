"""Checks the plugin against a real Hermes checkout without importing Hermes.

    HERMES_SRC=/path/to/hermes-agent python -m unittest test_hermes_compat

Parses the Hermes source with ``ast`` and confirms that every class, method,
field and registration option the plugin relies on exists with the expected
parameters. Skipped when HERMES_SRC is not set.
"""

import ast
import os
import unittest
from pathlib import Path

import support  # noqa: F401  (puts the stubs and the plugin on sys.path)
from talaria import adapter as talaria

SRC = os.environ.get("HERMES_SRC")


def parse(relative: str) -> ast.Module:
    return ast.parse((Path(SRC) / relative).read_text(encoding="utf-8"))


def find_class(module: ast.Module, name: str) -> ast.ClassDef:
    for node in module.body:
        if isinstance(node, ast.ClassDef) and node.name == name:
            return node
    raise AssertionError(f"class {name} not found")


def methods(cls: ast.ClassDef) -> dict:
    return {n.name: n for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


def fields(cls: ast.ClassDef) -> set:
    return {n.target.id for n in cls.body if isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name)}


def params(fn) -> set:
    a = fn.args
    return {p.arg for p in [*a.posonlyargs, *a.args, *a.kwonlyargs]}


def top_level_functions(module: ast.Module) -> dict:
    return {n.name: n for n in module.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


def top_level_names(module: ast.Module) -> set:
    names = set(top_level_functions(module))
    names |= {n.name for n in module.body if isinstance(n, ast.ClassDef)}
    return names


@unittest.skipUnless(SRC, "set HERMES_SRC to a Hermes checkout")
class HermesCompatTests(unittest.TestCase):
    def test_registration_options_exist(self):
        captured = {}

        class Ctx:
            def register_platform(self, **kwargs):
                captured.update(kwargs)

        talaria.register(Ctx())
        entry_fields = fields(find_class(parse("gateway/platform_registry.py"), "PlatformEntry"))
        self.assertEqual(set(captured) - entry_fields, set())

    def test_platform_accepts_plugin_names(self):
        platform = find_class(parse("gateway/config.py"), "Platform")
        self.assertIn("_missing_", methods(platform), "Platform('talaria') needs Platform._missing_")

    def test_adapter_base_class(self):
        base = parse("gateway/platforms/base.py")
        adapter = methods(find_class(base, "BasePlatformAdapter"))
        for name in ("handle_message", "build_source", "format_message", "send_typing",
                     "_mark_connected", "_mark_disconnected", "_set_fatal_error",
                     "_acquire_platform_lock", "_release_platform_lock"):
            self.assertIn(name, adapter)
        self.assertLessEqual({"chat_id", "chat_name", "chat_type", "user_id", "user_name"},
                             params(adapter["build_source"]))
        self.assertLessEqual({"code", "message", "retryable"}, params(adapter["_set_fatal_error"]))
        self.assertLessEqual({"scope", "identity", "resource_desc"}, params(adapter["_acquire_platform_lock"]))
        self.assertLessEqual({"success", "message_id", "error", "retryable"},
                             fields(find_class(base, "SendResult")))

    def test_message_event(self):
        event = parse("gateway/platforms/event.py")
        self.assertLessEqual({"text", "message_type", "source", "message_id", "raw_message", "timestamp"},
                             fields(find_class(event, "MessageEvent")))
        message_type = find_class(event, "MessageType")
        self.assertIn("TEXT", {t.id for n in message_type.body if isinstance(n, ast.Assign) for t in n.targets})

    def test_helpers(self):
        shared = top_level_functions(parse("gateway/platforms/_shared.py"))
        self.assertIn("get_scoped_secret", shared)
        self.assertIn("nothing_sent", params(shared["send_error"]))
        helpers = parse("gateway/platforms/helpers.py")
        self.assertLessEqual({"MessageDeduplicator", "hash_for_log", "strip_markdown"}, top_level_names(helpers))
        self.assertIn("keep_link_targets", params(top_level_functions(helpers)["strip_markdown"]))
        dedup = methods(find_class(helpers, "MessageDeduplicator"))
        self.assertIn("ttl_seconds", params(dedup["__init__"]))
        self.assertIn("is_duplicate", dedup)
        self.assertIn("get_hermes_home", top_level_functions(parse("hermes_constants.py")))


if __name__ == "__main__":
    unittest.main()
