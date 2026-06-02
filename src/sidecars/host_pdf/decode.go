package main

import (
	"bytes"
	"encoding/json"
)

// DecodeDoc parses raw JSON args into a Doc with strict allowlist validation:
// unknown keys are rejected (schema_validation_failed), mirroring the
// strict-allowlist style of host.documents.set_state (contract §7). The Op type
// is a union of every op kind's fields, so a key belonging to no kind is
// rejected here; per-kind required-field and cross-field rules are enforced in
// Generate/drawOp.
func DecodeDoc(raw []byte) (Doc, *GenError) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var doc Doc
	if err := dec.Decode(&doc); err != nil {
		return Doc{}, &GenError{
			ErrorCode:    ErrSchemaValidation,
			ErrorMessage: "request did not match schema",
			Detail:       err.Error(),
		}
	}
	return doc, nil
}
