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
        int64_t  xi_neg[N] = {-80, -60, -40, -20};
        uint64_t xu[N]     = {10, 20, 30, 40};
        int64_t  zi[N];

        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N));

        // ================================================================
        // INTEGER VI (vector-immediate)
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vadd.vi v8, v0, 5");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] + 5) { printf("vadd.vi error at %d\n", i); errors++; }

        // vrsub.vi: vd[i] = imm - vs2[i]
        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vrsub.vi v8, v0, 5");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != 5 - xi[i]) { printf("vrsub.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vand.vi v8, v0, 7");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] & 7)) { printf("vand.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vor.vi v8, v0, 3");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] | 3)) { printf("vor.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vxor.vi v8, v0, 6");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] ^ 6)) { printf("vxor.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi));
        asm volatile("vsll.vi v8, v0, 2");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] << 2)) { printf("vsll.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu));
        asm volatile("vsrl.vi v8, v0, 2");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] >> 2)) { printf("vsrl.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi_neg));
        asm volatile("vsra.vi v8, v0, 2");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi_neg[i] >> 2)) { printf("vsra.vi error at %d\n", i); errors++; }

        // vmv.v.i: broadcast immediate to all elements -> No VSLDU
        asm volatile("vmv.v.i v8, 7");
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));
        for (int i = 0; i < N; i++)
            if (zi[i] != 7) { printf("vmv.v.i error at %d\n", i); errors++; }

        SECTION_END("integer vi (vadd/vrsub/vand/vor/vxor/vsll/vsrl/vsra)");

        if (errors == 0)
            printf("All tests passed (int vi)\n");
        else
            printf("%d total errors\n", errors);
    }

    snrt_cluster_hw_barrier();
    return 0;
}