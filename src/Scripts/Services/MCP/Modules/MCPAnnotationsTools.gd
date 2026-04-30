class_name MCPAnnotationsTools
extends "res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd"
## Compatibility shim for the old plural module name.
##
## Minerva registers MCPAnnotationTools as the single annotation MCP module.
## Keep this class_name for older tests and plugin code, but inherit all behavior
## from the registered singular implementation so query/status/repair/apply-hook
## logic cannot diverge again.
