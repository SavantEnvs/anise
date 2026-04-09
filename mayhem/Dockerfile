FROM --platform=linux/amd64 ubuntu:22.04 AS builder

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl git tcsh libc++-dev libc++abi-dev build-essential && \
    rm -rf /var/lib/apt/lists/*

# Install Rust nightly + cargo-fuzz
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install -f cargo-fuzz

# Build CSPICE (static library required by anise)
ADD . /anise
WORKDIR /anise
RUN curl https://naif.jpl.nasa.gov/pub/naif/toolkit//C/PC_Linux_GCC_64bit/packages/cspice.tar.Z --output cspice.tar.Z && \
    tar xzvf cspice.tar.Z && cd cspice && tcsh makeall.csh && mv lib/cspice.a lib/libcspice.a

# Build all fuzz targets
WORKDIR /anise/anise
RUN RUSTFLAGS="-C link-arg=-lc++" cargo fuzz build -O

FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y libc++1 && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /targets
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/almanac_describe /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/parse_spk /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/parse_bpc /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/load_from_bytes /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/fuzz_metadata /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/common_ephemeris_path /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/try_find_ephemeris_root /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/spacecraft_dataset /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/planetary_dataset /targets/
COPY --from=builder /anise/target/x86_64-unknown-linux-gnu/release/euler_parameter_dataset /targets/
