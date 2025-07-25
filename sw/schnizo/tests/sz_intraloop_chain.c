// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Program to test intra-loop dependencies.
// This program checks only for deadlocks not the correctness.

// A chain of RAW hazards & collision
//  frep n, 3
//  addi t1, t0, 8  // Instruction A0
//  addi t2, t1, 8  // Instruction A1 - A1 has lower prio than A2 - deadlock avoided
//  add  t3, t2, t1 // Instruction A2
//
// Iteration 1, LCP1: addi A0.1, t0,   8    <--+      <---------+
//                                             | (1)            |
//                    addi A1.1, A0.1, 8     --+      <--+      | (3)
//                                                       | (2)  |
//                    add  A2.1, A1.1, A0.1  ------------+------+
//
// This program has the same behaviour as program "sz_intraloop_a" except there is the additional
// request (2). However, it will deadlock in the same way depending on the priority. The (2) adds
// no additional problematic as there is no collision.
//

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 5;

    // ---------------------------
    // Program: A chain of RAW hazards & collision
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
        "addi t1, t0, 8 \n" // Instruction A0
        "addi t2, t1, 8 \n" // Instruction A1
        "add  t3, t2, t1\n" // Instruction A2 - deadlocks
        // outputs
        :
        // inputs - FREP repeats n_frep+1 times
        : [n_frep]"r"(n_reps-1)
        // clobbers - modified registers beyond the outputs
        : "t0", "t1", "t2", "t3", "memory"
    );

    // This program checks only for deadlocks not the correctness.
    return 0;
}