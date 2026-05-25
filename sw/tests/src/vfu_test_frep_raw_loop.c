// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Tests loop-carried RAW (inter-iteration RAW) in vector frep.
// The accumulator v0 is both read and written by the same instruction
// (vadd.vv v0, v0, v1) in every iteration.  Iteration N+1 must read the
// value written by iteration N; if the hardware does not correctly stall or
// forward across iteration boundaries, the accumulated sum will be wrong.
// This exercises integer accumulation; floating-point loop-carried RAW is
// already covered by the vfmacc-based gemm frep tests.

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

#define VL 8

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    int n_iter = 4;
    int total = VL * n_iter;

    int32_t x[VL * n_iter];
    // For some reason if this isn't added the stackalignment is completly screwd up
    // and the acc has an offset by one...
    int32_t acc[VL];

    for (int i = 0; i < total; i++) x[i] = i + 1;

    int32_t *px = x;

    // Initialise accumulator register to zero before the frep loop.
    asm volatile(
        "vsetvli zero, %[vl], e32, m1, ta, ma  \n"
        "vmv.v.i v0, 0                          \n"
        :
        : [ vl ] "r"(VL)
        : "v0");

    // Body (3 instructions):
    //   v1  = x[iter*VL .. (iter+1)*VL - 1]  (load current chunk)
    //   v0 += v1                              (loop-carried RAW on v0)
    //   advance px
    asm volatile(
        "frep.o %[iter], 3, 0, 0          \n"
        "vle32.v  v1,    (%[px])          \n"
        "vadd.vv  v0,    v0, v1           \n"
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
        int32_t expected = 0;
        for (int k = 0; k < n_iter; k++) expected += x[k * VL + j];
        if (acc[j] != expected) {
            printf("Lane %d: acc=%d expected=%d\n", j, acc[j], expected);
            error = 1;
        }
    }
    if (!error)
        printf("Loop-carried RAW test PASS: integer accumulation correct.\n");
    return error;
#else
    return 0;
#endif
}
