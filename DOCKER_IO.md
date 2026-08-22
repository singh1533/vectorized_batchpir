# Docker Input / Output Reference

This document describes exactly what the Docker container ([Dockerfile](Dockerfile)) reads,
what it writes, and how config values map onto the underlying Vectorized Batch PIR
(IEEE S&P 2023) C++/Microsoft SEAL (BFV) benchmark. The container's entrypoint is
[wrapper.py](wrapper.py), which in turn invokes a compiled binary whose `main()` the
Dockerfile **replaces** at build time (see "The injected `main.cpp`" below) — the
upstream `main()` ignores argv and runs three hardcoded demo scenarios, which is
useless for a parameterized benchmark.

## How it runs

```
docker run --rm -v /path/to/shared_volume:/benchmark <image>
```

- **Input** is read from `/benchmark/config.json` (inside the container).
- **Output** is written to `/benchmark/results.json` (inside the container).
- Mount a host directory (e.g. [shared_volume/](shared_volume/)) to `/benchmark` to pass a config in and get results out.
- The image is forced to `linux/amd64` (`FROM --platform=linux/amd64 ubuntu:22.04`). On
  Apple Silicon it builds/runs under Rosetta 2. The scheme is compiled for AVX2
  (`-march=x86-64-v3`, `SEAL_USE_INTEL_HEXL=OFF`), which Rosetta can emulate — it does
  **not** need AVX-512, so there's no build-time SIGILL hazard. Still, publication
  numbers should be collected on native x86-64, not under emulation.

### The injected `main.cpp`

The Dockerfile `COPY`s a heredoc over `src/main.cpp` before building. This custom
driver, not the upstream repo's `main()`, is what actually runs. It:

1. Takes CLI args `<batch_size> <num_entries> <entry_size> [num_trials]`.
2. Reads `BENCH_TRIALS` (overrides `num_trials`) and `BENCH_OUT` (output JSON path) from the environment.
3. Builds `selection = "<batch_size>,<num_entries>,<entry_size>"` and calls `utils::create_encryption_parameters(selection)` — the FHE parameter lookup key (see below).
4. Times, in order: `BatchPIRServer` construction (setup), `batch_client.create_queries()` (query generation), `num_trials` repetitions of `batch_server.generate_response()` (server answer, the headline metric — all on the *same* queries after a single setup), and `batch_client.decode_responses_chunks()` (client extract).
5. Verifies correctness via `batch_server.check_decoded_entries()` and writes a `decoded_ok` boolean.
6. Emits a JSON blob (`/tmp/raw.json` by default) that `wrapper.py` then reshapes into `results.json`.

## Input: `config.json`

Example ([shared_volume/config.json](shared_volume/config.json)):

```json
{
  "database":  { "num_records": 1048576, "record_bytes": 32 },
  "crypto":    { "lattice_dimension": 4096 },
  "benchmark": { "mode": "batch", "batch_size": 32 }
}
```

| Key | Required | Used? | Description |
|---|---|---|---|
| `database.num_records` | Yes | ✅ Yes | Passed straight through as `num_entries` to the binary (`int(db.get("num_records"))` — raises if missing). Also part of the FHE parameter-table lookup key (see below), so an untuned value silently degrades correctness, not just performance. |
| `database.record_bytes` | Yes | ✅ Yes | Passed straight through as `entry_size`. The database is **synthetic** — generated inside `BatchPIRServer`'s constructor, not loaded from real data — but the byte size genuinely drives `get_num_slots_per_entry()` and downstream parameter choices. Also part of the FHE selection-string lookup key. |
| `crypto.lattice_dimension` | No | ❌ **Not exposed / ignored** | Never forwarded to the binary. The BFV ring dimension (`poly_modulus_degree`) is hard-coded to **8192** in two places: `DatabaseConstants::PolyDegree` (`header/database_constants.h`) and the `const int PolyDegree = 8192` local inside `utils::create_encryption_parameters` (`src/utils.h`). `wrapper.py` logs whatever you set under `unmapped_parameters.lattice_dimension` with an explanatory note, but the value has zero effect on the run — even the example config's `4096` is silently dropped. |
| `benchmark.mode` | No | ✅ Yes (wrapper-level branch) | Only `"batch"` and `"single"` (default) matter. `mode == "batch"`: `batch_size` is taken from config and forwarded to the binary. Any other value (including omission) is treated as `"single"`: `batch_size` is **forced to 1** in the wrapper, regardless of what `benchmark.batch_size` says. |
| `benchmark.batch_size` | No (default `1`) | ✅ Yes, but **only when `mode == "batch"`** | This is the scheme's actual point — a genuinely batched query, not a loop of single queries. It becomes the binary's `argv[1]` and flows into `BatchPirParams` (`num_hash_funcs_ = DatabaseConstants::NumHashFunctions` = 3, `cuckoo_factor_ = DatabaseConstants::CuckooFactor` = 1.2), which determines the cuckoo-hash bucket count and, via `set_first_dimension_size()`, the internal PIR "first dimension." If `mode != "batch"`, any non-`1`/non-`null` `batch_size` is recorded under `unmapped_parameters.batch_size` with a note that it was ignored and the run was forced to `batch_size=1` — a single-record run is valid for this scheme but does **not** reflect its amortized batched performance, which is the whole point of the scheme. |

