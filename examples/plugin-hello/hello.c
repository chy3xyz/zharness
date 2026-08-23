/*
 * hello.c — minimal zharness native plugin (Plugin ABI v1, dev.md §XXV).
 *
 * Exports exactly the four ABI symbols:
 *   zh_plugin_abi_version() -> 1
 *   zh_plugin_manifest()    -> static manifest JSON (one tool: hello_echo)
 *   zh_tool_execute(name, args_json) -> heap JSON result (host frees via
 *                                       zh_string_free)
 *   zh_string_free(ptr)     -> free()
 *
 * The tool `hello_echo` takes {"name": "..."} and answers
 * {"ok":true,"greeting":"Hello, <name>!"}. JSON parsing/escaping here is
 * deliberately hand-rolled and tiny — a real plugin would do more.
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Manifest lives in static storage; the host copies it, never frees it. */
static const char kManifest[] =
    "{"
    "\"name\":\"hello\","
    "\"version\":\"0.1.0\","
    "\"kind\":\"tool\","
    "\"tools\":[{"
        "\"name\":\"hello_echo\","
        "\"description\":\"Echo a friendly greeting. Args: {\\\"name\\\": \\\"<who>\\\"}.\","
        "\"schema\":{"
            "\"type\":\"object\","
            "\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Who to greet\"}},"
            "\"required\":[\"name\"]"
        "}"
    "}]"
    "}";

__attribute__((visibility("default")))
unsigned int zh_plugin_abi_version(void) { return 1u; }

__attribute__((visibility("default")))
const char *zh_plugin_manifest(void) { return kManifest; }

/* Extract the string value of "name" from a small flat JSON object. */
static void extract_name(const char *json, char *out, size_t cap) {
    out[0] = '\0';
    if (!json) return;
    const char *key = strstr(json, "\"name\"");
    if (!key) return;
    const char *p = key + strlen("\"name\"");
    while (*p == ' ' || *p == '\t') p++;
    if (*p != ':') return;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return;
    p++;
    size_t n = 0;
    while (*p && *p != '"') {
        char c = *p;
        if (c == '\\' && p[1]) {
            p++;
            switch (*p) {
                case 'n': c = '\n'; break;
                case 't': c = '\t'; break;
                default:  c = *p;   break; /* \" \\ \/ … */
            }
        }
        if (n + 1 < cap) out[n++] = c;
        p++;
    }
    out[n] = '\0';
}

/* Escape one string into a JSON string body (no surrounding quotes). */
static void append_escaped(char **dst, size_t *left, const char *s) {
    while (*s && *left > 2) {
        unsigned char c = (unsigned char)*s++;
        if (c == '"' || c == '\\') {
            **dst = '\\'; (*dst)++; (*left)--;
            **dst = (char)c; (*dst)++; (*left)--;
        } else if (c == '\n') {
            **dst = '\\'; (*dst)++; (*left)--;
            **dst = 'n'; (*dst)++; (*left)--;
        } else if (c < 0x20) {
            **dst = '?'; (*dst)++; (*left)--; /* keep control chars tame */
        } else {
            **dst = (char)c; (*dst)++; (*left)--;
        }
    }
}

__attribute__((visibility("default")))
char *zh_tool_execute(const char *tool_name, const char *args_json) {
    /* Contract: NULL ⇔ tool failure. The host synthesizes the error message;
     * success results are heap JSON handed to zh_string_free. */
    if (!tool_name || strcmp(tool_name, "hello_echo") != 0) return NULL;

    char name[256];
    extract_name(args_json ? args_json : "", name, sizeof(name));
    if (name[0] == '\0') return NULL; /* missing required arg: name */

    /* Result is heap-allocated on purpose: proves the host honours
     * zh_string_free instead of leaking or freeing with the wrong allocator. */
    static const char prefix[] = "{\"ok\":true,\"greeting\":\"Hello, ";
    static const char suffix[] = "!\"}";
    size_t need = sizeof(prefix) + strlen(name) * 2 + sizeof(suffix);
    char *out = (char *)malloc(need);
    if (!out) return NULL;

    char *w = out;
    size_t left = need;
    memcpy(w, prefix, sizeof(prefix) - 1); w += sizeof(prefix) - 1; left -= sizeof(prefix) - 1;
    append_escaped(&w, &left, name);
    memcpy(w, suffix, sizeof(suffix)); /* includes NUL */
    return out;
}

__attribute__((visibility("default")))
void zh_string_free(char *s) { free(s); }
