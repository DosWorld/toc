#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma pack(push, 1)

typedef struct {
    uint16_t magic;
    uint8_t  minor_version;
    uint8_t  major_version;
    uint32_t names_pool_size;
    uint16_t names_count;
    uint16_t types_count;
    uint16_t members_count;
    uint16_t symbols_count;
    uint16_t globals_count;
    uint16_t modules_count;
    uint16_t locals_count;
    uint16_t scopes_count;
    uint16_t line_numbers_count;
    uint16_t source_files_count;
    uint16_t segments_count;
    uint16_t correlations_count;
    uint8_t  reserved[14];
    uint16_t extension_size;
} TDINFO_HEADER;

typedef struct {
    uint16_t index;
    uint16_t type;
    uint16_t offset;
    uint16_t segment;
    uint8_t  bitfield;
} SYMBOL_RECORD;

typedef struct {
    uint16_t name;
    uint8_t  padding[14];
} MODULE_RECORD;

typedef struct {
    uint16_t symbol_index;
    uint16_t symbol_count;
    uint16_t parent;
    uint16_t function;
    uint16_t offset;
    uint16_t length;
} SCOPE_RECORD;

typedef struct {
    uint16_t module;
    uint16_t code_segment;
    uint16_t code_offset;
    uint16_t code_length;
    uint16_t scope_index;
    uint16_t scope_count;
    uint8_t  padding[4];
} SEGMENT_RECORD;

typedef struct {
    uint8_t  id;
    uint16_t name;
    uint16_t size;
    uint8_t  class_type;
    uint16_t member_type;
} TYPE_RECORD;

typedef struct {
    uint8_t  info;
    uint16_t name;
    uint16_t type;
} MEMBER_RECORD;

typedef struct {
    uint16_t file_name_index;
    uint16_t dos_time;
    uint16_t dos_date;
} SOURCE_FILE_RECORD;

typedef struct {
    uint16_t line_number;
    uint16_t offset;
} LINE_NUMBER_RECORD;

typedef struct {
    uint16_t source_file_index;
    uint16_t segment_index;
    uint16_t module_index;
    uint16_t flags_or_reserved;
} CORRELATION_RECORD;

#pragma pack(pop)

static const char *symbol_class_names[] = {
    "STATIC", "ABSOLUTE", "AUTO", "PASCAL_VAR",
    "REGISTER", "CONSTANT", "TYPEDEF", "STRUCT_UNION_OR_ENUM"
};

static const char *type_id_names[] = {
    "VOID", "LSTR", "DSTR", "PSTR", "SCHAR", "SINT", "SLONG",
    NULL, "UCHAR", "UINT", "ULONG", NULL, "PCHAR", "FLOAT", "TPREAL",
    "DOUBLE", "LDOUBLE", "BCD4", "BCD8", "BCD10", "BCDCOB",
    "NEAR", "FAR", "SEG", "NEAR386", "FAR386", "ARRAY", NULL, "PARRAY",
    NULL, "STRUCT", "UNION", NULL, NULL, "ENUM", "FUNCTION", "LABEL",
    "SET", "TFILE", "BFILE", "BOOL", "PENUM", NULL, NULL, "FUNCPROTOTYPE",
    "SPECIALFUNC", "OBJECT", NULL, NULL, NULL, NULL, NULL, "NREF", "FREF",
    "WORDBOOL", "LONGBOOL", NULL, NULL, NULL, NULL, NULL, NULL,
    "GLOBALHANDLE", "LOCALHANDLE"
};

#define TYPE_ID_MAX (sizeof(type_id_names) / sizeof(type_id_names[0]))

static const char *get_name(uint16_t index, const char *pool)
{
    const char *p;
    uint16_t i;
    if (index == 0 || !pool) return NULL;
    p = pool;
    for (i = 1; i < index; i++) {
        p = strchr(p, '\0');
        if (!p) return NULL;
        p++;
    }
    return p;
}

static int safe_read(void *ptr, size_t size, size_t count, FILE *f)
{
    return fread(ptr, size, count, f) == count;
}

static int skip_bytes(FILE *f, long bytes)
{
    return fseek(f, bytes, SEEK_CUR) == 0;
}

