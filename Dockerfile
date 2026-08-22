# syntax=docker/dockerfile:1
#
# Vectorized Batch PIR (IEEE S&P 2023) — benchmark image for the PIR platform.
#
# Forced to linux/amd64 so the x86_64 publication target is reproduced. On Apple
# Silicon this builds and runs under Rosetta 2. This scheme is a C++/Microsoft
# SEAL (BFV) lattice scheme; it targets AVX2 (x86-64-v3), which Rosetta CAN
# emulate. It does NOT need AVX-512, so there is no build-script/host-SIGILL
# hazard here (that hazard is specific to Rust build.rs + AVX-512).
#
FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain. SEAL 4.1 needs CMake >= 3.13 and a C++17 compiler;
# Ubuntu 22.04 ships cmake 3.22 + gcc 11 (which understands -march=x86-64-v3/v4).
# python3 is required for the wrapper entrypoint.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        g++ \
        make \
        cmake \
        git \
        ca-certificates \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# x86-64-v3 == AVX2 + FMA + BMI, which Rosetta 2 emulates -> safe to BUILD and
# RUN on Apple Silicon. Do NOT use x86-64-v4 (AVX-512): Rosetta cannot emulate
# it and this scheme does not require it. For native publication runs, replace
# x86-64-v3 with native in BOTH places below (see Execution Instructions).
ENV CFLAGS="-O3 -march=x86-64-v3"
ENV CXXFLAGS="-O3 -march=x86-64-v3"

# ---------------------------------------------------------------------------
# Dependency: Microsoft SEAL 4.1 (the only external dependency).
# SEAL_USE_INTEL_HEXL=OFF guarantees no AVX-512 code path is ever pulled in.
# SEAL_BUILD_DEPS=ON lets SEAL fetch its own deps (GSL/zstd/zlib) at build time.
# ---------------------------------------------------------------------------
RUN git clone --depth 1 --branch 4.1.1 https://github.com/microsoft/SEAL.git /tmp/SEAL \
    && cmake -S /tmp/SEAL -B /tmp/SEAL/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DSEAL_BUILD_DEPS=ON \
        -DSEAL_USE_INTEL_HEXL=OFF \
        -DSEAL_BUILD_EXAMPLES=OFF \
        -DSEAL_BUILD_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_CXX_FLAGS="-O3 -march=x86-64-v3" \
    && cmake --build /tmp/SEAL/build -j"$(nproc)" \
    && cmake --install /tmp/SEAL/build \
    && rm -rf /tmp/SEAL

# ---------------------------------------------------------------------------
# Copy the LOCAL source tree (may contain local fixes). Never git clone the
# scheme: the upstream repo may differ from this working copy.
# ---------------------------------------------------------------------------
COPY . /app
WORKDIR /app

# The upstream main() ignores argv and runs three hardcoded scenarios, which is
# useless for a parameterized benchmark. Replace it (and only it) with a
# single-scenario driver that takes <batch_size> <num_entries> <entry_size>
# [num_trials], times each protocol phase, and writes structured JSON to
# $BENCH_OUT. CMake's GLOB_RECURSE picks this file up unchanged.
COPY <<'CPP' /app/src/main.cpp
#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <exception>
#include "server.h"
#include "pirparams.h"
#include "client.h"
#include "batchpirparams.h"
#include "batchpirserver.h"
#include "batchpirclient.h"

using namespace std;
using namespace std::chrono;

static double ms_since(high_resolution_clock::time_point s,
                       high_resolution_clock::time_point e) {
    return duration_cast<duration<double, std::milli>>(e - s).count();
}

