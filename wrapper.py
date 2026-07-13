#!/usr/bin/env python3
"""
Platform wrapper for Vectorized Batch PIR.

Container contract:
    docker run --rm -v <host_dir>:/benchmark <image>
      reads  /benchmark/config.json
      writes /benchmark/results.json   (canonical schema; adapter: generic)

Parameter mapping (config.json -> binary CLI):
    database.num_records   -> num_entries   (honored)
    database.record_bytes  -> entry_size    (honored; DB is synthetic)
    benchmark.batch_size   -> batch_size    (honored in batch mode; scheme IS batched)
    crypto.lattice_dimension               -> NOT exposed (ring degree compiled in at 8192)
"""

import json
import math
import os
import statistics
import subprocess
import sys

CONFIG_PATH = "/benchmark/config.json"
RESULTS_PATH = "/benchmark/results.json"
RAW_PATH = "/tmp/raw.json"
BINARY = "/app/build/bin/vectorized_batch_pir"

SCHEME_NAME = "Vectorized Batch PIR"
# DatabaseConstants::PolyDegree (BFV poly_modulus_degree) is compiled in.
POLY_MODULUS_DEGREE = 8192
# DatabaseConstants::NumHashFunctions / CuckooFactor (header/database_constants.h).
# simeple_hash() sizes its bucket array as ceil(CUCKOO_FACTOR * batch_size) and then
# requires NUM_HASH_FUNCS *distinct* buckets per entry (utils::get_candidate_buckets).
# If that bucket count is below NUM_HASH_FUNCS, picking a distinct bucket is
# impossible and the candidate-search while-loop spins forever.
NUM_HASH_FUNCS = 3
CUCKOO_FACTOR = 1.2
MIN_BATCH_SIZE = math.ceil(NUM_HASH_FUNCS / CUCKOO_FACTOR)


def write_results(obj):
    with open(RESULTS_PATH, "w") as f:
        json.dump(obj, f, indent=2)


