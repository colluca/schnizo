// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Tests a depth-3 RAW dependency chain within a single frep body iteration:
//   vle -> vadd (depth 1) -> vadd (depth 2) -> vadd (depth 3) -> vse
// Each vadd reads the result of the immediately preceding vadd.  The hardware
// must stall or forward correctly at all three levels before issuing the next
// dependent instruction.

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
    int32_t z[VL * n_iter];

    for (int i = 0; i < total; i++) {
        x[i] = i + 1;
        z[i] = 0;
    }

    int32_t *px = x;
    int32_t *pz = z;

    asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"(VL));

    // Body (7 instructions):
    //   v0 = x             (load)
    //   v1 = v0 + v0 = 2x (RAW on v0: depth 1)
    //   v2 = v1 + v1 = 4x (RAW on v1: depth 2)
    //   v3 = v2 + v2 = 8x (RAW on v2: depth 3)
    //   store v3
    //   advance px, pz
    asm volatile(
        "frep.o %[iter], 7, 0, 0          \n"
        "vle32.v  v0,    (%[px])          \n"
        "vadd.vv  v1,    v0, v0           \n"
        "vadd.vv  v2,    v1, v1           \n"
        "vadd.vv  v3,    v2, v2           \n"
        "vse32.v  v3,    (%[pz])          \n"
        "addi     %[px], %[px], %[sz]     \n"
        "addi     %[pz], %[pz], %[sz]     \n"
        : [ px ] "+r"(px), [ pz ] "+r"(pz)
        : [ iter ] "r"(n_iter - 1), [ sz ] "i"(VL * 4)
        : "v0", "v1", "v2", "v3", "memory");

    snrt_fpu_fence();

    int error = 0;
    for (int i = 0; i < total; i++) {
        int32_t expected = 8 * x[i];
        if (z[i] != expected) {
            printf("Mismatch at %d: z=%d expected=%d\n", i, z[i], expected);
            error = 1;
        }
    }
    if (!error)
        printf(
            "RAW chain test PASS: depth-3 forwarding correct for %d "
            "elements.\n",
            total);
    return error;
#else
    return 0;
#endif
}
