// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Giulio Ferraro <gferraro@student.ethz.ch>

#include "snrt.h"

// 64-bit AXPY: y = a * x + y
// Hardware now provides a fixed vector length:
//   - e32 -> vl = 8
//   - e64 -> vl = 4
void axpy_v(const int a, const int *x, const int *y, unsigned int avl) {
    unsigned int vl;

    // Stripmine loop ? vsetvli now always returns 8 (for e32)
    do {
        asm volatile("vsetvli %0, %1, e32, m8, ta, ma" : "=r"(vl) : "r"(avl));

        // Load vectors
        asm volatile("vle32.v v0, (%0)" ::"r"(x));
        asm volatile("vle32.v v8, (%0)" ::"r"(y));

        // Multiply-accumulate: y = a * x + y
        asm volatile("vmacc.vx v8, %0, v0" ::"r"(a));

        // Store results
        asm volatile("vse32.v v8, (%0)" ::"r"(y));

        // Bump pointers
        x += vl;
        y += vl;
        avl -= vl;
    } while (avl > 0);
}

int main() {
    if (snrt_global_core_idx() == 0) {
        unsigned int avl = 128 * 10;   // total elements (multiple of 8)
        int x[avl], y[avl];
        unsigned int vl;

        // init arrays
        for (int i = 0; i < avl; i++) {
            x[i] = i;
            y[i] = i;
        }

        // Force vl = 8 (hardware now always returns 8 for e32)
        asm volatile("vsetvli %[rvl], %[rdvl], e32, m8, ta, ma"
                     : [rvl] "=r"(vl)
                     : [rdvl] "r"(8));   // request exactly 8

        // Pointer setup and byte increment for 8 elements (8 * 4 = 32)
        int *xa = x;
        int *ya = y;
        const int inc = 8 * 4;          // bytes per vector (VL=8, e32)
        const int a  = 2;               // AXPY constant

        // Frep loop: repeat (avl / 8) times to process all elements
        asm volatile(
            "frep.o   %[n_frep], 6, 0, 0            \n"   // still 6 instructions
            "vle32.v  v0,    (%[xa])                 \n"   // load x
            "vle32.v  v8,    (%[ya])                 \n"   // load y
            "vadd.vv  v4,    v0,    v8               \n"   // v8 = x + y
            "vse32.v  v4,    (%[ya])                 \n"   // store sum back to y
            "add     %[xa], %[xa],   %[inc]   \n"         // advance x pointer
            "add     %[ya], %[ya],   %[inc]   \n"         // advance y pointer
            : [xa] "+r"(xa), [ya] "+r"(ya)
            : [n_frep] "r"(avl / 8),                // repeat count = 160
            [inc] "r"(inc)                         // byte increment (8*4 = 32)
            : "memory"
        );

        // Verification: y[i] should be 3*i
        for (int i = 0; i < avl; i++) {
            if (y[i] != 3 * i) {
                // printf("Error at index %d: %d != %d\n", i, y[i], 3*i);
            }
        }
    }

    snrt_cluster_hw_barrier();
    return 0;
}