// vtreplay — replay a PTY byte capture through Minerva's own VT engine
// (libminerva-vt / libghostty-vt) and dump screen rows exactly as
// TerminalSession.extract_row_text_screen does: cells < 32 -> space,
// row right-trimmed of spaces, rows joined by \n.
//
// Usage: vtreplay <cols> <rows> <file> [--poll <bytes>]
//   default: feed everything, print final screen rows.
//   --poll N: feed in N-byte chunks and print a snapshot block per chunk.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <minerva_vt.h>

#define MAXCOLS 512

// Mirrors extract_row_text_screen: scan up to max(cols,256) columns, stop when
// the cell is out of bounds, map control/unwritten cells to space, rstrip.
static void dump_rows(MinervaTerminal t, uint16_t cols) {
    uint32_t total = 0, vp = 0; bool bottom = false;
    minerva_vt_get_scroll_info(t, &total, &vp, &bottom);
    int scan = cols > 256 ? cols : 256;
    fprintf(stderr, "rows_total=%u viewport=%u\n", total, vp);
    for (uint32_t row = 0; row < total; row++) {
        char line[MAXCOLS * 4 + 1];
        int n = 0;
        for (int col = 0; col < scan; col++) {
            MinervaCellInfo ci;
            if (!minerva_vt_get_cell_screen(t, (uint16_t)col, row, &ci)) break;
            uint32_t cp = ci.codepoint;
            if (cp < 32) { line[n++] = ' '; continue; }
            // UTF-8 encode
            if (cp < 0x80) line[n++] = (char)cp;
            else if (cp < 0x800) { line[n++] = (char)(0xC0|(cp>>6)); line[n++] = (char)(0x80|(cp&0x3F)); }
            else if (cp < 0x10000) { line[n++] = (char)(0xE0|(cp>>12)); line[n++] = (char)(0x80|((cp>>6)&0x3F)); line[n++] = (char)(0x80|(cp&0x3F)); }
            else { line[n++] = (char)(0xF0|(cp>>18)); line[n++] = (char)(0x80|((cp>>12)&0x3F)); line[n++] = (char)(0x80|((cp>>6)&0x3F)); line[n++] = (char)(0x80|(cp&0x3F)); }
        }
        while (n > 0 && line[n-1] == ' ') n--;
        line[n] = 0;
        printf("%s\n", line);
    }
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: vtreplay <cols> <rows> <file> [--poll N]\n"); return 2; }
    uint16_t cols = (uint16_t)atoi(argv[1]);
    uint16_t rows = (uint16_t)atoi(argv[2]);
    size_t poll = 0;
    for (int i = 4; i + 1 < argc + 1 && i < argc; i++)
        if (!strcmp(argv[i], "--poll") && i + 1 < argc) poll = (size_t)atol(argv[i+1]);

    FILE *f = fopen(argv[3], "rb");
    if (!f) { perror("open"); return 1; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(len);
    if (fread(buf, 1, len, f) != (size_t)len) { perror("read"); return 1; }
    fclose(f);

    MinervaTerminal t = minerva_vt_new(cols, rows);
    if (!t) { fprintf(stderr, "vt_new failed\n"); return 1; }

    if (poll == 0) {
        minerva_vt_write(t, buf, len);
        dump_rows(t, cols);
    } else {
        for (long off = 0; off < len; off += poll) {
            size_t n = (size_t)((len - off) < (long)poll ? (len - off) : (long)poll);
            minerva_vt_write(t, buf + off, n);
            printf("===SNAPSHOT offset=%ld===\n", off + (long)n);
            dump_rows(t, cols);
        }
    }
    minerva_vt_free(t);
    free(buf);
    return 0;
}
