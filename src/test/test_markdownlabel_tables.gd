extends SceneTree
## MarkdownLabel table rendering, asserted on what RichTextLabel actually shows.
##
## Run: godot --headless --path src --script test/test_markdownlabel_tables.gd
##
## Malformed table BBCode surfaces in get_parsed_text() as literal "[/cell]" or
## "[/table]" text, or as missing content after the table, so the checks read
## the parsed text rather than the generated BBCode.

const MarkdownLabelScript := preload("res://addons/markdownlabel/markdownlabel.gd")

var _pass := 0
var _fail := 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _init() -> void:
	print("=== markdownlabel table tests ===\n")
	_run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# The label only renders once it has a parent.
func _render(markdown: String) -> MarkdownLabel:
	var label: MarkdownLabel = MarkdownLabelScript.new()
	root.add_child(label)
	label.markdown_text = markdown
	return label


func _run() -> void:
	var snake := _render("| name | kind |\n|---|---|\n| has_view | pane_shown |\n\nAfter table.\nSecond line.")
	var shown := snake.get_parsed_text()
	check("snake_case cells render literally", shown.contains("has_view") and shown.contains("pane_shown"), shown)
	check("no table markup leaks into the text", not shown.contains("[") and not shown.contains("|"), shown)
	check("paragraph after the table survives with its line break",
		shown.contains("After table.\nSecond line."), shown)
	snake.free()

	var mixed := _render("\n".join([
		"Run cat a | grep b | wc now.",
		"",
		"| a | b |",
		"|:--|--:|",
		"| **bold** | *it* |",
		"",
		"Middle.",
		"",
		"| c | d |",
		"|---|---|",
		"| x | y |",
		"End with snake_case_name.",
	]))
	shown = mixed.get_parsed_text()
	check("prose with shell pipes is not a table", shown.contains("Run cat a | grep b | wc now."), shown)
	check("both tables render", mixed.text.count("[table=2]") == 2, mixed.text)
	check("delimiter rows are hidden, including the second table's",
		not shown.contains("--") and not shown.contains(":-"), shown)
	check("emphasis inside cells is applied", not shown.contains("*") and shown.contains("bold"), shown)
	check("text between and after tables survives",
		shown.contains("Middle.") and shown.contains("End with snake_case_name."), shown)
	mixed.free()

	var fenced := _render("| a | b |\n|---|---|\n| x | y |\n```a|b|c\ncode body\n```\ntrailing")
	shown = fenced.get_parsed_text()
	# A bare MarkdownLabel shows [code syntax=...] literally; MessageMarkdown
	# splits those blocks out before rendering.
	check("a fence ends the table, even with pipes in its info string",
		shown.contains("[code syntax=a|b|c]\ncode body[/code]\ntrailing")
		and not shown.contains("[/table]") and not shown.contains("[/cell]"), shown)
	fenced.free()

	var malformed := _render("a | b | c\n--- | ---\n\n| d | e |\n| -:- | --- |\n\nfoo__bar__baz")
	shown = malformed.get_parsed_text()
	check("mismatched or malformed delimiter rows stay text",
		not malformed.text.contains("[table") and shown.contains("--- | ---") and shown.contains("-:-"),
		malformed.text)
	check("intraword double underscores are literal", shown.contains("foo__bar__baz"), shown)
	malformed.free()
