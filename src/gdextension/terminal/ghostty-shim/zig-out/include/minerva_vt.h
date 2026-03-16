/**
 * minerva_vt.h - Minerva terminal shim over libghostty-vt
 *
 * Provides C-callable functions for terminal lifecycle, cell-level access,
 * cursor state, and screen content extraction. Built on top of ghostty-vt's
 * Zig internals.
 */

#ifndef MINERVA_VT_H
#define MINERVA_VT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a terminal instance */
typedef void* MinervaTerminal;

/* Color type tag */
typedef enum {
    MINERVA_COLOR_NONE = 0,
    MINERVA_COLOR_PALETTE = 1,
    MINERVA_COLOR_RGB = 2,
} MinervaColorType;

/* Color value */
typedef struct {
    MinervaColorType type;
    uint8_t r, g, b;       /* RGB values (valid when type == RGB, or resolved from palette) */
    uint8_t palette_index;  /* palette index (valid when type == PALETTE) */
} MinervaColor;

/* Wide character state */
typedef enum {
    MINERVA_WIDE_NARROW = 0,
    MINERVA_WIDE_WIDE = 1,
    MINERVA_WIDE_SPACER_HEAD = 2,
    MINERVA_WIDE_SPACER_TAIL = 3,
} MinervaWide;

/* Cell information returned by minerva_vt_get_cell */
typedef struct {
    uint32_t codepoint;     /* Unicode codepoint (0 = empty cell) */
    MinervaColor fg;        /* Foreground color */
    MinervaColor bg;        /* Background color */
    MinervaWide wide;       /* Wide character state */
    bool bold;
    bool italic;
    bool faint;
    bool strikethrough;
    bool inverse;
    bool blink;
    bool overline;
    bool invisible;
    uint8_t underline;      /* 0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed */
    bool has_style;         /* true if cell has non-default style */
} MinervaCellInfo;

/* Cursor information */
typedef struct {
    uint16_t x;
    uint16_t y;
    bool visible;
    uint8_t style;          /* 0=block, 1=bar, 2=underline */
} MinervaCursorInfo;

/**
 * Create a new terminal with the given dimensions.
 * Returns NULL on failure.
 */
MinervaTerminal minerva_vt_new(uint16_t cols, uint16_t rows);

/**
 * Destroy a terminal and free all associated memory.
 */
void minerva_vt_free(MinervaTerminal term);

/**
 * Feed raw bytes (from PTY output) into the terminal for processing.
 * The terminal parses VT sequences and updates its internal state.
 */
void minerva_vt_write(MinervaTerminal term, const uint8_t* data, size_t len);

/**
 * Resize the terminal to new dimensions.
 * Returns true on success, false on failure.
 */
bool minerva_vt_resize(MinervaTerminal term, uint16_t cols, uint16_t rows);

/**
 * Get the current terminal dimensions.
 */
void minerva_vt_get_size(MinervaTerminal term, uint16_t* cols, uint16_t* rows);

/**
 * Get cell information at (col, row) in the active screen.
 * Returns true if the cell was retrieved, false if out of bounds.
 */
bool minerva_vt_get_cell(MinervaTerminal term, uint16_t col, uint16_t row, MinervaCellInfo* out);

/**
 * Get current cursor state.
 */
void minerva_vt_get_cursor(MinervaTerminal term, MinervaCursorInfo* out);

/**
 * Get a plain text representation of the current screen content.
 * Caller must free the returned string with minerva_vt_free_string().
 * Returns NULL on failure.
 */
char* minerva_vt_plain_string(MinervaTerminal term);

/**
 * Free a string returned by minerva_vt_plain_string().
 */
void minerva_vt_free_string(char* str);

/**
 * Scroll the viewport by the given number of lines.
 * Positive = scroll up (show scrollback), negative = scroll down.
 * Pass 0 to reset to bottom.
 */
void minerva_vt_scroll_viewport(MinervaTerminal term, int32_t lines);

/* ── Key encoding (ghostty key encoder) ─────────────────────────────── */

/**
 * Key action values (matches GhosttyKeyAction).
 */
#define MINERVA_KEY_ACTION_RELEASE 0
#define MINERVA_KEY_ACTION_PRESS   1
#define MINERVA_KEY_ACTION_REPEAT  2

/**
 * Modifier bitmask values (matches GhosttyMods).
 */
