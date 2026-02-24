/**
 * simdjson_bench.cpp
 *
 * NDJSON filter benchmark using simdjson ondemand API.
 * Equivalent task to zson: read NDJSON, match records where a numeric field
 * satisfies a comparison, output (or count) matching records.
 *
 * Usage:
 *   simdjson_bench <file.ndjson> [--field name] [--gt N] [--count] [--quiet]
 *
 * Defaults: --field age --gt 30
 *
 * Compile:
 *   c++ -O3 -std=c++17 -o simdjson_bench simdjson_bench.cpp \
 *       $(pkg-config --cflags --libs simdjson)
 */

#include <simdjson.h>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

// ── helpers ──────────────────────────────────────────────────────────────────

static double now_secs() {
    using namespace std::chrono;
    return duration<double>(high_resolution_clock::now().time_since_epoch()).count();
}

// Build an index of (start, exclusive-end) byte offsets for every non-empty line.
static std::vector<std::pair<size_t, size_t>>
build_line_index(const char* data, size_t len) {
    std::vector<std::pair<size_t, size_t>> idx;
    idx.reserve(2 << 20); // start with 2M capacity
    size_t s = 0;
    for (size_t i = 0; i <= len; ++i) {
        if (i == len || data[i] == '\n') {
            if (i > s) idx.emplace_back(s, i); // skip empty lines
            s = i + 1;
        }
    }
    return idx;
}

// ── main ─────────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    const char* filename  = nullptr;
    const char* field     = "age";
    double      threshold = 30.0;
    bool        count_only = false;
    bool        quiet      = false; // suppress per-record output (for pure throughput)

    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--count"))        count_only = true;
        else if (!strcmp(argv[i], "--quiet"))        quiet      = true;
        else if (!strcmp(argv[i], "--field") && i+1 < argc) field = argv[++i];
        else if (!strcmp(argv[i], "--gt")    && i+1 < argc) threshold = atof(argv[++i]);
        else if (argv[i][0] != '-')                  filename = argv[i];
    }

    if (!filename) {
        fprintf(stderr,
            "Usage: simdjson_bench <file.ndjson> [--field F] [--gt N] [--count] [--quiet]\n");
        return 1;
    }

    // ── load file ────────────────────────────────────────────────────────────
    simdjson::padded_string json;
    auto err = simdjson::padded_string::load(filename).get(json);
    if (err) {
        fprintf(stderr, "Error loading file: %s\n", simdjson::error_message(err));
        return 1;
    }
    const size_t file_size = json.size();

    // ── pre-scan line boundaries (needed for raw output) ─────────────────────
    // This mirrors zson's mmap approach: we keep the original bytes for output.
    auto line_idx = build_line_index(json.data(), file_size);
    const size_t total_lines = line_idx.size();

    // ── setup parser & stream ─────────────────────────────────────────────────
    simdjson::ondemand::parser parser;
    // iterate_many is simdjson's native NDJSON / batch-JSON API.
    // batch_size hint: 1 MiB keeps the parser cache warm.
    simdjson::ondemand::document_stream stream;
    err = parser.iterate_many(json, 1 << 20).get(stream);
    if (err) {
        fprintf(stderr, "iterate_many error: %s\n", simdjson::error_message(err));
        return 1;
    }
    // Use a large stdout buffer to avoid write-syscall overhead, matching zson's
    // single-write strategy as closely as possible.
    constexpr size_t OUT_BUF = 64 << 20; // 64 MiB
    std::vector<char> out_buf;
    if (!count_only && !quiet) out_buf.reserve(OUT_BUF);

    // ── benchmark loop ────────────────────────────────────────────────────────
    size_t total   = 0;
    size_t matched = 0;
    size_t line_no = 0; // tracks which line in our index we're on

    // Duplicate field key as a c-string for the hot path (field lookup).
    const std::string field_str(field);

    double t0 = now_secs();

    for (simdjson::ondemand::document_stream::iterator it = stream.begin();
         it != stream.end(); ++it) {
        // Must store to lvalue before using operator[]
        auto doc_ref = *it;
        double val;
        bool ok = (doc_ref[field_str].get(val) == simdjson::SUCCESS);

        if (ok && val > threshold) {
            ++matched;
            if (!count_only && !quiet && line_no < total_lines) {
                auto [s, e] = line_idx[line_no];
                const char* p = json.data() + s;
                size_t n = e - s;
                out_buf.insert(out_buf.end(), p, p + n);
                out_buf.push_back('\n');
            }
        }

        ++total;
        ++line_no;
    }

    double elapsed = now_secs() - t0;

    // ── flush output ──────────────────────────────────────────────────────────
    if (!count_only && !quiet && !out_buf.empty()) {
        fwrite(out_buf.data(), 1, out_buf.size(), stdout);
    }
    if (count_only) {
        printf("%zu\n", matched);
    }

    // ── report ────────────────────────────────────────────────────────────────
    double gb_per_sec = (double)file_size / 1e9 / elapsed;
    fprintf(stderr,
        "simdjson v%s | %s | field=%s gt=%.0f\n"
        "  total=%-10zu  matched=%-10zu\n"
        "  time=%.3fs  throughput=%.2f GB/s\n",
        SIMDJSON_VERSION,
        count_only ? "count" : (quiet ? "filter(no-output)" : "filter+output"),
        field, threshold,
        total, matched,
        elapsed, gb_per_sec);

    return 0;
}
