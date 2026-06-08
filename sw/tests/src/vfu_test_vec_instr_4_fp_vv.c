// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include "snrt.h"

#define SECTION_END(name)            \
    if (errors == sec_errors)        \
        printf("[PASS] " name "\n"); \
    else                             \
        printf("[FAIL] " name " (%d errors)\n", errors - sec_errors);

#define N 4  // 4 x 64-bit elements = 256-bit vector

int main() {
    if (snrt_global_core_idx() == 0) {
        int errors = 0;
        int sec_errors;

        double xf[N] = {1.0, 2.0, 3.0, 4.0};
        double yf[N] = {2.0, 3.0, 4.0, 5.0};
        double af[N] = {1.0, 1.0, 1.0, 1.0};
        double zf[N];

        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));

        // ================================================================
        // FP VV ARITHMETIC
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfadd.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] + yf[i]) {
                printf("vfadd error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfsub.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] - yf[i]) {
                printf("vfsub error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfmul.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] * yf[i]) {
                printf("vfmul error at %d\n", i);
                errors++;
            }

        SECTION_END("fp vv arithmetic (vfadd/vfsub/vfmul)");

        // ================================================================
        // FP VV FUSED MULTIPLY-ADD  (vd = vd*vs1 op vs2)
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmadd.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != af[i] * xf[i] + yf[i]) {
                printf("vfmadd error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmsub.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != af[i] * xf[i] - yf[i]) {
                printf("vfmsub error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmadd.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(af[i] * xf[i]) - yf[i]) {
                printf("vfnmadd error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmsub.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(af[i] * xf[i]) + yf[i]) {
                printf("vfnmsub error at %d\n", i);
                errors++;
            }

        SECTION_END("fp vv fused madd (vfmadd/vfmsub/vfnmadd/vfnmsub)");

        // ================================================================
        // FP VV MULTIPLY-ACCUMULATE  (vd = vs1*vs2 op vd)
        // vfmacc  vd[i] = +(vs1[i]*vs2[i]) + vd[i]
        // vfnmacc vd[i] = -(vs1[i]*vs2[i]) - vd[i]
        // vfmsac  vd[i] = +(vs1[i]*vs2[i]) - vd[i]
        // vfnmsac vd[i] = -(vs1[i]*vs2[i]) + vd[i]
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmacc.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] * yf[i] + af[i]) {
                printf("vfmacc error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmacc.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(xf[i] * yf[i]) - af[i]) {
                printf("vfnmacc error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmsac.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] * yf[i] - af[i]) {
                printf("vfmsac error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmsac.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(xf[i] * yf[i]) + af[i]) {
                printf("vfnmsac error at %d\n", i);
                errors++;
            }

        SECTION_END(
            "fp vv multiply-accumulate (vfmacc/vfnmacc/vfmsac/vfnmsac)");

        // ================================================================
        // FP VV MIN / MAX
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfmin.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (xf[i] < yf[i] ? xf[i] : yf[i])) {
                printf("vfmin error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfmax.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (xf[i] > yf[i] ? xf[i] : yf[i])) {
                printf("vfmax error at %d\n", i);
                errors++;
            }

        SECTION_END("fp vv min/max (vfmin/vfmax)");

        // ================================================================
        // FP VV SIGN INJECTION
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfsgnj.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i]) {
                printf("vfsgnj error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfsgnjn.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -xf[i]) {
                printf("vfsgnjn error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v4, (%0)" ::"r"(yf));
        asm volatile("vfsgnjx.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i]) {
                printf("vfsgnjx error at %d\n", i);
                errors++;
            }

        SECTION_END("fp vv sign injection (vfsgnj/vfsgnjn/vfsgnjx)");

        if (errors == 0)
            printf("All tests passed (fp vv)\n");
        else
            printf("%d total errors\n", errors);
    }

    snrt_cluster_hw_barrier();
    return 0;
}