def main():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)

    db = cfg.get("database", {})
    crypto = cfg.get("crypto", {})
    bench = cfg.get("benchmark", {})

    num_records = int(db.get("num_records"))
    record_bytes = int(db.get("record_bytes"))
    lattice_dimension = crypto.get("lattice_dimension")
    mode = bench.get("mode", "single")
    cfg_batch_size = bench.get("batch_size", 1)

    notes = []
    unmapped = {}

    # lattice_dimension is never forwarded: the ring degree is hard-coded.
    unmapped["lattice_dimension"] = {
        "value": lattice_dimension,
        "note": (
            "Not exposed by the binary. The BFV ring dimension is compiled in "
            f"(DatabaseConstants::PolyDegree = {POLY_MODULUS_DEGREE}). No flag changes "
            "it, so lattice_dimension is logged and dropped, never forwarded."
        ),
    }

    # The scheme is genuinely batched, so batch_size is honored in batch mode.
    if mode == "batch":
        batch_size = int(cfg_batch_size)
        notes.append(f"mode=batch: retrieving batch_size={batch_size} records per query.")
    else:
        batch_size = 1
        if cfg_batch_size not in (1, None):
            unmapped["batch_size"] = {
                "value": cfg_batch_size,
                "note": "mode is 'single'; received batch_size ignored, run forced to 1.",
            }

    total_buckets = math.ceil(CUCKOO_FACTOR * batch_size)
    if total_buckets < NUM_HASH_FUNCS:
        msg = (
            f"batch_size={batch_size} is not supported: BatchPIRServer::simeple_hash() "
            f"sizes its bucket array as ceil({CUCKOO_FACTOR}*{batch_size})={total_buckets} "
            f"buckets, but every entry must land in {NUM_HASH_FUNCS} distinct buckets "
            "(NumHashFunctions). With fewer buckets than hash functions that's "
            "impossible, so the candidate-bucket search hangs forever instead of "
            f"failing. This scheme requires batch_size >= {MIN_BATCH_SIZE}; "
            "'Single-record' mode (batch_size=1) is not supported by Vectorized Batch "
            "PIR — use batch mode with a larger batch_size instead."
        )
        print(f"[wrapper] ERROR: {msg}", file=sys.stderr, flush=True)
        write_results({
            "scheme": SCHEME_NAME,
            "variant": None,
            "status": "error",
            "error": msg,
            "parameters_echo": {
                "database": {"num_records": num_records, "record_bytes": record_bytes},
                "crypto": {"lattice_dimension": lattice_dimension},
                "benchmark": {"mode": mode, "batch_size": cfg_batch_size},
            },
            "unmapped_parameters": unmapped,
            "notes": notes + [msg],
        })
        sys.exit(1)

    trials = os.environ.get("BENCH_TRIALS", "5")

    params_echo = {
        "database": {"num_records": num_records, "record_bytes": record_bytes},
        "crypto": {"lattice_dimension": lattice_dimension},
        "benchmark": {"mode": mode, "batch_size": cfg_batch_size},
    }

    cmd = [BINARY, str(batch_size), str(num_records), str(record_bytes), str(trials)]
    env = dict(os.environ)
    env["BENCH_OUT"] = RAW_PATH
    env["BENCH_TRIALS"] = str(trials)

    print(
        f"[wrapper] config: num_records={num_records} record_bytes={record_bytes} "
        f"mode={mode} batch_size={batch_size} trials={trials}",
        flush=True,
    )
    print(f"[wrapper] exec: {' '.join(cmd)}", flush=True)

    if os.path.exists(RAW_PATH):
        os.remove(RAW_PATH)

    # Stream stdout/stderr live (NO capture_output) so progress is visible.
    proc = subprocess.run(cmd, env=env)

    if proc.returncode != 0:
        rc = proc.returncode
        detail = f"binary exited with code {rc}"
        if rc < 0:
            sig = -rc
            detail = (
                f"binary terminated by signal {sig}. SIGILL(4)/SIGSEGV(11) under Rosetta 2 "
                "usually means an instruction the emulator cannot run (e.g. AVX-512). This "
                "scheme is built for AVX2 (x86-64-v3), which Rosetta DOES emulate, so a "
                "signal here more likely indicates a genuine crash or an unsupported "
                "(batch_size, num_records, record_bytes) parameter combination."
            )
        print(f"[wrapper] ERROR: {detail}", file=sys.stderr, flush=True)
        write_results({
            "scheme": SCHEME_NAME,
            "variant": None,
            "status": "error",
            "error": detail,
            "exit_code": rc,
            "parameters_echo": params_echo,
            "unmapped_parameters": unmapped,
            "notes": notes + [detail],
        })
        sys.exit(1)

    try:
        with open(RAW_PATH) as f:
            raw = json.load(f)
    except Exception as e:  # noqa: BLE001
        msg = f"binary exited 0 but {RAW_PATH} could not be read/parsed: {e}"
        print(f"[wrapper] ERROR: {msg}", file=sys.stderr, flush=True)
        write_results({
            "scheme": SCHEME_NAME,
            "variant": None,
            "status": "error",
            "error": msg,
            "parameters_echo": params_echo,
            "unmapped_parameters": unmapped,
            "notes": notes + [msg],
        })
        sys.exit(1)

    server_trials = [float(x) for x in raw.get("server_answer_trials_ms", [])]
    if server_trials:
        mean_ms = statistics.fmean(server_trials)
        std_ms = statistics.stdev(server_trials) if len(server_trials) > 1 else None
    else:
        mean_ms, std_ms = None, None

    total_comm_kb = raw.get("total_comm_kb")
    if total_comm_kb is not None:
        notes.append(
            "Scheme-reported total serialized communication (query+response): "
            f"{total_comm_kb} KB (~{int(total_comm_kb) * 1024} bytes). Reported here split "
            "into query_upload_bytes and response_bytes measured directly via save_size()."
        )

    if raw.get("decoded_ok", False):
        notes.append("Decoded batch entries verified against the server database.")
    else:
        notes.append(
            "WARNING: decoded entries did NOT match. The (batch_size, num_records, "
            "record_bytes) combination likely falls outside the FHE parameters tuned in "
            "utils.h, so default SEAL parameters were used. Timings are valid but "
            "correctness is not guaranteed for this input."
        )

    notes.append(
        f"FHE parameter-table selection string: '{raw.get('selection')}'. Known-good "
        "combos: 32/64/256 x 1048576 x 32, and 256 x {10485,104857} x {32,256}; other "
        "inputs fall back to default SEAL parameters."
    )
    notes.append(
        "Built for AVX2 (x86-64-v3); does NOT require AVX-512. Apple-Silicon-via-Rosetta "
        "timings are for pipeline validation only — collect publication numbers on native "
        "x86-64."
    )

    results = {
        "scheme": SCHEME_NAME,
        "variant": None,
        "parameters_echo": params_echo,
        "phases": {
            "setup": {
                "mean_ms": raw.get("setup_ms"),
                "note": (
                    "BatchPIRServer construction: synthetic database generation, "
                    "simple/cuckoo hashing into buckets, and NTT preprocessing of the PIR "
                    "database. Measured once (client key generation not separately timed)."
                ),
            },
            "client_offline_download": {
                "mean_ms": None,
                "note": (
                    "No separate client offline-download phase: the bucket hash-map and "
                    "Galois/relin keys are exchanged in-process and are not independently "
                    "timed by the binary."
                ),
            },
            "query_generation": {
                "mean_ms": raw.get("query_generation_ms"),
                "note": (
                    "create_queries: cuckoo hashing of the requested batch plus BFV "
                    "encryption of the per-bucket query vectors."
                ),
            },
            "server_answer": {
                "mean_ms": mean_ms,
                "std_dev_ms": std_ms,
                "all_trials_ms": server_trials,
                "num_trials": len(server_trials),
                "note": (
                    "generate_response over the encrypted batch query; headline metric. "
                    "Trials re-run on identical queries after a single setup."
                ),
            },
            "client_extract": {
                "mean_ms": raw.get("client_extract_ms"),
                "note": (
                    "decode_responses_chunks: decryption and extraction of all batch "
                    "entries from the server response."
                ),
            },
        },
        "communication": {
            "offline_download_bytes": None,
            "query_upload_bytes": raw.get("query_upload_bytes"),
            "response_bytes": raw.get("response_bytes"),
        },
        "unmapped_parameters": unmapped,
        "notes": notes,
    }

    write_results(results)
    print(f"[wrapper] wrote {RESULTS_PATH}", flush=True)


if __name__ == "__main__":
    main()