// Usage: vectorized_batch_pir <batch_size> <num_entries> <entry_size> [num_trials]
// Env:   BENCH_TRIALS (overrides num_trials), BENCH_OUT (json output path).
int main(int argc, char *argv[]) {
    if (argc < 4) {
        cerr << "Usage: " << argv[0]
             << " <batch_size> <num_entries> <entry_size> [num_trials]\n";
        return 2;
    }

    const int client_id = 0;
    int    batch_size  = std::stoi(argv[1]);
    size_t num_entries = std::stoull(argv[2]);
    size_t entry_size  = std::stoull(argv[3]);

    int num_trials = 5;
    if (argc >= 5) num_trials = std::stoi(argv[4]);
    if (const char *envt = std::getenv("BENCH_TRIALS")) {
        try { num_trials = std::stoi(envt); } catch (...) {}
    }
    if (num_trials < 1) num_trials = 1;

    const char *out_env = std::getenv("BENCH_OUT");
    string out_file = out_env ? string(out_env) : string("/tmp/raw.json");

    // The FHE parameter table in utils.h is keyed by this exact string.
    string selection = std::to_string(batch_size) + "," +
                       std::to_string(num_entries) + "," +
                       std::to_string(entry_size);

    auto encryption_params = utils::create_encryption_parameters(selection);
    BatchPirParams params(batch_size, num_entries, entry_size, encryption_params);
    params.print_params();

    // ---- setup: server construction (DB gen, hashing, NTT preprocessing) ----
    auto s0 = high_resolution_clock::now();
    BatchPIRServer batch_server(params);
    auto s1 = high_resolution_clock::now();
    double setup_ms = ms_since(s0, s1);

    BatchPIRClient batch_client(params);
    auto map = batch_server.get_hash_map();
    batch_client.set_map(map);
    batch_server.set_client_keys(client_id, batch_client.get_public_keys());

    std::srand(static_cast<unsigned>(time(nullptr)));
    vector<uint64_t> entry_indices;
    entry_indices.reserve(batch_size);
    for (int i = 0; i < batch_size; i++)
        entry_indices.push_back(std::rand() % num_entries);

    // ---- query generation ----
    auto q0 = high_resolution_clock::now();
    auto queries = batch_client.create_queries(entry_indices);
    auto q1 = high_resolution_clock::now();
    double query_generation_ms = ms_since(q0, q1);

    long long query_upload_bytes = 0;
    for (auto &q : queries)
        for (auto &c : q)
            query_upload_bytes += static_cast<long long>(c.save_size());

    // ---- server answer (headline metric, N trials on identical queries) ----
    vector<double> trials_ms;
    PIRResponseList responses;
    for (int t = 0; t < num_trials; t++) {
        auto a0 = high_resolution_clock::now();
        responses = batch_server.generate_response(client_id, queries);
        auto a1 = high_resolution_clock::now();
        trials_ms.push_back(ms_since(a0, a1));
        cout << "server_answer trial " << (t + 1) << "/" << num_trials
             << ": " << trials_ms.back() << " ms" << endl;
    }

    long long response_bytes = 0;
    for (auto &c : responses)
        response_bytes += static_cast<long long>(c.save_size());

    // ---- client extract ----
    auto e0 = high_resolution_clock::now();
    auto decoded = batch_client.decode_responses_chunks(responses);
    auto e1 = high_resolution_clock::now();
    double client_extract_ms = ms_since(e0, e1);

    size_t total_comm_kb = batch_client.get_serialized_commm_size();

    bool decoded_ok = false;
    try {
        decoded_ok = batch_server.check_decoded_entries(
            decoded, batch_client.get_cuckoo_table());
    } catch (const std::exception &ex) {
        cerr << "decode check threw: " << ex.what() << endl;
        decoded_ok = false;
    }

    // ---- emit structured JSON ----
    std::ostringstream js;
    js << "{\n";
    js << "  \"batch_size\": " << batch_size << ",\n";
    js << "  \"num_entries\": " << num_entries << ",\n";
    js << "  \"entry_size\": " << entry_size << ",\n";
    js << "  \"selection\": \"" << selection << "\",\n";
    js << "  \"poly_modulus_degree\": " << encryption_params.poly_modulus_degree() << ",\n";
    js << "  \"setup_ms\": " << setup_ms << ",\n";
    js << "  \"query_generation_ms\": " << query_generation_ms << ",\n";
    js << "  \"client_extract_ms\": " << client_extract_ms << ",\n";
    js << "  \"num_trials\": " << num_trials << ",\n";
    js << "  \"server_answer_trials_ms\": [";
    for (size_t i = 0; i < trials_ms.size(); ++i) {
        js << trials_ms[i];
        if (i + 1 < trials_ms.size()) js << ", ";
    }
    js << "],\n";
    js << "  \"query_upload_bytes\": " << query_upload_bytes << ",\n";
    js << "  \"response_bytes\": " << response_bytes << ",\n";
    js << "  \"total_comm_kb\": " << total_comm_kb << ",\n";
    js << "  \"decoded_ok\": " << (decoded_ok ? "true" : "false") << "\n";
    js << "}\n";

    std::ofstream ofs(out_file);
    ofs << js.str();
    ofs.close();

    cout << js.str();
    cout << "Benchmark complete. Wrote " << out_file << endl;
    return 0;
}
CPP

# ---------------------------------------------------------------------------
# Build the project against the installed SEAL. CMakeLists already adds -O3;
# CMAKE_CXX_FLAGS adds the AVX2 target. find_package(SEAL 4.1) resolves the
# install under /usr/local. SEAL::seal raises the standard to C++17 as required.
#
# Local-copy fix: client.cpp/server.cpp use std::bitset but never #include
# <bitset>. The upstream authors' toolchain pulled it in transitively; gcc 11 +
# libstdc++ does not, so the build fails. Force-include it (equivalent to adding
# the missing #include) rather than editing the source tree.
# ---------------------------------------------------------------------------
RUN cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-O3 -march=x86-64-v3 -include bitset" \
    && cmake --build build -j"$(nproc)"

# Platform wrapper implementing the container contract.
COPY wrapper.py /app/wrapper.py

# Mount point for /benchmark/config.json (in) and /benchmark/results.json (out).
RUN mkdir -p /benchmark

ENTRYPOINT ["python3", "/app/wrapper.py"]
