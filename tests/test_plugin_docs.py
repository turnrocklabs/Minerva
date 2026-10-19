"""Real source census and drift anti-cases for the SDK documentation guard."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from check_plugin_docs import compare, contextual_contracts, declared_contracts


class PluginDocsTest(unittest.TestCase):
    def test_current_owners_and_drift(self) -> None:
        root = Path(__file__).resolve().parents[1] / "src/Scripts/Services/Plugins"
        definition, panels, generations = ((root / name).read_text() for name in
            ("PluginDefinition.gd", "PluginScenePanelHost.gd", "PluginGenerationStore.gd"))
        declarations = declared_contracts(definition, panels, generations)
        declarations.update(contextual_contracts(*((root / name).read_text() for name in
            ("MinervaIPC.gd", "RequiredPlugins.gd", "PluginToolRegistry.gd"))))
        self.assertIn("host.documents.patch_state", declarations["host_capability"])
        self.assertIn("tools[].tool_set", declarations["manifest_field"])
        self.assertIn("_on_panel_restore_live_state", declarations["panel_hook"])
        self.assertNotIn("_on_hot_reload", declarations["panel_hook"])
        self.assertIn("MinervaIPC.request_capability", declarations["sdk_method"])
        self.assertIn("handle_tool_with_context", declarations["sdk_method"])
        self.assertIn("repo", declarations["required_plugin_field"])
        # A synthetic fully documented census is the baseline, then actual source
        # and Markdown mutations must each produce the named independent error.
        rows = "\n".join(f"| `{symbol}` | {category} |" for category, symbols in
                         declarations.items() for symbol in sorted(symbols))
        self.assertEqual(compare(declarations, rows, "fixture"), [])
        changed = definition.replace('"host.echo",', '"host.echo", "host.new_contract",', 1)
        self.assertIn("fixture: undocumented host_capability: host.new_contract",
                      compare(declared_contracts(changed, panels, generations), rows, "fixture"))
        self.assertIn("fixture: obsolete panel_hook row: _on_hot_reload",
                      compare(declarations, rows + "\n| `_on_hot_reload` | panel_hook |", "fixture"))
        changed = definition.replace('data.get("name", "")', 'data.get("new_field", "")', 1)
        self.assertIn("fixture: undocumented manifest_field: new_field",
                      compare(declared_contracts(changed, panels, generations), rows, "fixture"))
        changed_panels = panels + '\nfunc probe() -> void:\n\tpanel_root.has_method("_on_panel_new")\n'
        self.assertIn("fixture: undocumented panel_hook: _on_panel_new",
                      compare(declared_contracts(definition, changed_panels, generations), rows, "fixture"))


if __name__ == "__main__":
    unittest.main()
