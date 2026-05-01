// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"
#include <stdint.h>

#define SECTION_END(name) \
    if (errors == sec_errors) printf("[PASS] " name "\n"); \
    else printf("[FAIL] " name " (%d errors)\n", errors - sec_errors);

#define N 4  // 4 x 64-bit elements = 256-bit vector

int main() {
    if (snrt_global_core_idx() == 0) {
        int errors = 0;
        int sec_errors;

        int64_t  xi[N]     = {10, 20, 30, 40};
        int64_t  yi[N]     = { 3,  4,  5,  6};
        int64_t  xi_neg[N] = {-80, -60, -40, -20};
        uint64_t xu[N]     = {10, 20, 30, 40};
        uint64_t yu[N]     = { 3,  4,  5,  6};
        int64_t  zi[N];

        int32_t  xi32[N] = { 3,  7, 11, 15};
        int32_t  yi32[N] = { 2,  4,  6,  8};
        uint32_t xu32[N] = { 3,  7, 11, 15};
        uint32_t yu32[N] = { 2,  4,  6,  8};

        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));

        // ================================================================
        // LOAD / STORE
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vadd.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] + yi[i]) { printf("vle/vse/vadd error at %d\n", i); errors++; }

        SECTION_END("load/store (vle64/vse64)");

        // ================================================================
        // INTEGER VV ARITHMETIC
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vsub.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] - yi[i]) { printf("vsub error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vand.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] & yi[i])) { printf("vand error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vor.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] | yi[i])) { printf("vor error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vxor.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] ^ yi[i])) { printf("vxor error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vmin.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] < yi[i] ? xi[i] : yi[i])) { printf("vmin error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu));
        asm volatile("vle64.v v4, (%0)" :: "r"(yu));
        asm volatile("vminu.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] < yu[i] ? xu[i] : yu[i])) { printf("vminu error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vmax.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] > yi[i] ? xi[i] : yi[i])) { printf("vmax error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu));
        asm volatile("vle64.v v4, (%0)" :: "r"(yu));
        asm volatile("vmaxu.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] > yu[i] ? xu[i] : yu[i])) { printf("vmaxu error at %d\n", i); errors++; }

        SECTION_END("integer vv arithmetic (vadd/vsub/vand/vor/vxor/vmin/vminu/vmax/vmaxu)");

        // ================================================================
        // INTEGER VV SHIFTS
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vsll.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] << yi[i])) { printf("vsll error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu));
        asm volatile("vle64.v v4, (%0)" :: "r"(yu));
        asm volatile("vsrl.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] >> yu[i])) { printf("vsrl error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi_neg));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vsra.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi_neg[i] >> yi[i])) { printf("vsra error at %d\n", i); errors++; }

        SECTION_END("integer vv shifts (vsll/vsrl/vsra)");

        // ================================================================
        // INTEGER VV DIVIDE / REMAINDER
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vdiv.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] / yi[i]) { 
                printf("vdiv error at %d\n", i); 
                errors++; 
                printf("operand 1 %d/ operand 2 %d, expected %d, got %d\n", xi[i], yi[i], xi[i] / yi[i], zi[i]);
            }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu));
        asm volatile("vle64.v v4, (%0)" :: "r"(yu));
        asm volatile("vdivu.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != xu[i] / yu[i]) { printf("vdivu error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vle64.v v4, (%0)" :: "r"(yi));
        asm volatile("vrem.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] % yi[i]) { printf("vrem error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu));
        asm volatile("vle64.v v4, (%0)" :: "r"(yu));
        asm volatile("vremu.vv v8, v0, v4");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != xu[i] % yu[i]) { printf("vremu error at %d\n", i); errors++; }

        SECTION_END("integer vv divide/remainder (vdiv/vdivu/vrem/vremu)");

        // ================================================================
        // INTEGER VV WIDENING MULTIPLY (e32 -> e64)
        // ================================================================
        sec_errors = errors;

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(2*N));

        asm volatile("vle32.v v0, (%0)" :: "r"(xi32));
        asm volatile("vle32.v v4, (%0)" :: "r"(yi32));
        asm volatile("vwmul.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (int64_t)xi32[i] * (int64_t)yi32[i]) { printf("vwmul error at %d\n", i); errors++; }

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(2*N));
        asm volatile("vle32.v v0, (%0)" :: "r"(xu32));
        asm volatile("vle32.v v4, (%0)" :: "r"(yu32));
        asm volatile("vwmulu.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (uint64_t)xu32[i] * (uint64_t)yu32[i]) { printf("vwmulu error at %d\n", i); errors++; }

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(2*N));
        asm volatile("vle32.v v0, (%0)" :: "r"(xi32));
        asm volatile("vle32.v v4, (%0)" :: "r"(yu32));
        asm volatile("vwmulsu.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (int64_t)xi32[i] * (int64_t)yu32[i]) { printf("vwmulsu error at %d\n", i); errors++; }

        SECTION_END("integer vv widening multiply (vwmul/vwmulu/vwmulsu)");

        // ================================================================
        // INTEGER VV WIDENING MULTIPLY-ACCUMULATE (e32 -> e64)
        // ================================================================
        sec_errors = errors;

        int64_t ai64[N] = {100, 200, 300, 400};

        asm volatile("vle64.v v8, (%0)" :: "r"(ai64));
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(2*N));
        asm volatile("vle32.v v0, (%0)" :: "r"(xi32));
        asm volatile("vle32.v v4, (%0)" :: "r"(yi32));
        asm volatile("vwmacc.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != ai64[i] + (int64_t)xi32[i] * (int64_t)yi32[i]) { printf("vwmacc error at %d\n", i); errors++; }

        asm volatile("vle64.v v8, (%0)" :: "r"(ai64));
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(2*N));
        asm volatile("vle32.v v0, (%0)" :: "r"(xu32));
        asm volatile("vle32.v v4, (%0)" :: "r"(yu32));
        asm volatile("vwmaccu.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (uint64_t)ai64[i] + (uint64_t)xu32[i] * (uint64_t)yu32[i]) { printf("vwmaccu error at %d\n", i); errors++; }

        asm volatile("vle64.v v8, (%0)" :: "r"(ai64));
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(2*N));
        asm volatile("vle32.v v0, (%0)" :: "r"(xi32));
        asm volatile("vle32.v v4, (%0)" :: "r"(yu32));
        asm volatile("vwmaccsu.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != ai64[i] + (int64_t)xi32[i] * (int64_t)yu32[i]) { printf("vwmaccsu error at %d\n", i); errors++; }

        SECTION_END("integer vv widening macc (vwmacc/vwmaccu/vwmaccsu)");

        if (errors == 0)
            printf("All tests passed (int vv)\n");
        else
            printf("%d total errors\n", errors);
    }

    snrt_cluster_hw_barrier();
    return 0;
}