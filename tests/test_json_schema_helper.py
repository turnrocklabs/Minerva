#!/usr/bin/env python3
"""Black-box contract for the source-built JSON Schema companion."""
import json
import os
import queue
import struct
import subprocess
import threading
import unittest


class Helper:
    def __init__(self):
        path = os.environ.get("MINERVA_JSON_SCHEMA_HELPER")
        if not path:
            raise unittest.SkipTest("MINERVA_JSON_SCHEMA_HELPER is not set")
        self.process = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1)
        self.next_id = 0
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._read_lines, daemon=True)
        self.reader.start()

    def _read_lines(self):
        for line in self.process.stdout:
            self.lines.put(line)

    def call(self, op, **fields):
        self.next_id += 1
        request = {"id": str(self.next_id), "op": op, **fields}
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        try:
            line = self.lines.get(timeout=2.0)
        except queue.Empty:
            self.process.kill()
            _, stderr = self.process.communicate(timeout=2)
            raise AssertionError(f"helper timed out; stderr={stderr[:500]}")
        return json.loads(line)

    def close(self):
        try:
            if self.process.poll() is None:
                if not self.process.stdin.closed:
                    self.process.stdin.close()
                self.process.wait(timeout=2)
            self.reader.join(timeout=2)
            stderr = self.process.stderr.read()
            if stderr:
                raise AssertionError(f"unexpected helper stderr: {stderr[:500]}")
        finally:
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                if stream is not None and not stream.closed:
                    stream.close()