#define MINERVA_MODS_SHIFT     (1 << 0)
#define MINERVA_MODS_CTRL      (1 << 1)
#define MINERVA_MODS_ALT       (1 << 2)
#define MINERVA_MODS_SUPER     (1 << 3)
#define MINERVA_MODS_CAPS_LOCK (1 << 4)
#define MINERVA_MODS_NUM_LOCK  (1 << 5)

/**
 * Physical key codes (matches GhosttyKey enum values).
 * Only the subset used by Minerva is listed here.
 */
typedef enum {
    MINERVA_KEY_UNIDENTIFIED = 0,
    /* Writing System Keys */
    MINERVA_KEY_BACKQUOTE,
    MINERVA_KEY_BACKSLASH,
    MINERVA_KEY_BRACKET_LEFT,
    MINERVA_KEY_BRACKET_RIGHT,
    MINERVA_KEY_COMMA,
    MINERVA_KEY_DIGIT_0,
    MINERVA_KEY_DIGIT_1,
    MINERVA_KEY_DIGIT_2,
    MINERVA_KEY_DIGIT_3,
    MINERVA_KEY_DIGIT_4,
    MINERVA_KEY_DIGIT_5,
    MINERVA_KEY_DIGIT_6,
    MINERVA_KEY_DIGIT_7,
    MINERVA_KEY_DIGIT_8,
    MINERVA_KEY_DIGIT_9,
    MINERVA_KEY_EQUAL,
    MINERVA_KEY_INTL_BACKSLASH,
    MINERVA_KEY_INTL_RO,
    MINERVA_KEY_INTL_YEN,
    MINERVA_KEY_A,
    MINERVA_KEY_B,
    MINERVA_KEY_C,
    MINERVA_KEY_D,
    MINERVA_KEY_E,
    MINERVA_KEY_F,
    MINERVA_KEY_G,
    MINERVA_KEY_H,
    MINERVA_KEY_I,
    MINERVA_KEY_J,
    MINERVA_KEY_K,
    MINERVA_KEY_L,
    MINERVA_KEY_M,
    MINERVA_KEY_N,
    MINERVA_KEY_O,
    MINERVA_KEY_P,
    MINERVA_KEY_Q,
    MINERVA_KEY_R,
    MINERVA_KEY_S,
    MINERVA_KEY_T,
    MINERVA_KEY_U,
    MINERVA_KEY_V,
    MINERVA_KEY_W,
    MINERVA_KEY_X,
    MINERVA_KEY_Y,
    MINERVA_KEY_Z,
    MINERVA_KEY_MINUS,
    MINERVA_KEY_PERIOD,
    MINERVA_KEY_QUOTE,
    MINERVA_KEY_SEMICOLON,
    MINERVA_KEY_SLASH,
    /* Functional Keys */
    MINERVA_KEY_ALT_LEFT,
    MINERVA_KEY_ALT_RIGHT,
    MINERVA_KEY_BACKSPACE,
    MINERVA_KEY_CAPS_LOCK,
    MINERVA_KEY_CONTEXT_MENU,
    MINERVA_KEY_CONTROL_LEFT,
    MINERVA_KEY_CONTROL_RIGHT,
    MINERVA_KEY_ENTER,
    MINERVA_KEY_META_LEFT,
    MINERVA_KEY_META_RIGHT,
    MINERVA_KEY_SHIFT_LEFT,
    MINERVA_KEY_SHIFT_RIGHT,
    MINERVA_KEY_SPACE,
    MINERVA_KEY_TAB,
    MINERVA_KEY_CONVERT,
    MINERVA_KEY_KANA_MODE,
    MINERVA_KEY_NON_CONVERT,
    /* Control Pad */
    MINERVA_KEY_DELETE,
    MINERVA_KEY_END,
    MINERVA_KEY_HELP,
    MINERVA_KEY_HOME,
    MINERVA_KEY_INSERT,
    MINERVA_KEY_PAGE_DOWN,
    MINERVA_KEY_PAGE_UP,
    /* Arrow Pad */
    MINERVA_KEY_ARROW_DOWN,
    MINERVA_KEY_ARROW_LEFT,
    MINERVA_KEY_ARROW_RIGHT,
    MINERVA_KEY_ARROW_UP,
    /* Numpad */
    MINERVA_KEY_NUM_LOCK,
    MINERVA_KEY_NUMPAD_0,
    MINERVA_KEY_NUMPAD_1,
    MINERVA_KEY_NUMPAD_2,
    MINERVA_KEY_NUMPAD_3,
    MINERVA_KEY_NUMPAD_4,
    MINERVA_KEY_NUMPAD_5,
    MINERVA_KEY_NUMPAD_6,
    MINERVA_KEY_NUMPAD_7,
    MINERVA_KEY_NUMPAD_8,
    MINERVA_KEY_NUMPAD_9,
    MINERVA_KEY_NUMPAD_ADD,
    MINERVA_KEY_NUMPAD_BACKSPACE,
    MINERVA_KEY_NUMPAD_CLEAR,
    MINERVA_KEY_NUMPAD_CLEAR_ENTRY,
    MINERVA_KEY_NUMPAD_COMMA,
    MINERVA_KEY_NUMPAD_DECIMAL,
    MINERVA_KEY_NUMPAD_DIVIDE,
    MINERVA_KEY_NUMPAD_ENTER,
    MINERVA_KEY_NUMPAD_EQUAL,
    MINERVA_KEY_NUMPAD_MEMORY_ADD,
    MINERVA_KEY_NUMPAD_MEMORY_CLEAR,
    MINERVA_KEY_NUMPAD_MEMORY_RECALL,
    MINERVA_KEY_NUMPAD_MEMORY_STORE,
    MINERVA_KEY_NUMPAD_MEMORY_SUBTRACT,
    MINERVA_KEY_NUMPAD_MULTIPLY,
    MINERVA_KEY_NUMPAD_PAREN_LEFT,
    MINERVA_KEY_NUMPAD_PAREN_RIGHT,
    MINERVA_KEY_NUMPAD_SUBTRACT,
    MINERVA_KEY_NUMPAD_SEPARATOR,
    MINERVA_KEY_NUMPAD_UP,
    MINERVA_KEY_NUMPAD_DOWN,
    MINERVA_KEY_NUMPAD_RIGHT,
    MINERVA_KEY_NUMPAD_LEFT,
    MINERVA_KEY_NUMPAD_BEGIN,
    MINERVA_KEY_NUMPAD_HOME,
    MINERVA_KEY_NUMPAD_END,
    MINERVA_KEY_NUMPAD_INSERT,
    MINERVA_KEY_NUMPAD_DELETE,
    MINERVA_KEY_NUMPAD_PAGE_UP,
    MINERVA_KEY_NUMPAD_PAGE_DOWN,
    /* Function Keys */
    MINERVA_KEY_ESCAPE,
    MINERVA_KEY_F1,
    MINERVA_KEY_F2,
    MINERVA_KEY_F3,
    MINERVA_KEY_F4,
    MINERVA_KEY_F5,
    MINERVA_KEY_F6,
    MINERVA_KEY_F7,
    MINERVA_KEY_F8,
    MINERVA_KEY_F9,
    MINERVA_KEY_F10,
    MINERVA_KEY_F11,
    MINERVA_KEY_F12,
    MINERVA_KEY_F13,
    MINERVA_KEY_F14,
    MINERVA_KEY_F15,
    MINERVA_KEY_F16,
    MINERVA_KEY_F17,
    MINERVA_KEY_F18,
    MINERVA_KEY_F19,
    MINERVA_KEY_F20,
    MINERVA_KEY_F21,
    MINERVA_KEY_F22,
    MINERVA_KEY_F23,
    MINERVA_KEY_F24,
    MINERVA_KEY_F25,
} MinervaKey;

/**
 * Encode a key event into a terminal escape sequence using ghostty's key encoder.
 * The encoding is terminal-mode-aware (responds to DEC cursor key mode, kitty protocol, etc.).
 *
 * @param term      Terminal handle (for reading current modes)
 * @param key_code  Physical key code (MinervaKey enum value)
 * @param action    Key action (MINERVA_KEY_ACTION_PRESS/RELEASE/REPEAT)
 * @param mods      Modifier bitmask (MINERVA_MODS_*)
 * @param utf8      Optional UTF-8 text generated by the key (NULL if none)
 * @param utf8_len  Length of utf8 in bytes
 * @param out_buf   Buffer to write encoded sequence into
 * @param out_buf_size  Size of out_buf in bytes (128 is recommended)
 * @return Number of bytes written, or 0 if no output / error
 */
size_t minerva_vt_encode_key(
    MinervaTerminal term,
    int key_code,
    int action,
    uint16_t mods,
    const uint8_t* utf8,
    size_t utf8_len,
    uint8_t* out_buf,
    size_t out_buf_size
);

#ifdef __cplusplus
}
#endif

#endif /* MINERVA_VT_H */
