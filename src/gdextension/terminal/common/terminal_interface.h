#ifndef TERMINAL_INTERFACE_H
#define TERMINAL_INTERFACE_H

#include <godot_cpp/classes/node.hpp>

namespace godot {

// Pure C++ interface - no GDCLASS registration needed for abstract base
class TerminalInterface : public Node {
public:
    virtual bool start(int width = 100, int height = 100) = 0;
    virtual bool resize(int width, int height) = 0;
    virtual void stop() = 0;
    virtual bool write_input(const String &input) = 0;
    virtual bool is_running() const = 0;

    virtual ~TerminalInterface() = default;
};

}

#endif // TERMINAL_INTERFACE_H