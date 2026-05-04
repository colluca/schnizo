// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

#define N 4

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    int n_iter = 4;
    int total_elements = N * n_iter;

    int64_t x[N * n_iter];
    int64_t y[N * n_iter];
    int64_t z[N * n_iter];

    // Initialize arrays
    for (int i = 0; i < total_elements; i++) {
        x[i] = i * 2;
        y[i] = i + 1;
        z[i] = 0;
    }

    // Set up pointers
    int64_t *px = x;
    int64_t *py = y;
    int64_t *pz = z;

    // Vector length (N elements of 64-bit)
    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));

    // frep.o repeats the following block n_iter times.
    // The block loads N elements from x and y, adds them, stores to z,
    // then advances all pointers by N * 8 bytes.
    asm volatile(
        "frep.o %[iter], 7, 0, 0      \n"  // repeat block 4 times (n_iter-1)
        "vle64.v  v0,    (%[px])      \n"  // load N x elements into v0
        "vle64.v  v1,    (%[py])      \n"  // load N y elements into v1
        "vadd.vv  v2,    v0, v1       \n"  // v2 = v0 + v1
        "vse64.v  v2,    (%[pz])      \n"  // store result to z
        "addi     %[px], %[px], %[sz] \n"  // advance x pointer
        "addi     %[py], %[py], %[sz] \n"  // advance y pointer
        "addi     %[pz], %[pz], %[sz] \n"  // advance z pointer
        : [ px ] "+r"(px), [ py ] "+r"(py), [ pz ] "+r"(pz)
        : [ iter ] "r"(n_iter), [ sz ] "i"(N * 8)
        : "v0", "v1", "v2");

    snrt_fpu_fence();  // ensure vector writes are visible

    // Verification loop
    int error = 0;
    for (int i = 0; i < total_elements; i++) {
        int64_t expected = x[i] + y[i];
        if (z[i] != expected) {
            printf("Mismatch at index %d: z=%ld, expected=%ld\n", i, z[i],
                   expected);
            error = 1;
        }
    }

    if (!error) {
        printf("All results match! frep works correctly.\n");
    }
    return error;
#else
    return 0;
#endif
}