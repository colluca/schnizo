// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"
#include <stdint.h>

int main() {
    if (snrt_global_core_idx() == 0) {
        const int N = 4;                     // 4 elements per 256?bit vector (64?bit each)
        double x[N] = {1.0, 2.0, 3.0, 4.0};
        double y[N] = {2.0, 0.0, 4.0, 5.0};
        double z[N];
        int errors = 0;

        // Load x into v0, y into v4
        asm volatile("vle64.v v0, (%0)" :: "r"(x));
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );

        asm volatile("vle64.v v4, (%0)" :: "r"(y));

        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );

        // ---- vfadd ----
        asm volatile("vfadd.vv v8, v0, v4");
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );

        asm volatile("vse64.v v8, (%0)" :: "r"(z));
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        asm volatile("addi x0, x0, 0" : : : );
        // Verification loop
        for (int i = 0; i < N; i++) {
            double exp = x[i] + y[i];
            if (z[i] != exp) {
                printf("vfadd error at %d: got %f, expected %f\n", i, z[i], exp);
                errors++;
            }
        }

        // const int N = 4;                     // 4 elements per 256?bit vector (64?bit each)
        // int64_t x[N] = {1, 2, 3, 4};
        // int64_t y[N] = {2, 3, 4, 5};
        // int64_t z[N];
        // int errors = 0;

        // asm volatile(
        //     "vle64.v v0, (%0)\n"
        //     "vle64.v v4, (%1)\n"
        //     "vadd.vv v8, v0, v4\n"
        //     :
        //     : "r"(x), "r"(y)
        //     : "v0", "v4", "v8"
        // );
        // asm volatile("addi x0, x0, 0" : : : );
        // asm volatile("addi x0, x0, 0" : : : );
        // asm volatile("addi x0, x0, 0" : : : );
        // asm volatile("addi x0, x0, 0" : : : );
        // asm volatile("addi x0, x0, 0" : : : );
        // asm volatile("addi x0, x0, 0" : : : );
        // asm volatile("vse64.v v8, (%0)" :: "r"(z));
        // // asm volatile("addi x0, x0, 0" : : : );
        // // asm volatile("addi x0, x0, 0" : : : );
        // // asm volatile("addi x0, x0, 0" : : : );
        // for (int i = 0; i < N; i++) {
        //     int64_t exp = x[i] + y[i];
        //     if (z[i] != exp) {
        //         printf("vadd error at %d: got %lld, expected %lld\n", i, z[i], exp);
        //         errors++;
        //     }
        // }

        // // ---- vsub ----
        // asm volatile("vsub.vv v8, v0, v4");
        // asm volatile("vse64.v v8, (%0)" :: "r"(z));
        // for (int i = 0; i < N; i++) {
        //     int64_t exp = x[i] - y[i];
        //     if (z[i] != exp) {
        //         printf("vsub error at %d: got %lld, expected %lld\n", i, z[i], exp);
        //         errors++;
        //     }
        // }

        // ---- vmul ----
        // asm volatile("vmul.vv v8, v0, v4");
        // asm volatile("vse64.v v8, (%0)" :: "r"(z));
        // for (int i = 0; i < N; i++) {
        //     int64_t exp = x[i] * y[i];
        //     if (z[i] != exp) {
        //         printf("vmul error at %d: got %ld, expected %ld\n", i, z[i], exp);
        //         errors++;
        //     }
        // }

        if (errors == 0)
            printf("All tests passed (fixed 4 x 64-bit SIMD)\n");
        else
            printf("%d errors\n", errors);
    }

    snrt_cluster_hw_barrier();
    return 0;
}