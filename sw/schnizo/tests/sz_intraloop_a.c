// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Program to test intra-loop dependencies.
// This program checks only for deadlocks not the correctness.

// Program A: Colliding requests:
//  frep n, 3
//  addi t1, t0, 8 // Instruction A0
//  addi t2, t1, 8 // Instruction A1
//  addi t3, t1, 8 // Instruction A2
//
// Trace:
// Iteration 1, LCP1: addi A0.1, t0,   8 <--+      <--+
//                                          | (1)     | (2)
//                    addi A1.1, A0.1, 8  --+         |
//                    addi A2.1, A0.1, 8  ------------+
// Iteration 2, LCP2: addi A0.2, t0,   8 <--+      <--+
//                                          | (3)     | (4)
//                    addi A1.2, A0.2, 8  --+         |
//                    addi A2.2, A0.2, 8  ------------+
// Iteration 3, LEP:  addi A0.3, t0  , 8 <--+      <--+
//                                          | (5)     | (6)
//                    addi A1.3, A0.3, 8  --+         |
//                    addi A2.3, A0.3, 8  ------------+
//
// We can see two RAW dependencies which target the same RSS, (1) & (2).
// In LCP1 there is no problem as the requests are serialized.
// In LCP2 the (3) is placed first and A1 can execute. This brings the dependency (5) alive for the
// next cycle. Now A2 places the request (4) to A0. But to A0 there is also the request (5)
// pending. Depending on how the request priority is, we can deadlock.
// - If (4) is prioritized there is no problem.
// - If (5) is prioritized we deadlock because A2 cannot execute due to the blocked (4).
//
// This priority is implementation dependent. In the naive stream xbar implementation the
// priority depends on the arb tree. The arbitration tree will choose the input with the same index
//  as currently defined by the state if it has an active request. Because the request (3) is
// served, the index stays at the port from A1 and thus prioritizing (5) over (4) leading to a
// deadlock.
//

int main() {
    const uint32_t n_reps = 5;

    // ---------------------------
    // Program A: Same RS - priority leads to deadlock
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
        "addi t1, t0, 8\n" // Instruction A0
        "addi t2, t1, 8\n" // Instruction A1
        "addi t3, t1, 8\n" // Instruction A2 - A1 has higher prio than A2 - deadlocks A2
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