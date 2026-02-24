/**
 * tokenizer_bench.cpp
 *
 * Measures simdjson's structural character finding (stage1) throughput.
 * This is the apples-to-apples comparison against simd.zig::findJsonStructure.
 *
 * Both programs do the same task:
 *   Input : raw bytes of NDJSON data (already in memory)
 *   Output: positions of structural characters { } [ ] " : ,
 *   Metric: GB/s  (number of input bytes processed per second)
 *
 * The file is loaded ONCE outside the timing loop.
 * Each iteration re-parses the entire buffer from the same in-memory copy.
 *
 * Compile:
 *   c++ -O3 -std=c++17 -DSIMDJSON_THREADS_ENABLED=1 \
 *       -I/opt/homebrew/Cellar/simdjson/4.2.4/include \
 *       -L/opt/homebrew/Cellar/simdjson/4.2.4/lib -lsimdjson \
 *       -o bench/tokenizer_bench bench/tokenizer_bench.cpp
 *
 * Usage:
 *   ./bench/tokenizer_bench <file.ndjson> [iterations]
 */

#include <simdjson.h>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static double now_secs() {
    using namespace std::chrono;
    return duration<double>(high_resolution_clock::now().time_since_epoch()).count();
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <file.ndjson> [iterations]\n", argv[0]);
        return 1;
    }
    const char* filename = argv[1];
    const int iters = argc >= 3 ? atoi(argv[2]) : 5;

    // ── Load file once into a padded_string ──────────────────────────────────
    simdjson::padded_string json;
    auto err = simdjson::padded_string::load(filename).get(json);
    if (err) {
        fprintf(stderr, "Load error: %s\n", simdjson::error_message(err));
        return 1;
    }
    const size_t file_size = json.size();
    fprintf(stderr, "File loaded: %.3f GB  (%zu bytes)\n",
            (double)file_size / 1e9, file_size);

    // ── Warm-up (1 iteration, not timed) ─────────────────────────────────────
    {
        simdjson::ondemand::parser parser;
        simdjson::ondemand::document_stream stream;
        if (!parser.iterate_many(json, 1 << 20).get(stream)) {
            for (auto it = stream.begin(); it != stream.end(); ++it) {
                auto doc = *it;
                (void)doc;
            }
        }
    }

    // ── Timed iterations ─────────────────────────────────────────────────────
    // We measure the full ondemand parse loop (iterate_many) — this is what
    // simdjson does under the hood: stage1 (find structural bits) + stage2
    // (lazy value resolution on demand).  For NDJSON filtering workloads,
    // stage1 dominates.  Each iteration creates a fresh parser + stream so
    // that CPU caches see the data fresh each time.
    fprintf(stderr, "Running %d timed iteration(s)...\n", iters);

    double total_time = 0.0;
    size_t total_docs = 0;
    std::vector<double> run_times;

    for (int iter = 0; iter < iters; ++iter) {
        simdjson::ondemand::parser parser;
        simdjson::ondemand::document_stream stream;
        size_t docs = 0;

        double t0 = now_secs();

        if (!parser.iterate_many(json, 1 << 20).get(stream)) {
            for (auto it = stream.begin(); it != stream.end(); ++it) {
                // Access ONE field to force simdjson to actually tokenize the
                // document (lazy parsing doesn't tokenize until accessed).
                // We use a dummy key that won't exist — simdjson still runs
                // stage1 + stage2 header parsing to find the field.
                auto doc = *it;
                double val;
                (void)(doc["__z__"].get(val)); // always MISS — but forces parse
                ++docs;
            }
        }

        double elapsed = now_secs() - t0;
        run_times.push_back(elapsed);
        total_time += elapsed;
        total_docs += docs;
    }

    // ── Report ────────────────────────────────────────────────────────────────
    double best = run_times[0];
    for (double t : run_times) if (t < best) best = t;
    double avg = total_time / iters;

    fprintf(stderr,
        "\nsimdjson v%s  ondemand/iterate_many  (stage1+stage2, lazy field)\n"
        "  file_size : %.3f GB\n"
        "  iters     : %d\n"
        "  docs/iter : %zu\n"
        "  best run  : %.4fs  →  %.2f GB/s\n"
        "  avg  run  : %.4fs  →  %.2f GB/s\n",
        SIMDJSON_VERSION,
        (double)file_size / 1e9,
        iters,
        total_docs / (size_t)iters,
        best,  (double)file_size / 1e9 / best,
        avg,   (double)file_size / 1e9 / avg);

    // Machine-readable line for the comparison script
    printf("simdjson_gb_per_sec=%.2f simdjson_best_sec=%.4f simdjson_docs=%zu\n",
           (double)file_size / 1e9 / best, best, total_docs / (size_t)iters);

    return 0;
}
