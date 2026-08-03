// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "snrt.h"

#ifndef FREP
#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif
#endif

// Load-use-store kernel: frep.o → scalar (no unroll).
// Scalar: flw + fmul.s + fsw + addi = 4 insns, n_frep = n - 1.
static inline void scal_fp32_schnizo(float alpha, float *x, uint32_t n) {
    int n_frep = n - 1;
    float *x2 = x;
    asm volatile(FREP
                 " %[n], 5, 0, 0               \n"
                 "flw    fa0,  0(%[x1])              \n"
                 "fmul.s fa0, fa0, %[alpha]          \n"
                 "fsw    fa0,  0(%[x2])              \n"
                 "addi   %[x1], %[x1], 4             \n"
                 "addi   %[x2], %[x2], 4             \n"
                 : [x1] "+r"(x), [x2] "+r"(x2)
                 : [n] "r"(n_frep), [alpha] "f"(alpha)
                 : "fa0", "memory");
}