static SEGMENT_RECORD *find_segment_by_index(SEGMENT_RECORD *segments,
                                             uint16_t count, uint16_t index)
{
    if (segments && index > 0 && index <= count)
        return &segments[index - 1];
    return NULL;
}

int main(int argc, char **argv)
{
    FILE *fp;
    long file_size;
    long tdinfo_off;
    long off;
    uint16_t magic;
    TDINFO_HEADER hdr;
    SYMBOL_RECORD *symbols;
    MODULE_RECORD *modules;
    SOURCE_FILE_RECORD *src_files;
    LINE_NUMBER_RECORD *line_nums;
    SCOPE_RECORD *scopes;
    SEGMENT_RECORD *segments;
    CORRELATION_RECORD *corrs;
    TYPE_RECORD *types;
    MEMBER_RECORD *members;
    char *names_pool;
    uint16_t j;
    const char *name;
    uint8_t cls;
    const char *fname;
    const char *mod;
    const char *id_str;
    const char *type_name;
    const char *member_name;
    const char *end_mark;

    symbols = NULL;
    modules = NULL;
    src_files = NULL;
    line_nums = NULL;
    scopes = NULL;
    segments = NULL;
    corrs = NULL;
    types = NULL;
    members = NULL;
    names_pool = NULL;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s <file.exe>\n", argv[0]);
        return 1;
    }

    fp = fopen(argv[1], "rb");
    if (!fp) {
        perror("Failed to open file");
        return 1;
    }

    fseek(fp, 0, SEEK_END);
    file_size = ftell(fp);
    rewind(fp);

    tdinfo_off = -1;
    for (off = 0; off < file_size - 1; off++) {
        fseek(fp, off, SEEK_SET);
        if (safe_read(&magic, 2, 1, fp) && magic == 0x52FB) {
            tdinfo_off = off;
            break;
        }
    }

    if (tdinfo_off < 0) {
        fprintf(stderr, "TDINFO signature (0x52FB) not found\n");
        fclose(fp);
        return 1;
    }

    printf("TDINFO at offset 0x%lX\n", tdinfo_off);
    fseek(fp, tdinfo_off, SEEK_SET);

    if (!safe_read(&hdr, sizeof(hdr), 1, fp)) {
        fprintf(stderr, "Error reading TDINFO header\n");
        fclose(fp);
        return 1;
    }

    printf("Borland TLINK v%u.%02u  names:%u types:%u members:%u symbols:%u(global:%u) modules:%u scopes:%u seg:%u src:%u lines:%u corr:%u pool:%u\n\n",
           hdr.major_version, hdr.minor_version,
           hdr.names_count, hdr.types_count, hdr.members_count,
           hdr.symbols_count, hdr.globals_count,
           hdr.modules_count, hdr.scopes_count, hdr.segments_count,
           hdr.source_files_count, hdr.line_numbers_count, hdr.correlations_count,
           hdr.names_pool_size);

    if (hdr.extension_size && !skip_bytes(fp, hdr.extension_size)) {
        fprintf(stderr, "Error skipping extension\n");
        fclose(fp);
        return 1;
    }

    if (hdr.symbols_count) {
        symbols = malloc(hdr.symbols_count * sizeof(SYMBOL_RECORD));
        if (!symbols || !safe_read(symbols, sizeof(SYMBOL_RECORD), hdr.symbols_count, fp)) goto fail;
    }
    if (hdr.modules_count) {
        modules = malloc(hdr.modules_count * sizeof(MODULE_RECORD));
        if (!modules || !safe_read(modules, sizeof(MODULE_RECORD), hdr.modules_count, fp)) goto fail;
    }
    if (hdr.source_files_count) {
        src_files = malloc(hdr.source_files_count * sizeof(SOURCE_FILE_RECORD));
        if (!src_files || !safe_read(src_files, sizeof(SOURCE_FILE_RECORD), hdr.source_files_count, fp)) goto fail;
    }
    if (hdr.line_numbers_count) {
        line_nums = malloc(hdr.line_numbers_count * sizeof(LINE_NUMBER_RECORD));
        if (!line_nums || !safe_read(line_nums, sizeof(LINE_NUMBER_RECORD), hdr.line_numbers_count, fp)) goto fail;
    }
    if (hdr.scopes_count) {
        scopes = malloc(hdr.scopes_count * sizeof(SCOPE_RECORD));
        if (!scopes || !safe_read(scopes, sizeof(SCOPE_RECORD), hdr.scopes_count, fp)) goto fail;
    }
    if (hdr.segments_count) {
        segments = malloc(hdr.segments_count * sizeof(SEGMENT_RECORD));
        if (!segments || !safe_read(segments, sizeof(SEGMENT_RECORD), hdr.segments_count, fp)) goto fail;
    }
    if (hdr.correlations_count) {
        corrs = malloc(hdr.correlations_count * sizeof(CORRELATION_RECORD));
        if (!corrs || !safe_read(corrs, sizeof(CORRELATION_RECORD), hdr.correlations_count, fp)) goto fail;
    }
    if (hdr.types_count) {
        types = malloc(hdr.types_count * sizeof(TYPE_RECORD));
        if (!types || !safe_read(types, sizeof(TYPE_RECORD), hdr.types_count, fp)) goto fail;
    }
    if (hdr.members_count) {
        members = malloc(hdr.members_count * sizeof(MEMBER_RECORD));
        if (!members || !safe_read(members, sizeof(MEMBER_RECORD), hdr.members_count, fp)) goto fail;
    }

    if (hdr.names_pool_size && hdr.names_count) {
        names_pool = malloc(hdr.names_pool_size);
        if (!names_pool) goto fail;
        fseek(fp, -(long)hdr.names_pool_size, SEEK_END);
        if (!safe_read(names_pool, 1, hdr.names_pool_size, fp)) {
            free(names_pool);
            names_pool = NULL;
        }
    }

    if (symbols) {
        printf("=== Symbols (%u) ===\n", hdr.symbols_count);
        for (j = 0; j < hdr.symbols_count; j++) {
            name = get_name(symbols[j].index, names_pool);
            cls = symbols[j].bitfield & 0x07;
            printf("  [%3u] %-40s type=%u seg:off=%04X:%04X class=%s\n",
                   j, name ? name : "(null)", symbols[j].type,
                   symbols[j].segment, symbols[j].offset, symbol_class_names[cls]);
        }
        putchar('\n');
    }

    if (modules) {
        printf("=== Modules (%u) ===\n", hdr.modules_count);
        for (j = 0; j < hdr.modules_count; j++) {
            name = get_name(modules[j].name, names_pool);
            printf("  [%3u] %s\n", j, name ? name : "(null)");
        }
        putchar('\n');
    }

    /* SOURCE_FILE_RECORD carries no segment/offset field (v2.08); the only
       file<->segment link is the CORRELATION_RECORD array (see below). Dump
       source files and line numbers as flat, unbracketed tables. */
    if (src_files) {
        printf("=== Source files (%u) ===\n", hdr.source_files_count);
        for (j = 0; j < hdr.source_files_count; j++) {
            fname = get_name(src_files[j].file_name_index, names_pool);
            if (!fname) fname = "(null)";
            printf("  [%3u] %s  (time=%04X date=%04X)\n",
                   j, fname, src_files[j].dos_time, src_files[j].dos_date);
        }
        putchar('\n');
    }
    if (line_nums) {
        printf("=== Line numbers (%u) ===\n", hdr.line_numbers_count);
        for (j = 0; j < hdr.line_numbers_count; j++) {
            printf("  line %5u at offset %04X\n",
                   line_nums[j].line_number, line_nums[j].offset);
        }
        putchar('\n');
    }

    if (scopes) {
        printf("=== Scopes (%u) ===\n", hdr.scopes_count);
        for (j = 0; j < hdr.scopes_count; j++) {
            printf("  [%3u] sym_first=%u cnt=%u parent=%u func=%u offset=%04X len=%04X\n",
                   j, scopes[j].symbol_index, scopes[j].symbol_count,
                   scopes[j].parent, scopes[j].function,
                   scopes[j].offset, scopes[j].length);
        }
        putchar('\n');
    }

    if (segments) {
        printf("=== Segments (%u) ===\n", hdr.segments_count);
        for (j = 0; j < hdr.segments_count; j++) {
            mod = "?";
            if (modules && names_pool && segments[j].module > 0 &&
                segments[j].module <= hdr.modules_count)
                mod = get_name(modules[segments[j].module - 1].name, names_pool);
            printf("  [%3u] module=%u (%s) seg:off=%04X:%04X len=%04X scope_first=%u scope_count=%u\n",
                   j, segments[j].module, mod ? mod : "?",
                   segments[j].code_segment, segments[j].code_offset,
                   segments[j].code_length,
                   segments[j].scope_index, segments[j].scope_count);
        }
        putchar('\n');
    }

    if (corrs) {
        printf("=== Correlations (%u) ===\n", hdr.correlations_count);
        for (j = 0; j < hdr.correlations_count; j++) {
            const char *src_name = "(none)";
            const char *mod_name = "(none)";
            const char *seg_mod = "(none)";
            SEGMENT_RECORD *seg;
            if (corrs[j].source_file_index > 0 &&
                corrs[j].source_file_index <= hdr.source_files_count &&
                src_files) {
                src_name = get_name(
                    src_files[corrs[j].source_file_index - 1].file_name_index,
                    names_pool);
                if (!src_name) src_name = "(null)";
            }
            if (corrs[j].module_index > 0 &&
                corrs[j].module_index <= hdr.modules_count &&
                modules && names_pool) {
                mod_name = get_name(
                    modules[corrs[j].module_index - 1].name, names_pool);
                if (!mod_name) mod_name = "(null)";
            }
            seg = find_segment_by_index(segments, hdr.segments_count,
                                        corrs[j].segment_index);
            if (seg) {
                seg_mod = "?";
                if (modules && names_pool && seg->module > 0 &&
                    seg->module <= hdr.modules_count)
                    seg_mod = get_name(modules[seg->module - 1].name, names_pool);
                if (!seg_mod) seg_mod = "?";
                printf("  [%3u] src_file=\"%s\" seg=%u (%04X:%04X, mod=\"%s\") mod=%u (\"%s\") flags=0x%04X\n",
                       j, src_name,
                       corrs[j].segment_index,
                       seg->code_segment, seg->code_offset,
                       seg_mod,
                       corrs[j].module_index, mod_name,
                       corrs[j].flags_or_reserved);
            } else {
                printf("  [%3u] src_file=\"%s\" seg=%u (unknown) mod=%u (\"%s\") flags=0x%04X\n",
                       j, src_name,
                       corrs[j].segment_index,
                       corrs[j].module_index, mod_name,
                       corrs[j].flags_or_reserved);
            }
        }
        putchar('\n');
    }

    if (types) {
        printf("=== Types (%u) ===\n", hdr.types_count);
        for (j = 0; j < hdr.types_count; j++) {
            id_str = (types[j].id < TYPE_ID_MAX && type_id_names[types[j].id])
                     ? type_id_names[types[j].id] : "UNKNOWN";
            type_name = (types[j].name && names_pool)
                        ? get_name(types[j].name, names_pool) : "(anonymous)";
            printf("  [%3u] %-20s id=%-12s size=%u class_type=%u member_type=%u\n",
                   j, type_name, id_str, types[j].size,
                   types[j].class_type, types[j].member_type);
        }
        putchar('\n');
    }

    if (members) {
        printf("=== Members (%u) ===\n", hdr.members_count);
        for (j = 0; j < hdr.members_count; j++) {
            member_name = (members[j].name && names_pool)
                          ? get_name(members[j].name, names_pool) : "(anonymous)";
            end_mark = (members[j].info == 0xC0) ? " [END]" : "";
            printf("  [%3u] %-30s type=%u info=0x%02X%s\n",
                   j, member_name, members[j].type, members[j].info, end_mark);
        }
        putchar('\n');
    }

    if (names_pool && hdr.names_count) {
        printf("=== Names pool (%u names) ===\n", hdr.names_count);
        for (j = 1; j <= hdr.names_count; j++) {
            name = get_name(j, names_pool);
            printf("  [%3u] %s\n", j, name ? name : "(null)");
        }
        putchar('\n');
    }

    free(symbols);
    free(modules);
    free(src_files);
    free(line_nums);
    free(scopes);
    free(segments);
    free(corrs);
    free(types);
    free(members);
    free(names_pool);
    fclose(fp);
    return 0;

fail:
    fprintf(stderr, "Memory allocation or read error\n");
    free(symbols);
    free(modules);
    free(src_files);
    free(line_nums);
    free(scopes);
    free(segments);
    free(corrs);
    free(types);
    free(members);
    free(names_pool);
    fclose(fp);
    return 1;
}