**No network parameters exist or are needed.** Client and server logic run in a single
process (`client_id = 0` hardcoded, keys exchanged in-memory); there are no sockets,
ports, or protocol settings. `BENCH_TRIALS` (env var, default `"5"` set by the wrapper)
controls the number of `generate_response()` repetitions but is not part of `config.json`
— it can only be overridden by setting the container's environment, not through the
config file.

### Hardcoded scheme constants (not in config.json, no override exists)

From `header/database_constants.h`:

| Constant | Value | Effect |
|---|---|---|
| `PolyDegree` | 8192 | BFV ring dimension. Same value `utils.h` uses locally. |
| `PlaintextModBitss` | 22 | Overridden per-selection-string branch inside `utils::create_encryption_parameters` (26 or 28 bits) — see FHE parameter table below. |
| `MaxAttempts` | 500 | Cuckoo-hashing retry cap during bucket placement. |
| `NumHashFunctions` | 3 | Number of cuckoo hash functions used to place each batch item into buckets. |
| `CuckooFactor` | 1.2 | Bucket-count inflation factor over `batch_size` for cuckoo hashing. |
| `FirstDimension` | 32 | Declared but the actual first-dimension size used at runtime is computed by `BatchPirParams::set_first_dimension_size()` from `max_bucket_size` via a cube-root/next-power-of-2 search, not this constant directly. |

### The FHE parameter table: a silent-fallback trap

`utils::create_encryption_parameters(selection)` in `src/utils.h` looks up the exact
string `"<batch_size>,<num_entries>,<entry_size>"` against a small set of hardcoded
branches:

- `"256,10485,256"` or `"256,10485,32"` → `PlaintextModBitss = 26`, `CoeffMods = {55,55,60}` (2D internal PIR, no merge).
- `"32,1048576,32"`, `"64,1048576,32"`, or `"256,104857,32"` → `PlaintextModBitss = 28`, `CoeffMods = {42,58,58,60}` (3D internal PIR, no merge).
- **Anything else** (any `(batch_size, num_records, record_bytes)` triple not in this exact list) → falls through to the default `PlaintextModBitss = 22`, `CoeffMods = {55,55,48,60}`. This is a **silent fallback**: the binary does not warn or error, it just uses generic SEAL parameters that were not tuned for your data size. The plaintext modulus may then be too small to hold the batch's data without wraparound, which can make decoding **incorrect** while still reporting timings.
- `wrapper.py` mitigates this partially: it checks the binary's `decoded_ok` output field and, if `false`, appends an explicit `"WARNING: decoded entries did NOT match..."` note to `results.json` pointing at the untuned-parameter cause. But the run is **not aborted** — timings are still reported even when correctness fails.

## Output: `results.json`

```json
{
  "scheme": "Vectorized Batch PIR",
  "variant": null,
  "parameters_echo": { "database": {...}, "crypto": {...}, "benchmark": {...} },
  "phases": {
    "setup": { "mean_ms": 0.0, "note": "..." },
    "client_offline_download": { "mean_ms": null, "note": "..." },
    "query_generation": { "mean_ms": 0.0, "note": "..." },
    "server_answer": { "mean_ms": 0.0, "std_dev_ms": 0.0, "all_trials_ms": [...], "num_trials": 5, "note": "..." },
    "client_extract": { "mean_ms": 0.0, "note": "..." }
  },
  "communication": {
    "offline_download_bytes": null,
    "query_upload_bytes": 0,
    "response_bytes": 0
  },
  "unmapped_parameters": { "lattice_dimension": {...} },
  "notes": [ "..." ]
}
```

### `phases` — per-phase measured values

