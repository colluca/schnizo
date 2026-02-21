// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Program to test intra-loop dependencies.
// This program checks only for deadlocks not the correctness.

// Same program as sz_intraloop_chain but with multicycle instructions.
// The instruction A2 deadlocks because the request for t1 from A1 (for the next iteration) gets
// priority over the request from A2.

uint32_t x = 314159;

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 5;
    uint32_t* ptr = &x - 1;  // offset ptr for addi instruction

    // ---------------------------
    // sz_intraloop_chain but with multicyle instructions
    // ---------------------------
    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place the fence in the same asm block as otherwise FPU instructions are placed
        // in between.
        "fmv.x.w t0, fa0   \n"
        "mv      t0, t0\n"
        "fence\n"
        // loop
        "frep.o %[n_frep], 3, 0, 0\n"
        "addi   t1,        %[addr], 4 \n"  // Instruction A0
        "lw     t2,        0(t1)      \n"  // Instruction A1
        "add    t3,        t2,      t1"    // Instruction A2 - deadlocks
        // outputs
        :
        // inputs - FREP repeats n_frep+1 times
        : [ n_frep ] "r"(n_reps - 1), [ addr ] "r"(ptr)
        // clobbers - modified registers beyond the outputs
        : "t0", "t1", "t2", "t3", "memory");

    // This program checks only for deadlocks not the correctness.
    return 0;
}