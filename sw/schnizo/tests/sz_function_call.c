// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test wether we properly fall back into HW loop mode if we encounter a jump instruction.

int main() {
    const uint32_t n_reps = 20;
    const uint32_t start = 10;
    register volatile uint32_t res asm("t1") = start;
    register volatile uint32_t increment asm("t2") = 8;

    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place the fence in the same asm block as otherwise FPU instructions are placed
        // in between.
        "fmv.x.w t0, fa0               \n"
        "mv      t0, t0                \n"
        "fence                         \n"
        "jal     x0, sz_loop           \n"
        // Function to be called within loop
        "sz_add_inc:                   \n"
        "add     %[res], %[res], %[inc]\n"
        "jalr    x0,     0(t0)         \n"
        // The actual loop
        "sz_loop:\n"
        "frep.o %[n_frep], 3,         0,     0\n"
        "add    %[res],    %[res],    %[inc]  \n"
        "jal    t0,        sz_add_inc         \n"
        // The last instruction of a loop may not be a jump as we otherwise cannot return properly
        "add    %[res],    %[res],    %[inc]  \n"
        // outputs
        : [res]"+r"(res)
        // inputs - FREP repeats n_frep+1 times
        : [n_frep]"r"(n_reps-1), [inc]"r"(increment)
        // clobbers - modified registers beyond the outputs
        : "t0", "memory"
    );

    if (res != (start + (3 * increment * n_reps))) {
        return 1;
    }

  return 0;
}