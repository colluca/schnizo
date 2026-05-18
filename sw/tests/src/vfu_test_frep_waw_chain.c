// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Tests WAW (Write-After-Write) hazard and consequent fallback to HW-Loop
// Here the two writes are separated by a transitive RAW dependency chain:
//
//   (1) vle32.v v0, (px)    -- 1st WRITE to v0: v0 = x
//   (2) vadd.vv v1, v0, v0  -- RAW on v0;         v1 = 2*x
//   (3) vadd.vv v0, v1, v1  -- RAW on v1; 2nd WRITE to v0 (WAW): v0 = 4*x
//   (4) vadd.vv v2, v0, v1  -- RAW on v0 (2nd write) and v1;     v2 = 6*x
//   (5) vse32.v v2, (pz)    -- store 6*x
//   (6) addi px, px, sz
//   (7) addi pz, pz, sz
//
// The first value of v0 (= x) must be visible to instruction (2) before
// instruction (3) overwrites v0.  If the WAW is mishandled and (3) writes v0
// before (2) reads it, instruction (2) produces 2*(4*x) = 8*x instead of
// 2*x, and the final result deviates from the expected 6*x.
// This is distinct from vfu_test_frep_multi_write, where the second write is
// an independent load rather than a value derived from the first write.

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

    asm volatile(
        "frep.o %[iter], 7, 0, 0          \n"
        "vle32.v  v0,    (%[px])          \n"  // (1) 1st write v0 = x
        "vadd.vv  v1,    v0, v0           \n"  // (2) RAW v0;  v1 = 2*x
        "vadd.vv  v0,    v1, v1           \n"  // (3) RAW v1;  2nd write v0 = 4*x  [WAW]
        "vadd.vv  v2,    v0, v1           \n"  // (4) RAW v0 (2nd), v1; v2 = 6*x
        "vse32.v  v2,    (%[pz])          \n"  // (5) store 6*x
        "addi     %[px], %[px], %[sz]     \n"  // (6)
        "addi     %[pz], %[pz], %[sz]     \n"  // (7)
        : [ px ] "+r"(px), [ pz ] "+r"(pz)
        : [ iter ] "r"(n_iter - 1), [ sz ] "i"(VL * 4)
        : "v0", "v1", "v2", "memory");

    snrt_fpu_fence();

    int error = 0;
    for (int i = 0; i < total; i++) {
        int32_t expected = 6 * x[i];
        if (z[i] != expected) {
            printf("Mismatch at %d: z=%d expected=%d\n", i, z[i], expected);
            error = 1;
        }
    }
    if (!error)
        printf(
            "WAW chain test PASS: transitive RAW between writes correct for %d "
            "elements.\n",
            total);
    return error;
#else
    return 0;
#endif
}
