// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

// 256-bit SIMD: 8 x fp32 per vector register (m1 LMUL)
#define VL 8
// Unroll factor: process 1 row at a time
#define M_UNROLL 1
// Matrix dimensions: M = 1 row, N = 2*VL (two vector-width tiles), K = 10
#define M_DIM M_UNROLL
#define N_DIM (2 * VL)
#define K_DIM 10

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    float A[M_DIM][K_DIM];
    float B[K_DIM][N_DIM];
    float C[M_DIM][N_DIM];
    float golden[M_DIM][N_DIM];

    // Initialise A and B with predictable values
    for (int i = 0; i < M_DIM; i++)
        for (int k = 0; k < K_DIM; k++) A[i][k] = (float)(i * K_DIM + k + 1);

    for (int k = 0; k < K_DIM; k++)
        for (int j = 0; j < N_DIM; j++) B[k][j] = (float)(k * N_DIM + j + 1);

    for (int i = 0; i < M_DIM; i++)
        for (int j = 0; j < N_DIM; j++) C[i][j] = 0.0f;

    // Scalar golden reference: C = A * B
    for (int i = 0; i < M_DIM; i++)
        for (int j = 0; j < N_DIM; j++) {
            golden[i][j] = 0.0f;
            for (int k = 0; k < K_DIM; k++) golden[i][j] += A[i][k] * B[k][j];
        }

    // Strides for row-major traversal
    uint32_t inc_b = N_DIM * sizeof(float);  // bytes to next row of B
    uint32_t inc_a = sizeof(float);  // bytes to next column element of A

    // Set vector length to exactly 8 (256-bit SIMD)
    asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"((uint32_t)VL));

    // --- Outer N-tile loop: process VL columns of C per iteration ---
    for (int j_tile = 0; j_tile < N_DIM; j_tile += VL) {
        // Reset A pointer to the start of the row for every N-tile
        float *ptr_b = &B[0][j_tile];
        float *ptr_a0 = &A[0][0];

        // --- 1-row kernel (k=0 initialisation, then k=1..K-1 via frep) ---
        float t0 = *ptr_a0;

        // k=0: load B row 0 at column j_tile, multiply into accumulator,
        //      advance A pointer to k=1
        asm volatile("vle32.v v24, (%0)" : : "r"(ptr_b));
        ptr_b += N_DIM;

        asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
        ptr_a0++;
        t0 = *ptr_a0;

        // frep.o hardware loop for k = 1 .. K_DIM-2; k = K_DIM-1 is peeled below
        // to avoid the prefetch flw reading past the end of the A row.
        // frep executes n_frep+1 times, so n_frep = K_DIM-3 covers K_DIM-2 iterations.
        uint32_t n_frep = K_DIM - 3;

        // The body of the loop is exactly 5 instructions (see below).
        // frep.o repeats the next 5 instructions n_frep+1 times.
        asm volatile(
            "frep.o %[n_frep], 5, 0, 0                   \n"
            // --- 5-instruction block (start) ---
            "vle32.v  v24, (%[ptr_b])                    \n"  //  1
            "add      %[ptr_b],  %[ptr_b],  %[inc_b]     \n"  //  2
            "vfmacc.vf v0,  %[ft0], v24                  \n"  //  3
            "add      %[ptr_a0], %[ptr_a0], %[inc_a]     \n"  //  4
            "flw      %[ft0], 0(%[ptr_a0])               \n"  //  5
            // --- 5-instruction block (end) ---
            : [ ptr_b ] "+r"(ptr_b), [ ptr_a0 ] "+r"(ptr_a0), [ ft0 ] "+f"(t0)
            : [ inc_b ] "r"(inc_b), [ inc_a ] "r"(inc_a), [ n_frep ] "r"(n_frep)
            : "v0", "v24", "memory");

        // Peeled k = K_DIM-1: ft0 = A[0][K_DIM-1] already prefetched by last frep flw
        asm volatile(
            "vle32.v   v24, (%[ptr_b])       \n"
            "vfmacc.vf v0,  %[ft0], v24      \n"
            :
            : [ ptr_b ] "r"(ptr_b), [ ft0 ] "f"(t0)
            : "v0", "v24", "memory");

        // Store the result row into the current N-tile of C
        float *ptr_c0 = &C[0][j_tile];
        asm volatile("vse32.v v0, (%0)" : : "r"(ptr_c0) : "memory");

        snrt_fpu_fence();
    }

    // Verification
    int errors = 0;
    for (int i = 0; i < M_DIM; i++) {
        for (int j = 0; j < N_DIM; j++) {
            float diff = C[i][j] - golden[i][j];
            if (diff < 0.0f) diff = -diff;
            if (diff > golden[i][j] * 1e-4f) {
                printf("Mismatch C[%d][%d]: got %f expected %f\n", i, j,
                       C[i][j], golden[i][j]);
                errors++;
            }
        }
    }

    if (!errors)
        printf(
            "vfu_gemm_dummy PASS: 1x16 C=A*B, K=10 frep iterations, 256-bit "
            "SIMD\n");

    return errors;
#else
    return 0;
#endif
}