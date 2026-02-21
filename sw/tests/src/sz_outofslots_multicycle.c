// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test that if we run out of reservation station slots we fall back on a regular hw loop mechanism.
// This test is with multicycle instructions

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 10;
    const uint32_t start = 10;
    register volatile uint32_t res asm("a4") = start;
    // force it into a register to use add instead of addi
    register uint32_t increment asm("a5") = 8;
    uint32_t value = 32;
    uint32_t out;
    uint32_t* addr = &value;

    // only use one LSU to quickly exhaust the slots
    szrt_set_frep_mem_consistency(FREP_MEM_SERIALIZED);

    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place the fence in the same asm block as otherwise FPU instructions are placed
        // in between.
        "fmv.x.w t0, fa0   \n"
        "mv      t0, t0\n"
        "fence\n"
        // loop
        "frep.o %[n_frep], 7,         0, 0\n"
        "lw     t0,        0(%[addr])     \n"
        "lw     t1,        0(%[addr])     \n"
        "lw     t2,        0(%[addr])     \n"
        "lw     t3,        0(%[addr])     \n"
        "lw     t4,        0(%[addr])     \n"
        "lw     t5,        0(%[addr])     \n"
        "lw     %[res],    0(%[addr])     \n"
        // outputs
        : [ res ] "=r"(out)
        // inputs - FREP repeats n_frep+1 times
        : [ n_frep ] "r"(n_reps - 1), [ addr ] "r"(addr)
        // clobbers - modified registers beyond the outputs
        : "t0", "t1", "t2", "t3", "t4", "memory");

    if (out != value) {
        return 1;
    }
    return 0;
}