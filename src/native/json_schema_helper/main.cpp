// Minerva JSON Schema companion. jsoncons is acquired from the pinned source
// lock; this program has no Godot or network dependency.
#include <jsoncons/json.hpp>
#include <jsoncons_ext/jsonschema/jsonschema.hpp>
#include <jsoncons_ext/jsonschema/draft202012/schema_draft202012.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>

using jsoncons::json;
namespace js = jsoncons::jsonschema;

namespace {
constexpr std::size_t kSchemaBytes = 4u * 1024u * 1024u;
constexpr std::size_t kInstanceBytes = 32u * 1024u * 1024u;
constexpr std::size_t kMaxNodes = 100000u;
constexpr std::size_t kMaxDepth = 128u;
constexpr std::size_t kRequestBytes = 72u * 1024u * 1024u;
constexpr std::size_t kMaxSchemas = 256u;
constexpr int64_t kMaxSafeInteger = 9007199254740991LL;
constexpr std::size_t kDiagnosticText = 96u;
constexpr std::size_t kDiagnosticPointer = 256u;

struct Entry {
    std::string raw;
    std::unique_ptr<js::json_schema<json>> compiled;
};
std::unordered_map<uint64_t, Entry> schemas;
uint64_t next_handle = 1;

jsoncons::json_options strict_options(bool lossless_numbers = false) {
    return jsoncons::json_options{}.allow_comments(false).allow_trailing_comma(false)
        .lossless_number(lossless_numbers);
}

json response(const json& id, bool ok, const std::string& code = {}, const std::string& message = {}) {
    json out(jsoncons::json_object_arg);
    out["id"] = id;
    out["ok"] = ok;
    if (!ok) {
        json error(jsoncons::json_object_arg);
        error["code"] = code;
        error["message"] = message.substr(0, 512);
        out["error"] = std::move(error);
    }
    return out;
}

bool within_shape(const json& value, std::size_t depth, std::size_t& nodes) {
    if (depth > kMaxDepth || ++nodes > kMaxNodes) return false;
    if (value.is_array()) {
        for (const auto& child : value.array_range()) if (!within_shape(child, depth + 1, nodes)) return false;
    } else if (value.is_object()) {
        for (const auto& member : value.object_range()) if (!within_shape(member.value(), depth + 1, nodes)) return false;
    }
    return true;
}

std::pair<std::string, int64_t> decimal_key(std::string text);

bool godot_numeric_safe(const json& value) {
    if (value.is_int64()) {
        auto number = value.as<int64_t>();
        return number >= -kMaxSafeInteger && number <= kMaxSafeInteger;
    }
    if (value.is_uint64()) return value.as<uint64_t>() <= static_cast<uint64_t>(kMaxSafeInteger);
    if (value.is_double()) {
        double number = value.as<double>();
        return std::isfinite(number) &&
            (std::trunc(number) != number || std::fabs(number) <= kMaxSafeInteger);
    }
    if (value.is_string() && (value.tag() == jsoncons::semantic_tag::bigdec ||
            value.tag() == jsoncons::semantic_tag::bigint)) {
        try {
            auto key = decimal_key(value.as<std::string>());
            if (key.second >= 0) {
                std::string digits = key.first.front() == '-' ? key.first.substr(1) : key.first;
                if (key.second > 16 || digits.size() + static_cast<std::size_t>(key.second) > 16) return false;
                std::string expanded = digits + std::string(static_cast<std::size_t>(key.second), '0');
                const std::string limit = "9007199254740991";
                return expanded.size() < limit.size() || (expanded.size() == limit.size() && expanded <= limit);
            }
            return true;
        } catch (...) { return false; }
    }
    if (value.is_array()) {
        for (const auto& child : value.array_range()) if (!godot_numeric_safe(child)) return false;
    } else if (value.is_object()) {
        for (const auto& member : value.object_range()) if (!godot_numeric_safe(member.value())) return false;
    }
    return true;
}

std::pair<std::string, int64_t> decimal_key(std::string text) {
    bool negative = !text.empty() && text.front() == '-';
    if (negative || (!text.empty() && text.front() == '+')) text.erase(0, 1);
    int64_t exponent = 0;
    auto e = text.find_first_of("eE");
    if (e != std::string::npos) {
        std::string exponent_text = text.substr(e + 1);
        if (exponent_text.size() > 7) throw std::out_of_range("numeric exponent");
        exponent = std::stoll(exponent_text);
        if (exponent < -100000 || exponent > 100000) throw std::out_of_range("numeric exponent");
        text.resize(e);
    }
    auto dot = text.find('.');
    if (dot != std::string::npos) {
        exponent -= static_cast<int64_t>(text.size() - dot - 1);
        text.erase(dot, 1);
    }
    auto first = text.find_first_not_of('0');
    text = first == std::string::npos ? "0" : text.substr(first);
    while (text.size() > 1 && text.back() == '0') { text.pop_back(); ++exponent; }
    if (text == "0") exponent = 0;
    if (negative && text != "0") text.insert(text.begin(), '-');
    return {text, exponent};
}

bool number_key(const json& value, std::pair<std::string, int64_t>& key) {
    if (value.is_int64()) { key = decimal_key(std::to_string(value.as<int64_t>())); return true; }
    if (value.is_uint64()) { key = decimal_key(std::to_string(value.as<uint64_t>())); return true; }
    if (value.is_double()) { key = decimal_key(value.to_string()); return true; }
    if (value.is_string() && (value.tag() == jsoncons::semantic_tag::bigdec ||
            value.tag() == jsoncons::semantic_tag::bigint)) {
        key = decimal_key(value.as<std::string>()); return true;
    }
    return false;
}

bool numbers_equal(const json& original, const json& adapted) {
    std::pair<std::string, int64_t> left, right;
    bool left_number = number_key(original, left);
    bool right_number = number_key(adapted, right);
    if (left_number || right_number) return left_number && right_number && left == right;
    if (original.is_array() != adapted.is_array() || original.is_object() != adapted.is_object()) return false;
    if (original.is_array() && adapted.is_array()) {
        if (original.size() != adapted.size()) return false;
        for (std::size_t i = 0; i < original.size(); ++i) if (!numbers_equal(original[i], adapted[i])) return false;
        return true;
    } else if (original.is_object() && adapted.is_object()) {
        if (original.size() != adapted.size()) return false;
        for (const auto& member : original.object_range()) {
            if (!adapted.contains(member.key()) || !numbers_equal(member.value(), adapted.at(member.key()))) return false;
        }
        return true;
    }
    return original == adapted;
}

std::string bounded(std::string value, std::size_t limit) {
    if (value.size() <= limit) return value;
    value.resize(limit);
    return value;
}

std::string pointer_token(std::string value) {
    std::string escaped;
    for (char ch : value) {
        if (ch == '~') escaped += "~0";
        else if (ch == '/') escaped += "~1";
        else escaped += ch;
    }
    return escaped;
}

std::string child_pointer(const std::string& pointer, std::string token) {
    token = bounded(std::move(token), kDiagnosticPointer);
    return bounded(pointer + "/" + pointer_token(std::move(token)), kDiagnosticPointer);
}

struct NumericMismatch {
    std::string pointer;
    std::string original;
    std::string adapted;
    std::string reason;
};

std::string numeric_text(const json& value) {
    if (value.is_string() && (value.tag() == jsoncons::semantic_tag::bigdec ||
            value.tag() == jsoncons::semantic_tag::bigint))
        return value.as<std::string>();
    return value.to_string();
}

bool native_number_equal(const json& left, const json& right) {
    auto is_number = [](const json& value) {
        return value.is_int64() || value.is_uint64() || value.is_double();
    };
    if (left.is_double() || right.is_double()) {
        if (!(is_number(left) && is_number(right))) return false;
        auto l = left.as<double>();
        auto r = right.as<double>();
        return std::isfinite(l) && std::isfinite(r) && l == r;
    }
    if (!(is_number(left) && is_number(right))) return false;
    std::pair<std::string, int64_t> left_key, right_key;
    return number_key(left, left_key) && number_key(right, right_key) && left_key == right_key;
}

bool decimal_candidate_decodes_to(std::string digits, int64_t exponent,
        bool negative, double expected) {
    if (negative) digits.insert(digits.begin(), '-');
    digits += "e" + std::to_string(exponent);
    try {
        json candidate = json::parse(digits, strict_options());
        if (!(candidate.is_int64() || candidate.is_uint64() || candidate.is_double()))
            return false;
        double decoded = candidate.as<double>();
        return std::isfinite(decoded) && decoded == expected;
    } catch (...) { return false; }
}

void increment_decimal_digits(std::string& digits) {
    for (auto it = digits.rbegin(); it != digits.rend(); ++it) {
        if (*it != '9') { ++*it; return; }
        *it = '0';
    }
    digits.insert(digits.begin(), '1');
}

// JSON producers are allowed to choose any shortest decimal that round-trips
// to a binary64 value. Python can choose a different member of that set from
// jsoncons, so comparing one serializer's spelling is too strict. A decimal is
// shortest exactly when neither adjacent decimal on the next-coarser digit
// grid decodes to the same binary64. Testing those two candidates avoids any
// serializer preference and runtime formatting dependency. Extra trailing
// zeroes have already been removed by decimal_key. This rejects decimals that
// merely collapse onto a shorter value (0.10000000000000001 -> 0.1), plus
// overflow and underflow to zero.
bool source_binary64_canonical(const json& source, const json& native) {
    if (!(source.is_string() && source.tag() == jsoncons::semantic_tag::bigdec))
        return numbers_equal(source, native);
    if (!native.is_double()) return false;
    double value = native.as<double>();
    if (!std::isfinite(value)) return false;
    std::pair<std::string, int64_t> source_key;
    if (!number_key(source, source_key)) return false;
    if (value == 0.0 && source_key.first != "0") return false;
    bool negative = source_key.first.front() == '-';
    std::string digits = negative ? source_key.first.substr(1) : source_key.first;
    if (digits.size() > static_cast<std::size_t>(std::numeric_limits<double>::max_digits10))
        return false;
    if (digits.size() <= 1) return true;
    std::string lower = digits.substr(0, digits.size() - 1);
    std::string upper = lower;
    increment_decimal_digits(upper);
    int64_t shorter_exponent = source_key.second + 1;
    return !decimal_candidate_decodes_to(lower, shorter_exponent, negative, value) &&
        !decimal_candidate_decodes_to(upper, shorter_exponent, negative, value);
}

// Python and Godot can spell one binary64 value differently: Python chooses a
// shortest round-trip decimal while Godot's full-precision writer can expose
// another digit. Accept that spelling-only change only when the source is a
// shortest binary64 decimal. This retains the rejection of genuinely
// over-precise source decimals and unsafe integers.
bool numbers_compatible(const json& original, const json& adapted,
        const json& original_native, const json& adapted_native,
        const std::string& pointer, NumericMismatch& mismatch) {
    std::pair<std::string, int64_t> left, right;
    bool left_number = number_key(original, left);
    bool right_number = number_key(adapted, right);
    if (left_number || right_number) {
        bool exact = left_number && right_number && left == right;
        bool source_canonical = left_number &&
            source_binary64_canonical(original, original_native);
        bool binary_same = left_number && right_number && source_canonical &&
            native_number_equal(original_native, adapted_native);
        if (godot_numeric_safe(original) && source_canonical && (exact || binary_same)) return true;
        mismatch = {pointer, bounded(numeric_text(original), kDiagnosticText),
            bounded(numeric_text(adapted), kDiagnosticText),
            !godot_numeric_safe(original) ? "unsafe_numeric_domain" :
                (!source_canonical ? "source_not_binary64_canonical" : "numeric_value_changed")};
        return false;
    }
    if (original.is_array() != adapted.is_array() || original.is_object() != adapted.is_object() ||
            original_native.is_array() != original.is_array() ||
            adapted_native.is_array() != adapted.is_array() ||
            original_native.is_object() != original.is_object() ||
            adapted_native.is_object() != adapted.is_object()) {
        mismatch = {pointer, "", "", "structure_changed"};
        return false;
    }
    if (original.is_array()) {
        if (original.size() != adapted.size() || original.size() != original_native.size() ||
                adapted.size() != adapted_native.size()) {
            mismatch = {pointer, "", "", "structure_changed"};
            return false;
        }
        for (std::size_t i = 0; i < original.size(); ++i) {
            if (!numbers_compatible(original[i], adapted[i], original_native[i], adapted_native[i],
                    child_pointer(pointer, std::to_string(i)), mismatch)) return false;
        }
        return true;
    }
    if (original.is_object()) {
        if (original.size() != adapted.size() || original.size() != original_native.size() ||
                adapted.size() != adapted_native.size()) {
            mismatch = {pointer, "", "", "structure_changed"};
            return false;
        }
        for (const auto& member : original.object_range()) {
            std::string key(member.key().data(), member.key().size());
            if (!adapted.contains(key) || !original_native.contains(key) || !adapted_native.contains(key)) {
                mismatch = {pointer, "", "", "structure_changed"};
                return false;
            }
            if (!numbers_compatible(member.value(), adapted.at(key), original_native.at(key),
                    adapted_native.at(key), child_pointer(pointer, key), mismatch)) return false;
        }
        return true;
    }
    return original == adapted;
}

uint64_t double_bits(double value) {
    static_assert(sizeof(double) == sizeof(uint64_t), "binary64 double required");
    uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

bool adjacent_binary64(double left, double right) {
    uint64_t left_bits = double_bits(left);
    uint64_t right_bits = double_bits(right);
    auto ordered = [](uint64_t bits) {
        return (bits & (uint64_t{1} << 63)) ? ~bits : bits | (uint64_t{1} << 63);
    };
    uint64_t left_ordered = ordered(left_bits);
    uint64_t right_ordered = ordered(right_bits);
    return left_ordered > right_ordered
        ? left_ordered - right_ordered == 1
        : right_ordered - left_ordered == 1;
}

json double_words(double value) {
    uint64_t bits = double_bits(value);
    json words(jsoncons::json_array_arg);
    // Strings survive the helper's own Godot JSON boundary without another
    // numeric conversion before the words are applied.
    words.push_back(std::to_string(static_cast<uint32_t>(bits)));
    words.push_back(std::to_string(static_cast<uint32_t>(bits >> 32)));
    return words;
}

// Godot's JSON decoder can round a valid decimal to the adjacent binary64
// value. Build a sparse overlay containing the source decoder's exact IEEE-754
// words for only those leaves. The raw JSON remains authoritative: unsafe or
// over-precise source numbers and all nonnumeric changes are still rejected.
bool application_corrections(const json& original, const json& adapted,
        const json& original_native, const json& adapted_native,
        const std::string& pointer, json& corrections, NumericMismatch& mismatch) {
    std::pair<std::string, int64_t> left, right;
    bool left_number = number_key(original, left);
    bool right_number = number_key(adapted, right);
    if (left_number || right_number) {
        bool source_canonical = left_number &&
            source_binary64_canonical(original, original_native);
        if (!(left_number && right_number) || !godot_numeric_safe(original) || !source_canonical) {
            mismatch = {pointer, bounded(numeric_text(original), kDiagnosticText),
                bounded(numeric_text(adapted), kDiagnosticText),
                !godot_numeric_safe(original) ? "unsafe_numeric_domain" :
                    (!source_canonical ? "source_not_binary64_canonical" : "numeric_type_changed")};
            return false;
        }
        if (native_number_equal(original_native, adapted_native)) {
            corrections = json::null();
            return true;
        }
        if (!original_native.is_double() || !adapted_native.is_double() ||
                !adjacent_binary64(original_native.as<double>(), adapted_native.as<double>())) {
            mismatch = {pointer, bounded(numeric_text(original), kDiagnosticText),
                bounded(numeric_text(adapted), kDiagnosticText), "numeric_value_changed"};
            return false;
        }
        corrections = double_words(original_native.as<double>());
        return true;
    }
    if (original.is_array() != adapted.is_array() || original.is_object() != adapted.is_object() ||
            original_native.is_array() != original.is_array() ||
            adapted_native.is_array() != adapted.is_array() ||
            original_native.is_object() != original.is_object() ||
            adapted_native.is_object() != adapted.is_object()) {
        mismatch = {pointer, "", "", "structure_changed"};
        return false;
    }
    if (original.is_array()) {
        if (original.size() != adapted.size() || original.size() != original_native.size() ||
                adapted.size() != adapted_native.size()) {
            mismatch = {pointer, "", "", "structure_changed"};
            return false;
        }
        json overlay(jsoncons::json_array_arg);
        bool changed = false;
        for (std::size_t i = 0; i < original.size(); ++i) {
            json child;
            if (!application_corrections(original[i], adapted[i], original_native[i], adapted_native[i],
                    child_pointer(pointer, std::to_string(i)), child, mismatch)) return false;
            changed = changed || !child.is_null();
            overlay.push_back(std::move(child));
        }
        corrections = changed ? std::move(overlay) : json::null();
        return true;
    }
    if (original.is_object()) {
        if (original.size() != adapted.size() || original.size() != original_native.size() ||
                adapted.size() != adapted_native.size()) {
            mismatch = {pointer, "", "", "structure_changed"};
            return false;
        }
        json overlay(jsoncons::json_object_arg);
        for (const auto& member : original.object_range()) {
            std::string key(member.key().data(), member.key().size());
            if (!adapted.contains(key) || !original_native.contains(key) || !adapted_native.contains(key)) {
                mismatch = {pointer, "", "", "structure_changed"};
                return false;
            }
            json child;
            if (!application_corrections(member.value(), adapted.at(key), original_native.at(key),
                    adapted_native.at(key), child_pointer(pointer, key), child, mismatch)) return false;
            if (!child.is_null()) overlay[key] = std::move(child);
        }
        corrections = overlay.empty() ? json::null() : std::move(overlay);
        return true;
    }
    if (original != adapted) {
        mismatch = {pointer, "", "", "value_changed"};
        return false;
    }
    corrections = json::null();
    return true;
}

bool has_tagged_numbers(const json& value) {
    if (value.is_string() && (value.tag() == jsoncons::semantic_tag::bigdec ||
            value.tag() == jsoncons::semantic_tag::bigint)) return true;
    if (value.is_array()) {
        for (const auto& child : value.array_range()) if (has_tagged_numbers(child)) return true;
    } else if (value.is_object()) {
        for (const auto& member : value.object_range()) if (has_tagged_numbers(member.value())) return true;
    }
    return false;
}

bool parse_without_numeric_loss(const std::string& raw, json& parsed) {
    json lossless = json::parse(raw, strict_options(true));
    try {
        parsed = json::parse(raw, strict_options());
        return !has_tagged_numbers(parsed) && numbers_equal(lossless, parsed);
    }
    catch (...) { return false; }
}

json resolver_from(const json& registry, const jsoncons::uri& uri) {
    auto key = uri.base().string();
    if (registry.is_object() && registry.contains(key) && registry.at(key).is_string())
        return json::parse(registry.at(key).as<std::string>(), strict_options());
    return json::null();
}

json compile_schema(const json& request, const json& id) {
    if (schemas.size() >= kMaxSchemas) return response(id, false, "schema_capacity", "compiled schema capacity reached");
    if (!request.contains("schema_raw") || !request.at("schema_raw").is_string())
        return response(id, false, "invalid_request", "schema_raw must be a string");
    std::string raw = request.at("schema_raw").as<std::string>();
    if (raw.size() > kSchemaBytes) return response(id, false, "schema_too_large", "schema exceeds 4 MiB");
    json schema;
    if (!parse_without_numeric_loss(raw, schema))
        return response(id, false, "unsupported_number", "schema contains a number that cannot be represented exactly");
    if (!godot_numeric_safe(schema))
        return response(id, false, "unsupported_number", "schema contains an integer outside the safe numeric domain");
    std::size_t nodes = 0;
    if (!within_shape(schema, 0, nodes)) return response(id, false, "schema_limit", "schema depth or node limit exceeded");
    const std::string dialect = schema.is_object()
        ? schema.get_value_or<std::string>("$schema", "https://json-schema.org/draft/2020-12/schema")
        : "https://json-schema.org/draft/2020-12/schema";
    if (dialect != "https://json-schema.org/draft/2020-12/schema" && dialect != "https://json-schema.org/draft/2020-12/schema#")
        return response(id, false, "unsupported_dialect", "only JSON Schema Draft 2020-12 is supported");

    auto meta_value = js::draft202012::schema_draft202012<json>::get_schema();
    auto meta = js::make_json_schema(meta_value);
    if (!meta.is_valid(schema)) return response(id, false, "invalid_schema", "schema does not satisfy the Draft 2020-12 meta-schema");

    json registry = request.get_value_or<json>("registry", json(jsoncons::json_object_arg));
    if (!registry.is_object()) return response(id, false, "invalid_registry", "registry must map URI to raw schema strings");
    std::size_t registry_bytes = 0;
    for (const auto& member : registry.object_range()) {
        if (!member.value().is_string()) return response(id, false, "invalid_registry", "registry values must be raw schema strings");
        std::string registered_raw = member.value().as<std::string>();
        registry_bytes += registered_raw.size();
        if (registry_bytes + raw.size() > kSchemaBytes)
            return response(id, false, "schema_too_large", "schema registry exceeds 4 MiB");
        json registered;
        if (!parse_without_numeric_loss(registered_raw, registered))
            return response(id, false, "unsupported_number", "registered schema contains an inexact number");
        if (!godot_numeric_safe(registered))
            return response(id, false, "unsupported_number", "registered schema contains an unsafe integer");
        const std::string registered_dialect = registered.is_object()
            ? registered.get_value_or<std::string>("$schema", "https://json-schema.org/draft/2020-12/schema")
            : "https://json-schema.org/draft/2020-12/schema";
        if (registered_dialect != "https://json-schema.org/draft/2020-12/schema" &&
                registered_dialect != "https://json-schema.org/draft/2020-12/schema#")
            return response(id, false, "unsupported_dialect", "registry resources must use Draft 2020-12");
        if (!within_shape(registered, 0, nodes) || !meta.is_valid(registered))
            return response(id, false, "invalid_schema", "registered schema is invalid Draft 2020-12");
    }
    auto resolver = [registry](const jsoncons::uri& uri) { return resolver_from(registry, uri); };
    auto compiled = std::make_unique<js::json_schema<json>>(js::make_json_schema(schema, resolver));
    uint64_t handle = next_handle++;
    schemas.emplace(handle, Entry{std::move(raw), std::move(compiled)});
    json out = response(id, true);
    out["handle"] = handle;
    return out;
}

json validate_instance(const json& request, const json& id) {
    uint64_t handle = request.get_value_or<uint64_t>("handle", 0);
    auto found = schemas.find(handle);
    if (found == schemas.end()) return response(id, false, "invalid_handle", "schema handle is unavailable");
    if (!request.contains("instance_raw") || !request.at("instance_raw").is_string())
        return response(id, false, "invalid_request", "instance_raw must be a string");
    std::string raw = request.at("instance_raw").as<std::string>();
    if (raw.size() > kInstanceBytes) return response(id, false, "instance_too_large", "instance exceeds 32 MiB");
    json instance;
    if (!parse_without_numeric_loss(raw, instance))
        return response(id, false, "unsupported_number", "instance contains a number that cannot be represented exactly");
    if (!godot_numeric_safe(instance))
        return response(id, false, "unsupported_number", "instance contains an integer outside the safe numeric domain");
    std::size_t nodes = 0;
    if (!within_shape(instance, 0, nodes)) return response(id, false, "instance_limit", "instance depth or node limit exceeded");
    json out = response(id, true);
    out["valid"] = found->second.compiled->is_valid(instance);
    out["godot_numeric_safe"] = godot_numeric_safe(instance);
    return out;
}

json dispatch(const json& request) {
    json id = request.is_object() && request.contains("id") ? request.at("id") : json::null();
    if (!request.is_object() || !request.contains("op") || !request.at("op").is_string())
        return response(id, false, "invalid_request", "op must be a string");
    std::string op = request.at("op").as<std::string>();
    if (op == "compile") return compile_schema(request, id);
    if (op == "validate") return validate_instance(request, id);
    if (op == "release") {
        schemas.erase(request.get_value_or<uint64_t>("handle", 0));
        return response(id, true);
    }
    if (op == "ping") return response(id, true);
    if (op == "compare_numbers") {
        if (!request.contains("original_raw") || !request.contains("adapted_raw") ||
                !request.at("original_raw").is_string() || !request.at("adapted_raw").is_string())
            return response(id, false, "invalid_request", "raw values must be strings");
        auto options = strict_options(true);
        json original = json::parse(request.at("original_raw").as<std::string>(), options);
        json adapted = json::parse(request.at("adapted_raw").as<std::string>(), options);
        json original_native = json::parse(
            request.at("original_raw").as<std::string>(), strict_options());
        json adapted_native = json::parse(
            request.at("adapted_raw").as<std::string>(), strict_options());
        bool equal = false;
        NumericMismatch mismatch;
        try {
            equal = numbers_compatible(original, adapted, original_native, adapted_native, "", mismatch);
        } catch (...) { equal = false; }
        if (!equal) {
            json out = response(id, false, "unsupported_number",
                "number cannot cross the application boundary exactly");
            json details(jsoncons::json_object_arg);
            details["pointer"] = bounded(mismatch.pointer, kDiagnosticPointer);
            details["original"] = bounded(mismatch.original, kDiagnosticText);
            details["adapted"] = bounded(mismatch.adapted, kDiagnosticText);
            details["reason"] = bounded(mismatch.reason, kDiagnosticText);
            out["error"]["details"] = std::move(details);
            return out;
        }
        return response(id, true);
    }
    if (op == "prepare_numbers") {
        if (!request.contains("original_raw") || !request.contains("adapted_raw") ||
                !request.at("original_raw").is_string() || !request.at("adapted_raw").is_string())
            return response(id, false, "invalid_request", "raw values must be strings");
        const std::string original_raw = request.at("original_raw").as<std::string>();
        const std::string adapted_raw = request.at("adapted_raw").as<std::string>();
        if (original_raw.size() > kInstanceBytes || adapted_raw.size() > kInstanceBytes)
            return response(id, false, "instance_too_large", "application value exceeds 32 MiB");
        auto options = strict_options(true);
        json original = json::parse(original_raw, options);
        json adapted = json::parse(adapted_raw, options);
        json original_native = json::parse(original_raw, strict_options());
        json adapted_native = json::parse(adapted_raw, strict_options());
        std::size_t nodes = 0;
        if (!within_shape(original, 0, nodes))
            return response(id, false, "instance_limit", "source depth or node limit exceeded");
        nodes = 0;
        if (!within_shape(adapted, 0, nodes))
            return response(id, false, "instance_limit", "decoded value depth or node limit exceeded");
        json corrections;
        NumericMismatch mismatch;
        bool compatible = false;
        try {
            compatible = application_corrections(original, adapted, original_native,
                adapted_native, "", corrections, mismatch);
        } catch (...) { compatible = false; }
        if (!compatible) {
            json out = response(id, false, "unsupported_number",
                "number cannot cross the application boundary safely");
            json details(jsoncons::json_object_arg);
            details["pointer"] = bounded(mismatch.pointer, kDiagnosticPointer);
            details["original"] = bounded(mismatch.original, kDiagnosticText);
            details["adapted"] = bounded(mismatch.adapted, kDiagnosticText);
            details["reason"] = bounded(mismatch.reason, kDiagnosticText);
            out["error"]["details"] = std::move(details);
            return out;
        }
        json out = response(id, true);
        out["corrections"] = std::move(corrections);
        return out;
    }
    return response(id, false, "unknown_operation", "unknown helper operation");
}

bool read_request_line(std::string& line, bool& oversized) {
    line.clear();
    oversized = false;
    char ch;
    bool saw_input = false;
    while (std::cin.get(ch)) {
        saw_input = true;
        if (ch == '\n') break;
        if (line.size() < kRequestBytes) line.push_back(ch);
        else oversized = true;
    }
    return saw_input;
}
} // namespace

int main() {
    std::ios::sync_with_stdio(false);
    std::string line;
    bool oversized = false;
    while (read_request_line(line, oversized)) {
        if (oversized) {
            std::cout << response(json::null(), false, "request_too_large", "request line exceeds limit") << '\n';
        } else try {
            json request = json::parse(line, strict_options());
            try {
                std::cout << dispatch(request) << '\n';
            } catch (const std::exception& error) {
                json id = request.is_object() && request.contains("id") ? request.at("id") : json::null();
                if (std::string(error.what()).find("[minerva_unsupported_number]") != std::string::npos) {
                    std::cout << response(id, false, "unsupported_number",
                        "multipleOf must be a safe-range integer") << '\n';
                    std::cout.flush();
                    continue;
                }
                if (std::string(error.what()).find("[minerva_invalid_schema]") != std::string::npos) {
                    std::cout << response(id, false, "invalid_schema", "multipleOf must be positive") << '\n';
                    std::cout.flush();
                    continue;
                }
                std::cout << response(id, false, "operation_failed", "schema compilation or validation failed") << '\n';
            }
        } catch (const std::exception&) {
            std::cout << response(json::null(), false, "invalid_json", "request could not be parsed or processed") << '\n';
        }
        std::cout.flush();
    }
    return 0;
}
