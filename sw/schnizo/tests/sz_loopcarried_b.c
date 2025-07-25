// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// ---------------------------
// Program B
// ---------------------------
// Program B: Collision of intra and loop carried dependencies - Deadlock in LEP
//  frep n, 2
//  addi t1, t1, 8  // Instruction A0
//  addi t2, t1, 8  // Instruction A1
//
// Trace
// Iteration 1, LCP1: addi A0.1, A0.0, 8  <--+      <--+
//                                           | (1)     | (2)
//                    addi A1.1, A0.1, 8   --+         |
// Iteration 2, LCP2: addi A0.2, A0.1, 8   ------------+    <--+      <--+
//                                                             | (3)     | (4)
//                    addi A1.2, A0.2, 8   --------------------+         |
// Iteration 3, LEP:  addi A0.3, A0.2, 8   ------------------------------+    <--+     <--+
//                                                                               | (5)    | (6)
//                    addi A1.3, A0.3, 8   --------------------------------------+        |
// Iteration 4, LEP:  addi A0.4, A0.3, 8   -----------------------------------------------+
//                    addi A1.4, A0.4, 8   --> to A0.4 (7)
//
// Dependencies:
// Intra loop:   (1), (3), (5)
// Loop carried: (2), (4)
//
// Timeline:
// Time                After LCP1    Cycle 1      Cycle 2
//                   +-------------+------------+------------+
// A0    Step        |      -      |  F1+E1     |    F0      |
//       Result iter |      0      |  0 -> 1    |    1       |
//                   +-------------+------------+------------+
//                                   |   ^        |   ^  ^
//               (2), is LC -> itr=0 |   |    (4) |   |  |
//                                   +---+        +---+  |
//                                               itr=1   |
//                                                       |
//                                          (3) -> itr=1 |
//                                                       |
//                                                       |
//                   +-------------+--------  --+------------+
// A1    Step        |      -      | Stall      |  F1+E1     |
//       Result iter |      0      |   0        |  0 -> 1    |
//                   +-------------+------------+------------+
//
// The dependencies (3) & (4) collide but request the same iteration. Thus we only have an impact
// on performance but no deadlock in LCP2. However, there is a deadlock in LEP.
//
// Let us assume we serve (3) before (4).
// Then we can finish A1.2 but (4) is still outstanding. In addition, (5) comes alive.
// Now we enter LEP where we have the requests (4) and (5) alive. Both target A0
// but (4) targets A0.2 whereas (5) targets A0.3. So we have a collision and deadlock depending on
// the priority. We deadlock if (5) has higher prio than (4).
//
// If (4) were to be serve before (3), we would simply loose a cycle in LCP2 but won't
// deadlock in LEP. This is actually the case when using the naive stream xbar implementation.
// Therefore, this test passes with one extra cycle despite it could deadlock with opposite
// priority.
//

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 5;

    // ---------------------------
    // Program B
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
        "addi   t1, t1, 8\n" // Instruction A0
        "addi   t2, t1, 8"   // Instruction A1
        // outputs
        :
        // inputs - FREP repeats n_frep+1 times
        : [n_frep]"r"(n_reps-1)
        // clobbers - modified registers beyond the outputs
        : "t0", "t1", "t2", "memory"
    );

    return 0;
}