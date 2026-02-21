// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// ---------------------------
// Program A
// ---------------------------
// Program A: Two conflicting loop carried dependencies - Deadlock in LCP2
//  frep n, 2
//  addi t2, t1, 8  // Instruction A0
//  addi t1, t1, 8  // Instruction A1
//
// The following analysis is based on one ALU+RS with two RSS. However, it does apply
// to any configuration (i.e., two instructions for different FUs).
//
// If we execute this loop and rename the registers with a result name like
// - A0.0: result of instruction A0 of iteration "0" / the initial value
// - A0.1: result of instruction A0 of iteration "1"
//
// the execution trace looks like this (arrows depict RAW dependencies / operand requests):
//
// Iteration 1, LCP1: addi A0.1, A1.0, 8
//                    addi A1.1, A1.0, 8 <--+      <--+
//                                          | (1)     | (2)
// Iteration 2, LCP2: addi A0.2, A1.1, 8  --+         |
//                    addi A1.2, A1.1, 8  ------------+  <--+      <--+
//                                                          | (3)     | (4)
// Iteration 3, LEP:  addi A0.3  A1.2, 8  ------------------+         |
//                    addi A1.3, A1.2, 8  ----------------------------+
//
// Timeline (LC = loop carried):
//
// Time                After LCP1    Cycle 1    Cycle 2
//                   +-------------+----------+----------+
// A0    Step        |      -      |  F1+E1   |    F0    |
//       Result iter |      0      |  0 -> 1  |    1     |
//                   +-------------+----------+----------+
//                                      |       |
//                  (1), is LC -> itr=0 | ok    | (3), itr=1
//                                      |       |
//                                      |       | here (2) and (3) conflict
//                                      |       |
//                                      |       |  +---+
//                                      |       |  |   | (2), is LC -> itr=0
//                                      v       v  v   |
//                   +-------------+----------+----------+
// A1    Step        |      -      | Stall    |  F1+E1   |
//       Result iter |      0      |   0      |  0 -> 1  |
//                   +-------------+----------+----------+
//
// Problem:
//  This program deadlocks in the 2nd cycle of LCP2. Because the requests to A1 are incoming in
//  the order: (1), (3) // (2), (4). Where // means at the same time.
//  Now if (3) has higher prio than (2), then (3) blocks the (2) forever.
//
// Reason:
//  The previous instruction (A0) is already requesting the next iteration of this
//  result before the instruction itself (A1) did read its old result. Therefore, the
//  request from A0 blocks the result request interface.
//
// Solution:
//  Do not request operands in LCP2 at all (currently we start fetching when we
//  dispatched in LCP2). However, this would only solve LCP2. In LEP it depends on the
//  request priority. This order depends on which instruction is placed in which RSS.
//  A cleaner solution would be to implement a request priority based on the requested
//  iteration. Alternatively we could create two ports, one for each iteration. this is possible
//  as we track only whether we are in the current or next iteration. For dependencies the naming
//  previous / current iteration is maybe more clear.
//
// Detailed analysis:
//
// In the loop we can identify two loop carried RAW dependencies marked as (1) and (2).
// The dependency (3) is the same as (1) but for the next iteration. This dependency (3) targets
// the same RSS as (1) but for an other iteration result (iteration 2). The same applies for (2)
// and (4).
//
// During LCP1 we execute serially and a issued instruction / RSS does not directly
// place a request for the operands. Reason is that we are not certain if the current
// producer is the correct one. There could be another one in LCP2.
//
// In LCP2 we still execute serially however after issuing the instruction the RSS can directly
// place a operand request to the producer.
//
// In this simple loop this leads to a deadlock after the first cycle in LCP2.
// The following analysis also applies to LEP depending on how the instructions are dispatched
// into RSSs. The LCP2 case is however the most general case.
// We start in the first cycle of LCP2 where we try to dispatch A0:
// - The instruction A0 first fetches the operand from A1. This works as the result of iteration 1
//   is ready and no other request is alive / competing to read the value.
// - Then A0 is issued and we complete this cycle.
//
// In the following cycle, we want to dispatch A1. But at the same time A0 wants to fetch its
// operands for iteration 3. Thus we have two requests to the RSS of A1.
// - A1.2 wants to read iteration 1 of A1. This is dependency (2).
// - A0.3 wants to read iteration 2 of A1. This is dependency (3).
//
// Now depending on the request arbitration we can have a deadlock. If the request from A0.3 is
// prioritized, then the instruction A1.2 stalls forever as it cannot fetch its operands.
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
        "addi   t2, t1, 8\n"  // Instruction A0
        "addi   t1, t1, 8"  // A1 <-- This instruction stalls in LCP2 and also in LEP
        // outputs
        :
        // inputs - FREP repeats n_frep+1 times
        : [ n_frep ] "r"(n_reps - 1)
        // clobbers - modified registers beyond the outputs
        : "t0", "t1", "t2", "memory");

    return 0;
}