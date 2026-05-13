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

    int n_iter = 16;                     // total number of vector adds = n_iter * N
    int total_elements = N * n_iter;    // = 16

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

    int frep_count = n_iter / 2;        // each frep iteration does two vector adds
    int sz = N * 8;                     // stride for 4 elements (32 bytes)

    // frep.o repeats the following block frep_count times.
    // Each block does two vector adds on consecutive chunks:
    //   first chunk:  px[0..N-1] + py[0..N-1] -> pz[0..N-1]
    //   second chunk: px[N..2N-1] + py[N..2N-1] -> pz[N..2N-1]
    // Then px, py, pz advance by 2*N elements.
    // The same vector registers v0, v1, v2 are reused for both chunks.
    // This code is to test the fallback to HW loop for multiple writes to
    // the same physical register within an FREP block
    asm volatile(
        "frep.o %[iter], 14, 0, 0              \n"  // repeat block frep_count times
        // ---- first vector add (chunk A) ----
        "vle64.v  v0,    (%[px])               \n"
        "vle64.v  v1,    (%[py])               \n"
        "vadd.vv  v2,    v0, v1                \n"
        "vse64.v  v2,    (%[pz])               \n"
        // ---- advance pointers by one chunk ----
        "addi     %[px], %[px], %[sz]          \n"
        "addi     %[py], %[py], %[sz]          \n"
        "addi     %[pz], %[pz], %[sz]          \n"
        // ---- second vector add (chunk B) ----
        "vle64.v  v0,    (%[px])               \n"
        "vle64.v  v1,    (%[py])               \n"
        "vadd.vv  v2,    v0, v1                \n"
        "vse64.v  v2,    (%[pz])               \n"
        // ---- advance pointers to the next double block ----
        "addi     %[px], %[px], %[sz]          \n"
        "addi     %[py], %[py], %[sz]          \n"
        "addi     %[pz], %[pz], %[sz]          \n"
        : [ px ] "+r"(px), [ py ] "+r"(py), [ pz ] "+r"(pz)
        : [ iter ] "r"(frep_count), [ sz ] "i"(sz)
        : "v0", "v1", "v2", "memory");

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
