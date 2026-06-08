// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Float version of vfu_test_frep_waw_chain.c.
// Tests WAW (Write-After-Write) hazard with transitive RAW dependency chain
// using single-precision floating-point arithmetic:
//
//   (1) vle32.v  v0, (px)      -- 1st WRITE to v0: v0 = x
//   (2) vfadd.vv v1, v0, v0   -- RAW on v0;          v1 = 2*x
//   (3) vfadd.vv v0, v1, v1   -- RAW on v1; 2nd WRITE to v0 (WAW): v0 = 4*x
//   (4) vfadd.vv v2, v0, v1   -- RAW on v0 (2nd) and v1;           v2 = 6*x
//   (5) vse32.v  v2, (pz)      -- store 6*x
//   (6) addi px, px, sz
//   (7) addi pz, pz, sz
//
// Expected: z[i] = 6 * x[i]

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
    float z[VL * n_iter];

    for (int i = 0; i < total; i++) {
        x[i] = (float)(i + 1);
        z[i] = 0.0f;
    }

    float *px = x;
    float *pz = z;

    asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"(VL));

    asm volatile(
        "frep.o %[iter], 7, 0, 0          \n"
        "vle32.v  v0,    (%[px])          \n"  // (1) 1st write v0 = x
        "vfadd.vv v1,    v0, v0           \n"  // (2) RAW v0;  v1 = 2*x
        "vfadd.vv v0,    v1, v1           \n"  // (3) RAW v1;  2nd write v0 = 4*x  [WAW]
        "vfadd.vv v2,    v0, v1           \n"  // (4) RAW v0 (2nd), v1; v2 = 6*x
        "vse32.v  v2,    (%[pz])          \n"  // (5) store 6*x
        "addi     %[px], %[px], %[sz]     \n"  // (6)
        "addi     %[pz], %[pz], %[sz]     \n"  // (7)
        : [ px ] "+r"(px), [ pz ] "+r"(pz)
        : [ iter ] "r"(n_iter - 1), [ sz ] "i"(VL * 4)
        : "v0", "v1", "v2", "memory");

    snrt_fpu_fence();

    int error = 0;
    for (int i = 0; i < total; i++) {
        float expected = 6.0f * x[i];
        if (z[i] != expected) {
            printf("Mismatch at %d: z=%f expected=%f\n", i, (double)z[i],
                   (double)expected);
            error = 1;
        }
    }
    if (!error)
        printf(
            "Float WAW chain test PASS: transitive RAW between writes correct "
            "for %d elements.\n",
            total);
    return error;
#else
    return 0;
#endif
}
