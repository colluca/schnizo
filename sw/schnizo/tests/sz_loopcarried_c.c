// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"
// ---------------------------
// Program C
// ---------------------------
// Program C: Combination of sz_loopcarried A & B
//  frep n, 2
//  add  t0, t1, t0 // Instruction A0
//  add  t1, t1, t0 // Instruction A1
//
// This is the combination of the cases of A & B.
// Trace (dependencies in LCP1 not drawn):
// Iteration 1, LCP1: add A0.1, A0.0, A1.0  <-----------+
//                    add A1.1, A0.1, A1.0  <----+      |  <---------+
//                                           (1) |  (2) |            |
// Iteration 2, LCP2: add A0.2, A0.1, A1.1  -----+------+  <--+      |  <---------+
//                                                        (3) |  (4) |            |
//                    add A1.2, A0.2, A1.1  ------------------+------+  <--+      |  <---------+
//                                                                     (5) |  (6) |            |
// Iteration 3, LEP:  add A0.3, A0.2, A1.2  -------------------------------+------+  <--+      |
//                                                                                  (7) |  (8) |
//                    add A1.3, A0.3, A1.2  --------------------------------------------+------+
//
// This will deadlock as explained in A & B. When we issue A0.2, the requests (5) and (6) come
// alive. Therefore, (3) competes with (6) and (4) competes with (5).
//

int main() {
    const uint32_t n_reps = 5;

    // ---------------------------
    // Program C
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
        "frep.o %[n_frep], 2,  0, 0\n"
        "add    t0, t1, t0\n" // Instruction A0
        "add    t1, t1, t0"   // Instruction A1
        // outputs
        :
        // inputs - FREP repeats n_frep+1 times
        : [n_frep]"r"(n_reps-1)
        // clobbers - modified registers beyond the outputs
        : "t0", "t1", "t2", "memory"
    );

    return 0;
}