class JSONSchemaHelperTest(unittest.TestCase):
    def setUp(self):
        self.helper = Helper()

    def tearDown(self):
        self.helper.close()

    def compile(self, schema, registry=None):
        result = self.helper.call("compile", schema_raw=json.dumps(schema), registry=registry or {})
        self.assertTrue(result["ok"], result)
        return result["handle"]

    def validate(self, handle, value):
        return self.helper.call("validate", handle=handle,
                                instance_raw=json.dumps(value, separators=(",", ":")))

    def test_draft_2020_12_features_and_offline_resolution(self):
        # Boolean schemas are complete Draft 2020-12 schemas, including when
        # supplied as offline registry resources.
        allow = self.compile(True)
        deny = self.compile({"$ref": "urn:minerva:deny"}, {"urn:minerva:deny": "false"})
        self.assertTrue(self.validate(allow, {"anything": 1})["valid"])
        self.assertFalse(self.validate(deny, None)["valid"])
        address = {
            "$id": "urn:minerva:address", "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$dynamicAnchor": "node", "type": "object", "properties": {"zip": {"pattern": "^[0-9]{5}$"}},
            "required": ["zip"], "unevaluatedProperties": False,
        }
        schema = {
            "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object",
            "allOf": [{"properties": {"address": {"$ref": "urn:minerva:address"}}}],
            "properties": {"address": True}, "unevaluatedProperties": False,
        }
        handle = self.compile(schema, {"urn:minerva:address": json.dumps(address)})
        self.assertTrue(self.validate(handle, {"address": {"zip": "90210"}})["valid"])
        self.assertFalse(self.validate(handle, {"address": {"zip": "bad", "remote": True}})["valid"])
        dynamic = {
            "$schema": "https://json-schema.org/draft/2020-12/schema", "$dynamicAnchor": "node",
            "type": "object", "properties": {"child": {"$dynamicRef": "#node"}},
            "unevaluatedProperties": False,
        }
        dynamic_handle = self.compile(dynamic)
        self.assertTrue(self.validate(dynamic_handle, {"child": {"child": {}}})["valid"])
        self.assertFalse(self.validate(dynamic_handle, {"child": {"extra": 1}})["valid"])

    def test_invalid_schema_limits_release_and_numeric_adaptation(self):
        invalid = self.helper.call("compile", schema_raw=json.dumps({"type": 12}), registry={})
        self.assertFalse(invalid["ok"])
        self.assertEqual("invalid_schema", invalid["error"]["code"])
        missing = self.helper.call("compile", schema_raw=json.dumps({"$ref": "https://example.invalid/a"}), registry={})
        self.assertFalse(missing["ok"])
        legacy_registry = self.helper.call(
            "compile", schema_raw='{"$ref":"urn:legacy"}',
            registry={"urn:legacy": json.dumps({
                "$schema": "http://json-schema.org/draft-07/schema#", "type": "string"})})
        self.assertEqual("unsupported_dialect", legacy_registry["error"]["code"])
        huge = self.helper.call("compile", schema_raw=" " * (4 * 1024 * 1024 + 1), registry={})
        self.assertEqual("schema_too_large", huge["error"]["code"])
        handle = self.compile({"type": "number"})
        exact = self.helper.call("compare_numbers", original_raw="0.5", adapted_raw="0.5")
        binary64_spelling = self.helper.call(
            "compare_numbers",
            original_raw='{"mesh":{"vertices":[[0.1,0.0]]}}',
            adapted_raw='{"mesh":{"vertices":[[0.10000000000000001,0.0]]}}')
        alternate_shortest = self.helper.call(
            "compare_numbers",
            original_raw='{"result":{"mesh":{"vertices":[[47.82795043337536]]}}}',
            adapted_raw='{"result":{"mesh":{"vertices":[[47.82795043337536]]}}}')
        changed = self.helper.call("compare_numbers", original_raw="0.10000000000000001", adapted_raw="0.1")
        unsafe = self.helper.call("compare_numbers", original_raw="9007199254740992", adapted_raw="9007199254740992")
        self.assertTrue(exact["ok"])
        self.assertTrue(binary64_spelling["ok"], binary64_spelling)
        self.assertTrue(alternate_shortest["ok"], alternate_shortest)
        self.assertEqual("unsupported_number", changed["error"]["code"])
        self.assertEqual("unsupported_number", unsafe["error"]["code"])
        self.assertEqual("", changed["error"]["details"]["pointer"])
        self.assertEqual("0.10000000000000001", changed["error"]["details"]["original"])
        self.assertEqual("0.1", changed["error"]["details"]["adapted"])
        nested_changed = self.helper.call(
            "compare_numbers", original_raw='{"result":{"bbox":[0.10000000000000001]}}',
            adapted_raw='{"result":{"bbox":[0.1]}}')
        self.assertEqual("/result/bbox/0", nested_changed["error"]["details"]["pointer"])
        self.assertLessEqual(len(nested_changed["error"]["details"]["pointer"]), 256)
        self.assertLessEqual(len(nested_changed["error"]["details"]["original"]), 96)
        prepared = self.helper.call(
            "prepare_numbers",
            original_raw='{"result":{"edges":[{"polyline":[[0],[99.80267284282715]]}]}}',
            adapted_raw='{"result":{"edges":[{"polyline":[[0],[99.80267284282716]]}]}}')
        self.assertTrue(prepared["ok"], prepared)
        words = prepared["corrections"]["result"]["edges"][0]["polyline"][1][0]
        self.assertEqual(list(struct.unpack("<II", struct.pack("<d", 99.80267284282715))),
                         [int(word) for word in words])
        transformed = self.helper.call(
            "prepare_numbers", original_raw='{"value":0.5}', adapted_raw='{"value":0.75}')
        self.assertEqual("numeric_value_changed", transformed["error"]["details"]["reason"])
        ambiguous_source = self.helper.call(
            "prepare_numbers", original_raw='{"value":0.10000000000000001}',
            adapted_raw='{"value":0.1}')
        self.assertEqual("source_not_binary64_canonical",
                         ambiguous_source["error"]["details"]["reason"])
        released = self.helper.call("release", handle=handle)
        self.assertTrue(released["ok"])
        self.assertEqual("invalid_handle", self.validate(handle, 1)["error"]["code"])

    def test_supported_decimal_and_integral_multiple_of_policy(self):
        decimal = self.helper.call(
            "compile", schema_raw='{"const":0.1}', registry={})
        self.assertTrue(decimal["ok"])
        self.assertTrue(self.helper.call(
            "validate", handle=decimal["handle"], instance_raw="0.1")["valid"])
        array_compare = self.helper.call(
            "compare_numbers", original_raw="[0.1]", adapted_raw="[0.1]")
        self.assertTrue(array_compare["ok"])
        near_const = self.helper.call(
            "compile", schema_raw='{"const":0.10000000000000001}', registry={})
        self.assertEqual("unsupported_number", near_const["error"]["code"])
        large_exponent = self.helper.call(
            "compile", schema_raw='{"const":1e1000000}', registry={})
        self.assertEqual("unsupported_number", large_exponent["error"]["code"])

        integral = self.compile({"multipleOf": 3})
        self.assertTrue(self.helper.call(
            "validate", handle=integral, instance_raw="9007199254740990")["valid"])
        for value in ("6.000000000000001", "5.999999999999999", "9007199254740989"):
            self.assertFalse(self.helper.call(
                "validate", handle=integral, instance_raw=value)["valid"], value)
        fractional = self.helper.call(
            "compile", schema_raw='{"multipleOf":0.1}', registry={})
        self.assertEqual("unsupported_number", fractional["error"]["code"])
        self.assertIn("multipleOf", fractional["error"]["message"])
        referenced_fractional = self.helper.call(
            "compile", schema_raw='{"$ref":"#/$defs/divisor",'
                                  '"$defs":{"divisor":{"multipleOf":0.1}}}', registry={})
        self.assertEqual("unsupported_number", referenced_fractional["error"]["code"])
        referenced_zero = self.helper.call(
            "compile", schema_raw='{"$ref":"#/$defs/divisor",'
                                  '"$defs":{"divisor":{"multipleOf":0}}}', registry={})
        self.assertEqual("invalid_schema", referenced_zero["error"]["code"])
        # The supported profile does not treat unknown-keyword contents as schema
        # resources. Reject that pointer instead of assigning it a numeric-policy error.
        unknown_target = self.helper.call(
            "compile", schema_raw='{"$ref":"#/custom/divisor",'
                                  '"custom":{"divisor":{"multipleOf":0.1}}}', registry={})
        self.assertFalse(unknown_target["ok"])
        registry_fractional = self.helper.call(
            "compile", schema_raw='{"$ref":"urn:fractional"}',
            registry={"urn:fractional": '{"multipleOf":0.1}'})
        self.assertEqual("unsupported_number", registry_fractional["error"]["code"])
        named_property = self.helper.call(
            "compile", schema_raw='{"properties":{"multipleOf":{"type":"number"}},'
                                  '"default":{"multipleOf":0.1}}', registry={})
        self.assertTrue(named_property["ok"], named_property)
        unsafe_schema = self.helper.call(
            "compile", schema_raw='{"const":9007199254740993}', registry={})
        self.assertEqual("unsupported_number", unsafe_schema["error"]["code"])
        unsafe_instance = self.helper.call(
            "validate", handle=integral, instance_raw="9007199254740993")
        self.assertEqual("unsupported_number", unsafe_instance["error"]["code"])

    def test_malformed_request_recovers_and_eof_exits(self):
        self.helper.process.stdin.write("{broken\n")
        self.helper.process.stdin.flush()
        malformed = json.loads(self.helper.lines.get(timeout=2.0))
        self.assertEqual("invalid_json", malformed["error"]["code"])
        self.assertTrue(self.helper.call("ping")["ok"])
        self.helper.process.stdin.close()
        self.helper.process.wait(timeout=2.0)
        self.assertEqual(0, self.helper.process.returncode)


if __name__ == "__main__":
    unittest.main()
