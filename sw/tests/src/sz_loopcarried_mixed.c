// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"
// ---------------------------
// Program A
// ---------------------------
// Program A: Intra and loop carried dependencies
//  frep n, 2
//  addi t1, t2, 8  // Instruction A0
//  addi t2, t1, 8  // Instruction A1
//
// Trace
// Iteration 1, LCP1: addi A0.1, A0.0, 8  <--+
//                                           | (1)
//                    addi A1.1, A0.1, 8   --+      <--+
//                                                     | (2)
// Iteration 2, LCP2: addi A0.2, A0.1, 8   ------------+    <--+
//                                                             | (3)
//                    addi A1.2, A0.2, 8   --------------------+    <--+
//                                                                     | (4)
// Iteration 3, LEP:  addi A0.3, A0.2, 8   ----------------------------+    <--+
//                                                                             | (5)
//                    addi A1.3, A0.3, 8   ------------------------------------+    <--+
//                                                                                     | (6)
// Iteration 4, LEP:  addi A0.4, A0.3, 8   --------------------------------------------+
//                    addi A1.4, A0.4, 8   --> to A0.4 (7)
//
// Timeline:
// Time                After LCP1    Cycle 1      Cycle 2
//                   +-------------+------------+------------+
// A0    Step        |      -      |  F1+E1     |    F0      |
//       Result iter |      0      |  0 -> 1    |    1       |
//                   +-------------+------------+------------+
//                                   |            |      ^
//               (2), is LC -> itr=0 |        (4) |      |
//                                   |      itr=1 |      |
//                                   |            |      |
//                                   |            |      |
//                                   |            |      | (3) -> itr=1
//                                   |            |      |
//                                   v            v      |
//                   +-------------+--------  --+------------+
// A1    Step        |      -      | Stall      |  F1+E1     |
//       Result iter |      0      |   0        |  0 -> 1    |
//                   +-------------+------------+------------+
//
// We don't have a collision. This should never deadlock.
//

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 5;

    // ---------------------------
    // Program A
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
        // This case uses only one ALU but is also applicable if the two instructions were
        // allocated on two separate FUs.
        "frep.o %[n_frep], 2, 0, 0\n"
        "addi   t1, t2, 8\n"  // Instruction A0
        "addi   t2, t1, 8"    // Instruction A1
        // outputs
        :
        // inputs - FREP repeats n_frep+1 times
        : [ n_frep ] "r"(n_reps - 1)
        // clobbers - modified registers beyond the outputs
        : "t0", "t1", "t2", "memory");

    return 0;
}