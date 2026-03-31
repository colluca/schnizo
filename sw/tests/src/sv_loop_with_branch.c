// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Stefan Odermatt <soderma@student.ethz.ch>

#include "snrt.h"

// asm volatile(
//     ""
//     /* outputs: [ asm-name ] "constraint" (c-name)
//        To use value use: %asm-name
//        If no asm-name use %0, %1, ... in the order specified
//        constraints (many more, = or + is required for outputs):
//        "=": this variable is overwritten, dont assume previous value is there, except when tied to input.
//        "+": this variable is read and written.
//        "r": this value must reside in a register
//        "m": this value must reside in memory */
//     :
//     /* inputs: same as outputs except = and + are not allowed*/
//     :
//     /* clobbers - modified registers beyond the outputs */
//     :
// );

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 10;
    const uint32_t start = 10;
    register volatile uint32_t res asm("t1") = start;
    // force it into a register to use add instead of addi
    register uint32_t increment asm("t2") = 7;

    register volatile uint32_t is_odd asm ("t3");

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
        "add %[res], %[res], %[inc]\n"  // Simple increment insturction
        "andi %[is_odd], %[res], 1\n"   // Compute if the result is odd or even
        "beq %[is_odd], zero, skipp\n"  // If even skip the next increment
        "add %[res], %[res], %[inc]\n"  // Increment a second time if the result is odd
        "skipp: add %[res], %[res], %[inc]"
        // outputs
        : [ res ] "+r"(res), [ is_odd ] "+r"(is_odd)
        // inputs - FREP repeats n_frep+1 times..
        : [ n_frep ] "r"(n_reps - 1), [ inc ] "r"(increment)
        // clobbers - modified registers beyond the outputs
        : "t0", "memory");

    // reference model (golden result)
    uint32_t expected = start;

    for (uint32_t i = 0; i < n_reps; i++) {
        expected += increment;
        if (expected & 1) {
            expected += increment;
        }
        expected += increment;
    }
    if (res != expected) {
        return 1;
    }
    return 0;
}