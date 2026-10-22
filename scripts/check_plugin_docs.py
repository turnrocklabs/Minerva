"""Check the host SDK guide; compare plugin docs only with explicit repo roots."""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

CONTRACTS = {"host_capability", "capability_namespace", "manifest_field",
             "panel_hook", "host_path", "plugin_capability", "sdk_method",
             "required_plugin_field"}


def function_body(source: str, name: str) -> str:
    match = re.search(rf"^(?:static )?func {re.escape(name)}\(.*?(?=^(?:static )?func |\Z)",
                      source, re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError(f"Missing source owner: {name}")
    return re.sub(r"^\s*#.*$", "", match.group(), flags=re.MULTILINE)


def array_strings(source: str, name: str) -> set[str]:
    match = re.search(rf"^const {name}(?:\s*:\s*[^=]+)?\s*:?=\s*\[(.*?)^\]", source,
                      re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError(f"Missing source declaration: {name}")
    return set(re.findall(r'"([^"\n]+)"', re.sub(r"#.*", "", match[1])))


def declared_contracts(definition: str, panel_host: str, generations: str,
                       dependencies: str) -> dict[str, set[str]]:
    """Read literal declarations from their existing owners, never from fixtures."""
    parser = function_body(definition, "_from_dict_internal")
    fields: set[str] = set()
    # Receiver names are parser scopes, not a second list of allowed fields.
    for receiver, prefix in {"data": "", "backend": "backend.", "ui": "ui.",
                             "perms": "permissions.", "network": "permissions.network.",
                             "filesystem": "permissions.filesystem.", "pf": "project_file.",
                             "pe": "project_export."}.items():
        fields.update(prefix + key for key in re.findall(
            rf'\b{receiver}\.(?:get|has)\("([^"\n]+)"', parser))
    panel = function_body(definition, "_parse_panel_entry")
    fields.update("ui.panels[]." + key for key in re.findall(
        r'\bpanel\.(?:get|has)\("([^"\n]+)"', panel))
    fields.update("ui.panels[].chrome." + key for key in re.findall(
        r'\bchrome_dict\.(?:get|has)\("([^"\n]+)"', panel))
    fields.update("state." + key for key in re.findall(
        r'data\.get\("state",\s*\{\}\)\.get\("([^"\n]+)"', parser))
    fields.update("tools[]." + key for key in re.findall(
        r'\btool_entry\.(?:get|has)\("([^"\n]+)"', function_body(definition, "validate")))
    fields.update("requires_plugins[]." + key for key in re.findall(
        r'\bentry\.(?:get|has)\("([^"\n]+)"', function_body(dependencies, "parse")))
    return {
        "host_capability": array_strings(definition, "ALLOWED_HOST_CAPABILITIES"),
        "capability_namespace": array_strings(definition, "ALLOWED_HOST_CAPABILITY_NAMESPACES"),
        "plugin_capability": array_strings(definition, "CAPABILITIES"),
        "manifest_field": fields,
        "panel_hook": set(re.findall(r'panel_root\.has_method\("(_on_panel_[^"]+)"', panel_host)),
        "host_path": array_strings(generations, "HOST_PATHS"),
    }


def documented_contracts(markdown: str) -> dict[str, set[str]]:
    result = {category: set() for category in CONTRACTS}
    for line in markdown.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[1] in result:
            token = re.search(r"`([^`]+)`", cells[0])
            symbol = token[1] if token else cells[0]
            if symbol in result[cells[1]]:
                raise ValueError(f"Duplicate {cells[1]} row: {symbol}")
            result[cells[1]].add(symbol)
    return result


def contextual_contracts(ipc: str, required: str, registry: str) -> dict[str, set[str]]:
    """Include callable panel routes and the required-provider release coordinate."""
    methods = {"MinervaIPC." + name for name in re.findall(
        r"^func ((?:request_\w+|get_bulk_payload_limit))\(", ipc, re.MULTILINE)}
    methods.update(re.findall(r'panel\.has_method\("(handle_tool[^"\n]*)"', registry))
    # These two owners define the per-provider repository/release-page boundary.
    for name in ("repository", "release_page"):
        function_body(required, name)  # Refuse a renamed/removed owner.
        methods.add("RequiredPlugins." + name)
    fields = set(re.findall(r'entry\.get\("([^"\n]+)"', function_body(required, "repository")))
    return {"sdk_method": methods, "required_plugin_field": fields}


def compare(declared: dict[str, set[str]], markdown: str, label: str) -> list[str]:
    documented = documented_contracts(markdown)
    errors: list[str] = []
    for category, symbols in declared.items():
        for symbol in sorted(symbols - documented[category]):
            errors.append(f"{label}: undocumented {category}: {symbol}")
        for symbol in sorted(documented[category] - symbols):
            errors.append(f"{label}: obsolete {category} row: {symbol}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--plugins-root", type=Path)
    args = parser.parse_args()
    services = args.host_root / "src/Scripts/Services/Plugins"
    try:
        declared = declared_contracts(*((services / name).read_text(encoding="utf-8") for name in
            ("PluginDefinition.gd", "PluginScenePanelHost.gd", "PluginGenerationStore.gd",
             "PluginDependencyContract.gd")))
        declared.update(contextual_contracts(*((services / name).read_text(encoding="utf-8") for name in
            ("MinervaIPC.gd", "RequiredPlugins.gd", "PluginToolRegistry.gd"))))
        guide = (args.host_root / "src/plugins/plugin_system_guide.md").read_text(encoding="utf-8")
        errors = compare(declared, guide, "host guide")
        if args.plugins_root:
            ledger = (args.plugins_root / "docs/PLUGIN_API_COVERAGE.md").read_text(encoding="utf-8")
            errors.extend(compare(declared, ledger, "plugins ledger"))
            links = subprocess.run([sys.executable,
                str(args.plugins_root / "scripts/check_plugin_docs.py"),
                "--plugins-root", str(args.plugins_root), "--host-guide",
                str(args.host_root / "src/plugins/plugin_system_guide.md")], check=False)
            if links.returncode:
                errors.append("plugins guide/ledger link and retired-claim checks failed")
    except (OSError, ValueError) as error:
        print(f"Plugin docs: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Plugin docs: {sum(map(len, declared.values()))} declarations; {len(errors)} errors")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
