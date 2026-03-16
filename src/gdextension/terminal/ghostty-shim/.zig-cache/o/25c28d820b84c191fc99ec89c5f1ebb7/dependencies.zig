pub const packages = struct {
    pub const @"../../../../vendor/ghostty" = struct {
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty";
        pub const build_zig = @import("../../../../vendor/ghostty");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "libxev", "libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs" },
            .{ "vaxis", "vaxis-0.5.1-BWNV_LosCQAGmCCNOLljCIw6j6-yt53tji6n6rwJ2BhS" },
            .{ "z2d", "z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ" },
            .{ "zig_objc", "zig_objc-0.0.0-Ir_Sp5gTAQCvxxR7oVIrPXxXwsfKgVP7_wqoOQrZjFeK" },
            .{ "zig_js", "zig_js-0.0.0-rjCAV-6GAADxFug7rDmPH-uM_XcnJ5NmuAMJCAscMjhi" },
            .{ "uucode", "uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9" },
            .{ "zig_wayland", "wayland-0.5.0-dev-lQa1khrMAQDJDwYFKpdH3HizherB7sHo5dKMECfvxQHe" },
            .{ "zf", "zf-0.10.3-OIRy8RuJAACKA3Lohoumrt85nRbHwbpMcUaLES8vxDnh" },
            .{ "gobject", "gobject-0.3.0-Skun7ANLnwDvEfIpVmohcppXgOvg_I6YOJFmPIsKfXk-" },
            .{ "dcimgui", "../../../../vendor/ghostty/pkg/dcimgui" },
            .{ "fontconfig", "../../../../vendor/ghostty/pkg/fontconfig" },
            .{ "freetype", "../../../../vendor/ghostty/pkg/freetype" },
            .{ "gtk4_layer_shell", "../../../../vendor/ghostty/pkg/gtk4-layer-shell" },
            .{ "harfbuzz", "../../../../vendor/ghostty/pkg/harfbuzz" },
            .{ "highway", "../../../../vendor/ghostty/pkg/highway" },
            .{ "libintl", "../../../../vendor/ghostty/pkg/libintl" },
            .{ "libpng", "../../../../vendor/ghostty/pkg/libpng" },
            .{ "macos", "../../../../vendor/ghostty/pkg/macos" },
            .{ "oniguruma", "../../../../vendor/ghostty/pkg/oniguruma" },
            .{ "opengl", "../../../../vendor/ghostty/pkg/opengl" },
            .{ "sentry", "../../../../vendor/ghostty/pkg/sentry" },
            .{ "simdutf", "../../../../vendor/ghostty/pkg/simdutf" },
            .{ "utfcpp", "../../../../vendor/ghostty/pkg/utfcpp" },
            .{ "wuffs", "../../../../vendor/ghostty/pkg/wuffs" },
            .{ "zlib", "../../../../vendor/ghostty/pkg/zlib" },
            .{ "glslang", "../../../../vendor/ghostty/pkg/glslang" },
            .{ "spirv_cross", "../../../../vendor/ghostty/pkg/spirv-cross" },
            .{ "wayland", "N-V-__8AAKrHGAAs2shYq8UkE6bGcR1QJtLTyOE_lcosMn6t" },
            .{ "wayland_protocols", "N-V-__8AAKw-DAAaV8bOAAGqA0-oD7o-HNIlPFYKRXSPT03S" },
            .{ "plasma_wayland_protocols", "N-V-__8AAKYZBAB-CFHBKs3u4JkeiT4BMvyHu3Y5aaWF3Bbs" },
            .{ "jetbrains_mono", "N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x" },
            .{ "nerd_fonts_symbols_only", "N-V-__8AAMVLTABmYkLqhZPLXnMl-KyN38R8UVYqGrxqO26s" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
            .{ "android_ndk", "../../../../vendor/ghostty/pkg/android-ndk" },
            .{ "iterm2_themes", "N-V-__8AABVbAwBwDRyZONfx553tvMW8_A2OKUoLzPUSRiLF" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/android-ndk" = struct {
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/android-ndk";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/android-ndk");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/apple-sdk" = struct {
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/apple-sdk";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/apple-sdk");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/breakpad" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/breakpad";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/breakpad");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "breakpad", "N-V-__8AALw2uwF_03u4JRkZwRLc3Y9hakkYV7NKRR9-RIZJ" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/dcimgui" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/dcimgui";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/dcimgui");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "bindings", "N-V-__8AANT61wB--nJ95Gj_ctmzAtcjloZ__hRqNw5lC1Kr" },
            .{ "imgui", "N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
            .{ "freetype", "../../../../vendor/ghostty/pkg/freetype" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/fontconfig" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/fontconfig";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/fontconfig");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "fontconfig", "N-V-__8AAIrfdwARSa-zMmxWwFuwpXf1T3asIN7s5jqi9c1v" },
            .{ "freetype", "../../../../vendor/ghostty/pkg/freetype" },
            .{ "libxml2", "../../../../vendor/ghostty/pkg/libxml2" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/freetype" = struct {
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/freetype";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/freetype");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "freetype", "N-V-__8AAKLKpwC4H27Ps_0iL3bPkQb-z6ZVSrB-x_3EEkub" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
            .{ "libpng", "../../../../vendor/ghostty/pkg/libpng" },
            .{ "zlib", "../../../../vendor/ghostty/pkg/zlib" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/glslang" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/glslang";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/glslang");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "glslang", "N-V-__8AABzkUgISeKGgXAzgtutgJsZc0-kkeqBBscJgMkvy" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/gtk4-layer-shell" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/gtk4-layer-shell";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/gtk4-layer-shell");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "gtk4_layer_shell", "N-V-__8AALiNBAA-_0gprYr92CjrMj1I5bqNu0TSJOnjFNSr" },
            .{ "wayland_protocols", "N-V-__8AAKw-DAAaV8bOAAGqA0-oD7o-HNIlPFYKRXSPT03S" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/harfbuzz" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/harfbuzz";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/harfbuzz");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "harfbuzz", "N-V-__8AAG02ugUcWec-Ndp-i7JTsJ0dgF8nnJRUInkGLG7G" },
            .{ "freetype", "../../../../vendor/ghostty/pkg/freetype" },
            .{ "macos", "../../../../vendor/ghostty/pkg/macos" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/highway" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/highway";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/highway");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "highway", "N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
            .{ "android_ndk", "../../../../vendor/ghostty/pkg/android-ndk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/libintl" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/libintl";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/libintl");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "gettext", "N-V-__8AADcZkgn4cMhTUpIz6mShCKyqqB-NBtf_S2bHaTC-" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/libpng" = struct {
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/libpng";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/libpng");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "libpng", "N-V-__8AAJrvXQCqAT8Mg9o_tk6m0yf5Fz-gCNEOKLyTSerD" },
            .{ "zlib", "../../../../vendor/ghostty/pkg/zlib" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/libxml2" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/libxml2";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/libxml2");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "libxml2", "N-V-__8AAG3RoQEyRC2Vw7Qoro5SYBf62IHn3HjqtNVY6aWK" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/macos" = struct {
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/macos";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/macos");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/oniguruma" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/oniguruma";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/oniguruma");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "oniguruma", "N-V-__8AAHjwMQDBXnLq3Q2QhaivE0kE2aD138vtX2Bq1g7c" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/opengl" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/opengl";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/opengl");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"../../../../vendor/ghostty/pkg/sentry" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/sentry";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/sentry");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "sentry", "N-V-__8AAPlZGwBEa-gxrcypGBZ2R8Bse4JYSfo_ul8i2jlG" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
            .{ "breakpad", "../../../../vendor/ghostty/pkg/breakpad" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/simdutf" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/simdutf";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/simdutf");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
            .{ "android_ndk", "../../../../vendor/ghostty/pkg/android-ndk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/spirv-cross" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/spirv-cross";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/spirv-cross");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "spirv_cross", "N-V-__8AANb6pwD7O1WG6L5nvD_rNMvnSc9Cpg1ijSlTYywv" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/utfcpp" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/utfcpp";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/utfcpp");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "utfcpp", "N-V-__8AAHffAgDU0YQmynL8K35WzkcnMUmBVQHQ0jlcKpjH" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
            .{ "android_ndk", "../../../../vendor/ghostty/pkg/android-ndk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/wuffs" = struct {
        pub const available = true;
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/wuffs";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/wuffs");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "wuffs", "N-V-__8AAAzZywE3s51XfsLbP9eyEw57ae9swYB9aGB6fCMs" },
            .{ "pixels", "N-V-__8AADYiAAB_80AWnH1AxXC0tql9thT-R-DYO1gBqTLc" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"../../../../vendor/ghostty/pkg/zlib" = struct {
        pub const build_root = "/Users/ipeerbhai/github/Minerva/src/gdextension/terminal/ghostty-shim/../../../../vendor/ghostty/pkg/zlib";
        pub const build_zig = @import("../../../../vendor/ghostty/pkg/zlib");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zlib", "N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o" },
            .{ "apple_sdk", "../../../../vendor/ghostty/pkg/apple-sdk" },
        };
    };
    pub const @"N-V-__8AAAzZywE3s51XfsLbP9eyEw57ae9swYB9aGB6fCMs" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AABVbAwBwDRyZONfx553tvMW8_A2OKUoLzPUSRiLF" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AABzkUgISeKGgXAzgtutgJsZc0-kkeqBBscJgMkvy" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AADYiAAB_80AWnH1AxXC0tql9thT-R-DYO1gBqTLc" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AADcZkgn4cMhTUpIz6mShCKyqqB-NBtf_S2bHaTC-" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAG02ugUcWec-Ndp-i7JTsJ0dgF8nnJRUInkGLG7G" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAG3RoQEyRC2Vw7Qoro5SYBf62IHn3HjqtNVY6aWK" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAHffAgDU0YQmynL8K35WzkcnMUmBVQHQ0jlcKpjH" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAHjwMQDBXnLq3Q2QhaivE0kE2aD138vtX2Bq1g7c" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAIrfdwARSa-zMmxWwFuwpXf1T3asIN7s5jqi9c1v" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAJrvXQCqAT8Mg9o_tk6m0yf5Fz-gCNEOKLyTSerD" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAKLKpwC4H27Ps_0iL3bPkQb-z6ZVSrB-x_3EEkub" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAKYZBAB-CFHBKs3u4JkeiT4BMvyHu3Y5aaWF3Bbs" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAKrHGAAs2shYq8UkE6bGcR1QJtLTyOE_lcosMn6t" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAKw-DAAaV8bOAAGqA0-oD7o-HNIlPFYKRXSPT03S" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AALiNBAA-_0gprYr92CjrMj1I5bqNu0TSJOnjFNSr" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AALw2uwF_03u4JRkZwRLc3Y9hakkYV7NKRR9-RIZJ" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAMVLTABmYkLqhZPLXnMl-KyN38R8UVYqGrxqO26s" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AANT61wB--nJ95Gj_ctmzAtcjloZ__hRqNw5lC1Kr" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AANb6pwD7O1WG6L5nvD_rNMvnSc9Cpg1ijSlTYywv" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAPlZGwBEa-gxrcypGBZ2R8Bse4JYSfo_ul8i2jlG" = struct {
        pub const available = false;
    };
    pub const @"gobject-0.3.0-Skun7ANLnwDvEfIpVmohcppXgOvg_I6YOJFmPIsKfXk-" = struct {
        pub const available = false;
    };
    pub const @"libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs" = struct {
        pub const available = false;
    };
    pub const @"uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9" = struct {
        pub const build_root = "/Users/ipeerbhai/.cache/zig/p/uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9";
        pub const build_zig = @import("uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"vaxis-0.5.1-BWNV_LosCQAGmCCNOLljCIw6j6-yt53tji6n6rwJ2BhS" = struct {
        pub const available = false;
    };
    pub const @"wayland-0.5.0-dev-lQa1khrMAQDJDwYFKpdH3HizherB7sHo5dKMECfvxQHe" = struct {
        pub const available = false;
    };
    pub const @"z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ" = struct {
        pub const available = false;
    };
    pub const @"zf-0.10.3-OIRy8RuJAACKA3Lohoumrt85nRbHwbpMcUaLES8vxDnh" = struct {
        pub const available = false;
    };
    pub const @"zig_js-0.0.0-rjCAV-6GAADxFug7rDmPH-uM_XcnJ5NmuAMJCAscMjhi" = struct {
        pub const available = false;
    };
    pub const @"zig_objc-0.0.0-Ir_Sp5gTAQCvxxR7oVIrPXxXwsfKgVP7_wqoOQrZjFeK" = struct {
        pub const available = false;
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "ghostty", "../../../../vendor/ghostty" },
};
