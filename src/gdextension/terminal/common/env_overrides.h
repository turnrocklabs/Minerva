#ifndef MINERVA_ENV_OVERRIDES_H
#define MINERVA_ENV_OVERRIDES_H

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

// Environment entries a SubProcess adds for its child only
// (SubProcess.start_with_env): each name non-empty with no '=' and no NUL,
// each value with no NUL, all strings. Returns false, filling nothing, for
// anything else; names are not compared here (platforms differ in case).
inline bool minerva_env_overrides(const godot::Dictionary &extra_env,
        std::vector<std::pair<std::string, std::string>> &out)
{
    out.clear();
    godot::Array keys = extra_env.keys();
    for (int i = 0; i < keys.size(); ++i) {
        if (keys[i].get_type() != godot::Variant::STRING
                || extra_env[keys[i]].get_type() != godot::Variant::STRING) {
            out.clear();
            return false;
        }
        godot::CharString name = godot::String(keys[i]).utf8();
        godot::CharString value = godot::String(extra_env[keys[i]]).utf8();
        const size_t name_length = static_cast<size_t>(name.length());
        const size_t value_length = static_cast<size_t>(value.length());
        if (name_length == 0 || std::strlen(name.get_data()) != name_length
                || std::strchr(name.get_data(), '=') != nullptr
                || std::strlen(value.get_data()) != value_length) {
            out.clear();
            return false;
        }
        out.emplace_back(std::string(name.get_data(), name_length),
                std::string(value.get_data(), value_length));
    }
    return true;
}

#endif
