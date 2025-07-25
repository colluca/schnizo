// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

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

// Stores don't generate a result and thus the RS must track store instructions in a special manner.
// This test checks that if only a store is captured in an RS, the RS result counter stops at
// zero iterations.
uint32_t storage_location = 32;

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 10;
    const uint32_t new_value = 42;
    uint32_t old_value;

    old_value = storage_location;
    uint32_t *addr = &storage_location;

    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place the fence in the same asm block as otherwise FPU instructions are placed
        // in between.
        "fmv.x.w t0, fa0\n"
        "mv      t0, t0\n"
        "fence\n"
        // loop
        "frep.o %[n_frep], 1, 0, 0\n"
        "sw     %[value],  0(%[addr])\n"
        // fence to ensure load of test below is after the stores
        "fmv.x.w t0, fa0\n"
        "mv      t0, t0\n"
        "fence\n"
        // outputs
        :
        // inputs - FREP repeats n_frep+1 times..
        : [n_frep]"r"(n_reps-1), [value]"r"(new_value), [addr]"r"(addr)
        // clobbers - modified registers beyond the outputs
        : "t0", "memory"
    );


    if (storage_location != new_value) {
        return 1;
    }
    return 0;
}