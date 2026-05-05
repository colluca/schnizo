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
    float alpha = 2.5f;                    // scalar multiplier

    float x[total_elements];
    float y[total_elements];
    float z[total_elements];

    // Initialize arrays
    for (int i = 0; i < total_elements; i++) {
        x[i] = (float)(i * 2);
        y[i] = (float)(i + 1);
        z[i] = 0.0f;
    }

    float *px = x;
    float *py = y;
    float *pz = z;

    // Set vector length to 8 elements (256 bits)
    asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"(VL));

    // frep.o repeats the block n_iter times.
    // Each iteration loads 8 floats from x and y, computes ?·x + y, stores to z,
    // then advances all pointers by 8*4 = 32 bytes.
    asm volatile(
        "frep.o %[iter], 8, 0, 0          \n"
        "vle32.v  v0,    (%[px])          \n"   // load x (8 floats)
        "vle32.v  v1,    (%[py])          \n"   // load y (8 floats)
        "vfmul.vf v2,    v0, %[alpha]     \n"   // v2 = alpha * x
        "vfadd.vv v3,    v2, v1           \n"   // v3 = alpha*x + y
        "vse32.v  v3,    (%[pz])          \n"   // store result (8 floats)
        "addi     %[px], %[px], %[sz]     \n"   // advance x pointer (32 bytes)
        "addi     %[py], %[py], %[sz]     \n"   // advance y pointer
        "addi     %[pz], %[pz], %[sz]     \n"   // advance z pointer
        : [px] "+r"(px), [py] "+r"(py), [pz] "+r"(pz)
        : [iter] "r"(n_iter), [alpha] "f"(alpha), [sz] "i"(VL * 4)
        : "v0", "v1", "v2", "v3"
    );

    snrt_fpu_fence();   // ensure vector writes are visible

    // Verification
    int error = 0;
    for (int i = 0; i < total_elements; i++) {
        float expected = alpha * x[i] + y[i];
        float diff = z[i] - expected;
        if (diff < 0.0f) diff = -diff;
        if (diff > 1e-5f) {
            printf("Mismatch at index %d: z=%f, expected=%f\n", i, z[i], expected);
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