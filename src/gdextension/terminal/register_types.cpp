#include "register_types.h"

#ifdef PLATFORM_WINDOWS
    #include "windows/terminal.h"
#endif

#ifdef PLATFORM_LINUX
    #include "unix/terminal.h"
#endif

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_terminal_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    #ifdef PLATFORM_WINDOWS
        ClassDB::register_class<WindowsTerminal>();
    #endif

    #ifdef PLATFORM_LINUX
        ClassDB::register_class<LinuxTerminal>();
    #endif
}

void uninitialize_terminal_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
    // Initialization.
    GDExtensionBool GDE_EXPORT terminal_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, 
                                                    const GDExtensionClassLibraryPtr p_library, 
                                                    GDExtensionInitialization *r_initialization) {
        godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

        init_obj.register_initializer(initialize_terminal_module);
        init_obj.register_terminator(uninitialize_terminal_module);
        init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

        return init_obj.init();
    }
}