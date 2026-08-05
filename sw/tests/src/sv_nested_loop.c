// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Stefan Odermatt <soderma@student.ethz.ch>

#include "snrt.h"

// Program to test if a nested loop within an FREP loop behaves as
// expected. The inner loop is done via branch instructions.

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 10;
    const uint32_t start = 10;
    register volatile uint32_t res asm("t1") = start;
    // force it into a register to use add instead of addi
    register uint32_t increment asm("t2") = 7;

    register volatile uint32_t cnt asm("t3") = 3;

    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place the fence in the same asm block as otherwise FPU instructions are placed
        // in between.

        // This program increments the result 2 times unconditionally and a third time only if the
        // result after the first increment is odd.
        "fmv.x.w t0, fa0   \n"
        "mv      t0, t0\n"
        "fence\n"
        // loop
        "frep.o %[n_frep], 5, 0, 0\n"
        "inner_loop: add %[res], %[res], %[inc]\n"  // Increment the result
        "addi %[cnt], %[cnt], -1\n"  // Decrement the inner loop counter
        "bnez %[cnt], inner_loop\n"  // If the counter is not zero, repeat the inner loop
        "add %[cnt], zero, 3"  // Reset the inner loop counter to 3
        // outputs
        : [ res ] "+r"(res), [ cnt ] "+r"(cnt)
        // inputs - FREP repeats n_frep+1 times..
        : [ n_frep ] "r"(n_reps - 1), [ inc ] "r"(increment)
        // clobbers - modified registers beyond the outputs
        : "t0", "memory");

    // reference model (golden result)
    uint32_t expected = start;

    for (uint32_t i = 0; i < n_reps; i++) {
        uint32_t inner_cnt = 3;
        while (inner_cnt > 0) {
            expected += increment;
            inner_cnt--;
        }
    }
    if (res != expected) {
        return res;
    }
    return 0;
}