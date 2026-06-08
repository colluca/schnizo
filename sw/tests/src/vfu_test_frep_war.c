// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Tests WAR (Write-After-Read) hazard in vector frep.
//
// Body layout:
//   (1) vadd.vv v2, v0, v1   -- READ  v0  (must see the value written at body end of
//                                          the PREVIOUS iteration, or x_init for iter 0)
//   (2) vse32.v v2, (pz)     -- store result
//   (3) vle32.v v0, (px)     -- WRITE v0  (WAR: v0 was read at (1) and is now overwritten)
//   (4) addi pz, pz, sz
//   (5) addi px, px, sz
//
// Within a single body execution (1) issues before (3) in program order, so there is no
// intra-iteration hazard.  The hazard arises when the frep hardware pipelines iterations:
// iteration N's WRITE at position (3) must complete before iteration N+1's READ at
// position (1) issues, and the WRITE at (3) must not corrupt the READ at (1) of the
// same iteration N.  Incorrect stall/bypass logic causes (1) of some iteration to pick
// up the wrong v0 value, producing a wrong z[].

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

#define VL 8

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    int n_iter = 4;
    int total = VL * n_iter;

    int32_t x_init[VL];
    int32_t x[VL * n_iter];
    int32_t y[VL];
    int32_t z[VL * n_iter];

    for (int j = 0; j < VL; j++) {
        x_init[j] = j + 1;
        y[j] = 10 * (j + 1);
    }
    for (int i = 0; i < total; i++) x[i] = (i + 1) * 100;
    for (int i = 0; i < total; i++) z[i] = 0;

    int32_t *px = x;
    int32_t *pz = z;

    // Pre-load v0 = x_init and the constant addend v1 = y before entering frep.
    asm volatile(
        "vsetvli zero, %[vl], e32, m1, ta, ma  \n"
        "vle32.v  v0,  (%[xi])                 \n"
        "vle32.v  v1,  (%[yy])                 \n"
        :
        : [ vl ] "r"(VL), [ xi ] "r"(x_init), [ yy ] "r"(y)
        : "v0", "v1");

    asm volatile(
        "frep.o %[iter], 5, 0, 0          \n"
        "vadd.vv  v2,    v0, v1           \n"  // (1) READ  v0 (old value) + v1 -> v2
        "vse32.v  v2,    (%[pz])          \n"  // (2) store
        "vle32.v  v0,    (%[px])          \n"  // (3) WRITE v0 (WAR within body)
        "addi     %[pz], %[pz], %[sz]     \n"  // (4)
        "addi     %[px], %[px], %[sz]     \n"  // (5)
        : [ px ] "+r"(px), [ pz ] "+r"(pz)
        : [ iter ] "r"(n_iter - 1), [ sz ] "i"(VL * 4)
        : "v0", "v1", "v2", "memory");

    snrt_fpu_fence();

    // Expected: z[iter*VL + j] = x_prev[j] + y[j]
    // where x_prev for iter 0 is x_init[j], and for iter k > 0 is x[(k-1)*VL + j].
    int error = 0;
    for (int iter = 0; iter < n_iter; iter++) {
        for (int j = 0; j < VL; j++) {
            int32_t x_prev = (iter == 0) ? x_init[j] : x[(iter - 1) * VL + j];
            int32_t expected = x_prev + y[j];
            int32_t got = z[iter * VL + j];
            if (got != expected) {
                printf("Iter %d lane %d: z=%d expected=%d\n", iter, j, got,
                       expected);
                error = 1;
            }
        }
    }
    if (!error)
        printf(
            "WAR test PASS: read-before-write ordering correct across %d "
            "iters.\n",
            n_iter);
    return error;
#else
    return 0;
#endif
}
