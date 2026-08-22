#!/usr/bin/env bash
#
# mayhem/build.sh — build anise's cargo-fuzz targets (upstream anise/fuzz crate) as
# sanitized libFuzzer binaries, plus the upstream test suite (normal flags) so
# mayhem/test.sh only RUNS it.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# Every network fetch below is guarded so a re-run with the artifact already in
# the image is a no-op (test data via download_test_data.sh's own idempotency,
# CSPICE via an existence check, crates via the $CARGO_HOME registry cache).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── Test data (idempotent: download_if_missing skips files already baked in) ──
bash download_test_data.sh

# ── CSPICE (needed by the rust-spice dev-dependency of the test suite) ────────
if [ ! -f cspice/lib/libcspice.a ]; then
  curl -fsSL https://naif.jpl.nasa.gov/pub/naif/toolkit//C/PC_Linux_GCC_64bit/packages/cspice.tar.Z --output cspice.tar.Z
  tar xzf cspice.tar.Z && rm -f cspice.tar.Z
  (cd cspice && tcsh makeall.csh > /dev/null && mv lib/cspice.a lib/libcspice.a)
fi
export CSPICE_DIR="$SRC/cspice"

# ── The upstream test suite, with the project's NORMAL flags (clean build) ────
# Mirrors upstream CI (.github/workflows/rust.yml "Test debug"). test.sh re-runs
# this exact cargo invocation, hitting the build cache produced here.
export LAGRANGE_BSP=gmat-lagrange.bsp
env -u RUSTFLAGS cargo test --no-run --workspace --exclude anise-gui --exclude anise-py

# ── The fuzz targets: OSS-Fuzz Rust libFuzzer+ASan path via cargo-fuzz ────────
# $SANITIZER_FLAGS (clang flags from the base ENV) can't be fed to rustc directly;
# translate its intent: sanitizers ON (the default) → ASan via -Zsanitizer=address,
# an explicitly EMPTY SANITIZER_FLAGS → no sanitizer.
RUST_SAN="-Zsanitizer=address"
[ -z "${SANITIZER_FLAGS+x}" ] || [ -n "${SANITIZER_FLAGS}" ] || RUST_SAN=""
# DWARF <= 3 debug info for triage (SPEC §6.2 item 10) — threaded via RUST_DEBUG_FLAGS.
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Cforce-frame-pointers"
# The cc-built libFuzzer runtime honours CFLAGS/CXXFLAGS, and --build-std recompiles
# std with our RUSTFLAGS (the prebuilt std ships DWARF-4 debuginfo).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"
# rustc's prebuilt sanitizer runtimes (compiler-rt) ship DWARF-5 CUs; strip their
# debug info so the linked fuzz binaries stay DWARF <= 3 (runtime frames are never
# triaged as project bugs). Idempotent: stripping a stripped archive is a no-op.
find "$RUSTUP_HOME"/toolchains/*/lib/rustlib/x86_64-unknown-linux-gnu/lib \
  -name 'librustc-*_rt.*.a' -exec objcopy --strip-debug {} \;

FUZZ_DIR="anise/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# The historical Mayhem target set (parity with archive/original-master).
FUZZ_TARGETS=(
  almanac_describe
  common_ephemeris_path
  euler_parameter_dataset
  fuzz_metadata
  load_from_bytes
  parse_bpc
  parse_spk
  planetary_dataset
  spacecraft_dataset
  try_find_ephemeris_root
)

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" --build-std -O --debug-assertions "$t"
  bin=""
  for cand in "$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t" "$SRC/target/$TRIPLE/release/$t"; do
    [ -x "$cand" ] && bin="$cand" && break
  done
  [ -n "$bin" ] || { echo "ERROR: expected fuzz binary for $t not found" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete"
