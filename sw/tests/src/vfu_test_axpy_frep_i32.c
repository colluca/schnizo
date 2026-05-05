// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

#define VL 8       // 8 elements of 32-bit = 256 bits

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    int n_iter = 4;                         // number of vector iterations
    int total_elements = VL * n_iter;       // 32 elements total
    int alpha = 2;                         // scalar multiplier (integer)

    int32_t x[total_elements];
    int32_t y[total_elements];
    int32_t z[total_elements];

    // Initialize arrays
    for (int i = 0; i < total_elements; i++) {
        x[i] = (int32_t)(i * 2);
        y[i] = (int32_t)(i + 1);
        z[i] = 0;
    }

    int32_t *px = x;
    int32_t *py = y;
    int32_t *pz = z;

    // Set vector length to 8 elements (256 bits)
    asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"(VL));

    // frep.o repeats the block n_iter times.
    // Each iteration loads 8 ints from x and y, computes ?·x + y, stores to z,
    // then advances all pointers by 8*4 = 32 bytes.
    asm volatile(
        "frep.o %[iter], 8, 0, 0          \n"
        "vle32.v  v0,    (%[px])          \n"   // load x (8 ints)
        "vle32.v  v1,    (%[py])          \n"   // load y (8 ints)
        "vmul.vx  v2,    v0, %[alpha]     \n"   // v2 = alpha * x
        "vadd.vv  v3,    v2, v1           \n"   // v3 = alpha*x + y
        "vse32.v  v3,    (%[pz])          \n"   // store result (8 ints)
        "addi     %[px], %[px], %[sz]     \n"   // advance x pointer (32 bytes)
        "addi     %[py], %[py], %[sz]     \n"   // advance y pointer
        "addi     %[pz], %[pz], %[sz]     \n"   // advance z pointer
        : [px] "+r"(px), [py] "+r"(py), [pz] "+r"(pz)
        : [iter] "r"(n_iter), [alpha] "r"(alpha), [sz] "i"(VL * 4)
        : "v0", "v1", "v2", "v3"
    );

    snrt_fpu_fence();   // ensure vector writes are visible

    // Verification
    int error = 0;
    for (int i = 0; i < total_elements; i++) {
        int32_t expected = alpha * x[i] + y[i];
        if (z[i] != expected) {
            printf("Mismatch at index %d: z=%d, expected=%d\n", i, z[i], expected);
            error = 1;
        }
    }

    if (!error) {
        printf("AXPY with frep (256-bit vectors): all results match!\n");
    }
    return error;
#else
    return 0;
#endif
}