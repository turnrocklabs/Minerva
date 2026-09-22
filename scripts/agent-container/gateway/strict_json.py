"""Strict JSON decoding for untrusted gateway input.

Python's json module accepts things a filter must not: duplicate keys (which
one wins depends on the parser, so the gateway and the upstream could read
different values), NaN/Infinity, lone surrogates and unbounded nesting. Every
body the gateway reads from a container or an upstream goes through loads().
"""
import json
import math

MAX_DEPTH = 32
MAX_NUMBER_CHARS = 32


class StrictJSONError(ValueError):
    pass


def _no_duplicates(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise StrictJSONError(f"duplicate key {key!r}")
        obj[key] = value
    return obj


def _no_constants(name):
    raise StrictJSONError(f"non-finite number {name}")


def _parse_float(text):
    # "1e999" is not a named constant; it overflows to inf here instead.
    if len(text) > MAX_NUMBER_CHARS:
        raise StrictJSONError("number too long")
    value = float(text)
    if not math.isfinite(value):
        raise StrictJSONError("non-finite number")
    return value


def _parse_int(text):
    if len(text) > MAX_NUMBER_CHARS:
        raise StrictJSONError("number too long")
    return int(text)


def _check(value, depth):
    if depth > MAX_DEPTH:
        raise StrictJSONError("nesting too deep")
    if isinstance(value, str):
        # json.loads turns "\ud800" escapes into lone surrogates that no UTF-8
        # encoder can round-trip; refuse them rather than re-encode lossy.
        try:
            value.encode("utf-8")
        except UnicodeEncodeError:
            raise StrictJSONError("lone surrogate in string") from None
    elif isinstance(value, dict):
        for key, item in value.items():
            _check(key, depth + 1)
            _check(item, depth + 1)
    elif isinstance(value, list):
        for item in value:
            _check(item, depth + 1)


def loads(data: bytes, max_bytes: int):
    """Decode UTF-8 JSON bytes, refusing anything ambiguous or oversized."""
    if len(data) > max_bytes:
        raise StrictJSONError(f"body over {max_bytes} bytes")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise StrictJSONError("body is not UTF-8") from None
    try:
        value = json.loads(text, object_pairs_hook=_no_duplicates, parse_constant=_no_constants,
                           parse_float=_parse_float, parse_int=_parse_int)
    except RecursionError:
        raise StrictJSONError("nesting too deep") from None
    except json.JSONDecodeError:
        raise StrictJSONError("invalid JSON") from None
    except ValueError as exc:  # StrictJSONError from a hook, or a numeric conversion
        if isinstance(exc, StrictJSONError):
            raise
        raise StrictJSONError("invalid number") from None
    _check(value, 0)
    return value


def dumps(value) -> bytes:
    """Canonical compact encoding for everything the gateway sends."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")
