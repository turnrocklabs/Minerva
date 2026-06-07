class_name AnnotationRef
extends RefCounted
## Helpers for citeable annotation references "C<n>" (DCR 019e9f602391 P2).
##
## A ref is a short, human-typeable handle ("C7") minted per Minerva project from
## ProjectIdentity.annotation_ref_seq. This is the single home for the ref STRING
## format + the sidecar scan used to reconcile the counter (so a number is never
## reused). The counter itself lives on ProjectIdentity; ref STAMPING lives there
## too (vend_ref/stamp). This class only parses/formats and scans.

const PREFIX := "C"


## Format a ref from its sequence number: 7 -> "C7".
static func format(seq: int) -> String:
	return "%s%d" % [PREFIX, seq]


## Parse a ref string ("C7") to its sequence (7). Returns 0 for anything that is
## not a well-formed C<n> (so callers can treat "no ref" and "bad ref" alike).
static func parse_seq(ref: String) -> int:
	if not ref.begins_with(PREFIX):
		return 0
	var digits := ref.substr(PREFIX.length())
	if digits.is_empty() or not digits.is_valid_int():
		return 0
	return int(digits)


## Scan the sidecars of the given document paths for the highest ref sequence
## minted for `project_id`. Used to reconcile the project counter on load / before
## a closed-file vend so a number is never reused. Missing sidecars are skipped.
static func highest_seq_in_sidecars(doc_paths: Array, project_id: String) -> int:
	var highest := 0
	for p in doc_paths:
		var path := str(p)
		if path.is_empty():
			continue
		var sidecar := AnnotationSidecar.read_sidecar(path)
		for ann in sidecar.get("annotations", []):
			highest = max(highest, _matching_seq(ann, project_id))
	return highest


## Highest ref sequence for `project_id` among an in-memory annotation array.
static func highest_seq_in_list(annotations: Array, project_id: String) -> int:
	var highest := 0
	for ann in annotations:
		highest = max(highest, _matching_seq(ann, project_id))
	return highest


static func _matching_seq(ann: Variant, project_id: String) -> int:
	if not ann is Dictionary:
		return 0
	var d := ann as Dictionary
	if str(d.get("ref_project", "")) != project_id:
		return 0
	return parse_seq(str(d.get("ref", "")))