| Field | Measured? | Notes |
|---|---|---|
| `setup.mean_ms` | ✅ Yes — real | Wall-clock time to construct `BatchPIRServer`: synthetic DB generation, cuckoo/simple hashing into buckets, and NTT preprocessing. This is a **real** setup, not a `FakeSetup()` placeholder — unlike SimplePIR's benchmark, this scheme does not skip preprocessing. Measured once (not averaged over trials); client key generation is not separately timed. |
| `client_offline_download.mean_ms` | ❌ **No** — always `null` | There genuinely is no separate offline-download phase to measure: the bucket hash-map (`get_hash_map()`/`set_map()`) and the client's Galois/relinearization keys (`set_client_keys()`) are exchanged in-process via direct function calls, not serialized/timed as a network transfer. This is a structural absence, not a skipped-for-speed optimization. |
| `query_generation.mean_ms` | ✅ Yes — real | Time for `batch_client.create_queries()`: cuckoo-hashes the requested batch of indices into buckets, then BFV-encrypts the per-bucket query vectors. |
| `server_answer.mean_ms` / `std_dev_ms` / `all_trials_ms` | ✅ Yes — real | The headline metric. `generate_response()` is called `num_trials` times (default 5, overridable via `BENCH_TRIALS` env var — **not** a config.json key) on the **same** already-generated queries, after a single setup — i.e. setup cost is amortized out of this measurement by design, mirroring how the paper isolates server compute cost. `std_dev_ms` is `null` when only 1 trial runs. No warmup iteration is discarded (all `num_trials` runs are included in the mean), unlike SimplePIR's convention. |
| `client_extract.mean_ms` | ✅ Yes — real | Time for `batch_client.decode_responses_chunks()`: decrypts and extracts all batch entries from the server's response. Unlike SimplePIR's benchmark (which calls a `RunFakePIR()` that skips `Recover()`), this scheme's benchmark **does** run the real decode step and even verifies it via `check_decoded_entries()` — `decoded_ok` in the raw output, surfaced as a warning note (not a numeric field) in `results.json` when `false`. |

### `communication`

| Field | Measured? | Notes |
|---|---|---|
| `offline_download_bytes` | ❌ Always `null` | Same reason as `client_offline_download.mean_ms` — no serialized offline transfer exists in this in-process benchmark to size. |
| `query_upload_bytes` | ✅ Yes — real | Sum of `ciphertext.save_size()` over every ciphertext in every per-bucket query, computed directly in `main.cpp`. |
| `response_bytes` | ✅ Yes — real | Sum of `ciphertext.save_size()` over the server's response ciphertexts. |

The raw binary also reports a combined `total_comm_kb` (query+response, scheme's own
figure); `wrapper.py` does not put this in a `results.json` field but folds it into a
human-readable `notes` entry alongside the split byte counts above, since the byte-level
split is considered the more precise/canonical figure.

### `unmapped_parameters`

Not part of the canonical output schema's "real data" — this is a deliberate audit
trail. Currently only ever contains:

- `lattice_dimension` — always present, always explains that the ring dimension is fixed at 8192 and the config value was dropped.
- `batch_size` — present **only** when `mode != "batch"` and the config's `batch_size` was something other than `1`/absent, explaining it was ignored and the run forced to `batch_size=1`.

### `notes`

Free-text array, not measured data. Includes: the batch-size/mode explanation, the
decoded-correctness warning (present only on decode failure), the exact FHE
selection-string used and which combinations are actually tuned vs. falling back to
defaults, and a standing reminder that AVX2/Rosetta timings are for pipeline validation
only, not publication numbers.

### Error path

If the binary exits non-zero or crashes (e.g. SIGSEGV/SIGILL, signal reported as
negative return code), or if `/tmp/raw.json` is missing/unparseable after a 0 exit,
`wrapper.py` writes a `results.json` with `"status": "error"`, an `error` message, and
`exit_code` instead of the `phases`/`communication` shape above — there is no partial
results object in the error case.

## Summary: fixed vs. configurable

| Configurable via `config.json` | Fixed / not configurable |
|---|---|
| `database.num_records` (→ `num_entries`; also part of FHE parameter-table lookup key) | `crypto.lattice_dimension` — always ignored; BFV `poly_modulus_degree` hardcoded to 8192 in `database_constants.h` and `utils.h` |
| `database.record_bytes` (→ `entry_size`; also part of FHE parameter-table lookup key) | `PlaintextModBitss` / `CoeffMods` — chosen by a hardcoded lookup table keyed on the exact `(batch_size, num_records, record_bytes)` triple; untuned triples silently fall back to generic (possibly incorrect) defaults |
| `benchmark.mode` (`"batch"` vs `"single"`; gates whether `batch_size` is honored at all) | `NumHashFunctions` (3), `CuckooFactor` (1.2), `MaxAttempts` (500) — cuckoo-hashing constants, no config key exists |
| `benchmark.batch_size` — genuinely honored (this scheme's actual point), but **only when `mode == "batch"`**; forced to 1 otherwise | `client_id` (hardcoded to `0`) |
| `BENCH_TRIALS` env var (not a `config.json` key) — number of `generate_response()` repetitions, default 5 | Any network/transport setting (none exist — client and server run in one process) |
| | `client_offline_download` / `offline_download_bytes` — structurally absent, not just unmeasured (keys/hash-map exchanged in-process, never serialized or timed) |
