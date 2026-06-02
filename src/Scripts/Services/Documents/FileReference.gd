class_name FileReference
extends RefCounted
## Pure helpers for attaching a file to a note as a REFERENCE rather than inlining
## its bytes. A human attaches files an email points at (Word/Excel/PDF/images);
## binary documents have no in-app reader yet, so instead of garbage-decoding the
## bytes as text we make a note that just records the file's path — the pointer an
## LLM needs to read it with the right tool (e.g. minerva_read_document for .docx).
##
## Static + dependency-free (no autoloads, no scene tree) so it is unit-testable
## on its own, separate from the heavier Note class that uses it.

## Is this file binary (→ reference it) rather than UTF-8 text (→ inline it)?
## Sniffs the first 8 KiB for a NUL byte — present in zip-based formats
## (.docx/.xlsx) and .pdf, absent from text. Standard, list-free, cheap. An
## unreadable file is treated as binary (a reference is safer than a garbage read).
static func looks_binary(file_path: String) -> bool:
	var fa := FileAccess.open(file_path, FileAccess.READ)
	if fa == null:
		return true
	var sample := fa.get_buffer(8192)
	fa.close()
	return sample.has(0)


## The text body of a file-reference note: a human/LLM-readable pointer carrying
## the absolute path, filename, and type. Pure (no I/O).
static func reference_text(file_path: String) -> String:
	return "📎 Attached file (referenced, not inlined)\nName: %s\nPath: %s\nType: .%s\n\nRead the file from this path when needed (e.g. minerva_read_document for .docx)." % [
		file_path.get_file(), file_path, file_path.get_extension()]
