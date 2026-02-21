// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test that if we run out of reservation station slots we fall back on a regular hw loop mechanism.

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 10;
    const uint32_t start = 10;
    register volatile uint32_t res asm("t1") = start;
    // force it into a register to use add instead of addi
    register uint32_t increment asm("t2") = 8;

    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place the fence in the same asm block as otherwise FPU instructions are placed
        // in between.
        "fmv.x.w t0, fa0   \n"
        "mv      t0, t0\n"
        "fence\n"
        // loop
        "frep.o %[n_frep], 14,     0,     0\n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        "add    %[res],    %[res], %[inc]  \n"
        // outputs
        : [ res ] "+r"(res)
        // inputs - FREP repeats n_frep+1 times
        : [ n_frep ] "r"(n_reps - 1), [ inc ] "r"(increment)
        // clobbers - modified registers beyond the outputs
        : "t0", "memory");

    if (res != (start + (14 * increment * n_reps))) {
        return 1;
    }
    return 0;
}