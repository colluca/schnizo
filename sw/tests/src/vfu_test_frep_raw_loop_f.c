// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Float version of vfu_test_frep_raw_loop.c.
// Tests loop-carried RAW (inter-iteration RAW) in vector frep using
// single-precision floating-point accumulation.
// The accumulator v0 is both read and written by vfadd.vv v0, v0, v1 in every
// iteration.  Iteration N+1 must read the value written by iteration N.

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

#define VL 8

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    int n_iter = 4;
    int total = VL * n_iter;

    float x[VL * n_iter];
    float acc[VL];

    for (int i = 0; i < total; i++) x[i] = (float)(i + 1);

    float *px = x;

    // Initialise accumulator register to 0.0 before the frep loop.
    asm volatile(
        "vsetvli zero, %[vl], e32, m1, ta, ma  \n"
        "vfmv.v.f v0, %[zero]                  \n"
        :
        : [ vl ] "r"(VL), [ zero ] "f"(0.0f)
        : "v0");

    // Body (3 instructions):
    //   v1  = x[iter*VL .. (iter+1)*VL - 1]  (load current chunk)
    //   v0 += v1                              (loop-carried RAW on v0)
    //   advance px
    asm volatile(
        "frep.o %[iter], 3, 0, 0          \n"
        "vle32.v  v1,    (%[px])          \n"
        "vfadd.vv v0,    v0, v1           \n"
        "addi     %[px], %[px], %[sz]     \n"
        : [ px ] "+r"(px)
        : [ iter ] "r"(n_iter - 1), [ sz ] "i"(VL * 4)
        : "v0", "v1", "memory");

    // Store final accumulator so C can verify it.
    asm volatile("vse32.v v0, (%[acc])" : : [ acc ] "r"(acc) : "memory");

    snrt_fpu_fence();

    // Expected: acc[j] = sum of x[k*VL + j] for k in 0 .. n_iter-1
    int error = 0;
    for (int j = 0; j < VL; j++) {
        float expected = 0.0f;
        for (int k = 0; k < n_iter; k++) expected += x[k * VL + j];
        if (acc[j] != expected) {
            printf("Lane %d: acc=%f expected=%f\n", j, (double)acc[j],
                   (double)expected);
            error = 1;
        }
    }
    if (!error)
        printf("Float loop-carried RAW test PASS: fp accumulation correct.\n");
    return error;
#else
    return 0;
#endif
}
