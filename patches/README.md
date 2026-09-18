# Minerva patches

Custom patches for native dependencies live beside their build integration:

- `patches/godot_cef/*.patch` are applied by `build-godot-cef.sh`. See
  `patches/godot_cef/README.md` for the pinned source and rebuild procedure.
- `src/native/json_schema_helper/jsoncons-integral-multiple-of.patch` is
  verified and applied by the schema-helper builder.

Keep patches minimal and regenerate them from the pinned upstream revision so
dependency drift fails clearly during preparation.
