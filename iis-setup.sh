#!/usr/bin/env bash
# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Resolve this script's own directory so it can be sourced from anywhere,
# not just when the caller's cwd happens to be the repo root.
SN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define environment variables
export CC=gcc-9.2.0
export CXX=g++-9.2.0
export SN_OSEDA="oseda -2025.07"
export SN_BENDER=bender-0.28.2
export SN_VCS_SEPP=vcs-2024.09
export SN_VERILATOR_SEPP=$SN_OSEDA
export SN_QUESTA_SEPP=questa-2025.3
export SN_YOSYS="$SN_OSEDA yosys"
export SN_LLVM_BINROOT=/usr/scratch2/vulcano/colluca/tools/riscv32-snitch-llvm-almalinux8-15.0.0-snitch-0.5.0/bin

# We need Make >4.3 for grouped targets
export PATH=$SN_ROOT/util/bin:$PATH

# Add simulator binaries to PATH
export PATH=$SN_ROOT/target/sim/build/bin:$PATH

# We use `uv` for managing python dependencies and environments
export PATH=$PATH:/usr/local/uv
# Copy instead link packages from global cache, since the cache is typically
# located on a different file system (e.g. your home directory).
export UV_LINK_MODE=copy

# Bootstrap the Python environment (without changing the caller's cwd)
(cd "$SN_ROOT" && uv sync --all-extras --locked)
source "$SN_ROOT/.venv/bin/activate"

unset SN_ROOT
