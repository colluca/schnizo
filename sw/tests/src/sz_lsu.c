// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test wether the LSU offset immediate is correctly used.

#define NofElements 16

double x[NofElements] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

double sum_exp = 136;  // the sum of all integers from 1 to 16

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = NofElements;
    register volatile double res asm("ft1") = 0;
    // switch addi and fld and add constant fld offset -> subtract two elements
    double* addr = &x[0] - 2;

    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place the fence in the same asm block as otherwise FPU instructions are placed
        // in between.
        "fmv.x.w t0, fa0   \n"
        "mv      t0, t0\n"
        "fence\n"
        // loop
        "frep.o %[n_frep], 3,         0, 0\n"
        "addi   %[addr],   %[addr],   8   \n"  // switch order of addi and fld to prevent deadlock
        "fld    ft0,       8(%[addr])     \n"  // <--- Testcase: Is this offset of 8 applied correctly?
        "fadd.d %[res],    %[res],    ft0"
        // outputs
        : [ res ] "+fr"(res), [ addr ] "+r"(addr)
        // inputs - FREP repeats n_frep+1 times..
        : [ n_frep ] "r"(n_reps - 1)
        // clobbers - modified registers beyond the outputs
        : "t0", "ft0", "memory");

    if ((res - sum_exp) > 0.001) {
        return 1;
    }
    return 0;
}