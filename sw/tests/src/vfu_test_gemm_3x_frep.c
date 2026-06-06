// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

// 256-bit SIMD: 8 x fp32 per vector register (m1 LMUL)
#define VL 8
// Unroll factor: process 3 rows at a time
#define M_UNROLL 3
// Matrix dimensions: M = 3 rows, N = 2*VL (two vector-width tiles), K = 10
#define M_DIM M_UNROLL
#define N_DIM (2 * VL)
#define K_DIM 16

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    // 32-byte (256-bit) alignment so vle32.v/vse32.v hit the fast aligned path
    __attribute__((aligned(32))) float A[M_DIM][K_DIM];
    __attribute__((aligned(32))) float B[K_DIM][N_DIM];
    __attribute__((aligned(32))) float C[M_DIM][N_DIM];
    __attribute__((aligned(32))) float golden[M_DIM][N_DIM];

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
        // Reset A pointers to the start of each row for every N-tile
        float *ptr_b = &B[0][j_tile];
        float *ptr_a0 = &A[0][0];
        float *ptr_a1 = &A[1][0];
        float *ptr_a2 = &A[2][0];

        // --- 3-row unrolled kernel (k=0 initialisation, then k=1..K-1 via frep) ---
        float t0 = *ptr_a0;
        float t1 = *ptr_a1;
        float t2 = *ptr_a2;

        // k=0: load B row 0 at column j_tile, multiply into 3 accumulators,
        //      advance A pointers to k=1
        asm volatile("vle32.v v24, (%0)" : : "r"(ptr_b));
        ptr_b += N_DIM;

        asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
        ptr_a0++;
        t0 = *ptr_a0;

        asm volatile("vfmul.vf v8, v24, %0" : : "f"(t1));
        ptr_a1++;
        t1 = *ptr_a1;

        asm volatile("vfmul.vf v16, v24, %0" : : "f"(t2));
        ptr_a2++;
        t2 = *ptr_a2;

        // frep.o hardware loop for k = 1 .. K_DIM-2; k = K_DIM-1 is peeled below
        // to avoid the prefetch flw reading past the end of the A rows.
        // frep executes n_frep+1 times, so n_frep = K_DIM-3 covers K_DIM-2 iterations.
        uint32_t n_frep = K_DIM - 3;

        // The body of the loop is exactly 11 instructions (see below).
        // frep.o repeats the next 11 instructions n_frep+1 times.
        asm volatile(
            "frep.o %[n_frep], 11, 0, 0                  \n"
            // --- 11-instruction block (start) ---
            "vle32.v  v24, (%[ptr_b])                    \n"  //  1
            "add      %[ptr_b],  %[ptr_b],  %[inc_b]     \n"  //  2
            // row 0
            "vfmacc.vf v0,  %[ft0], v24                  \n"  //  3
            "add      %[ptr_a0], %[ptr_a0], %[inc_a]     \n"  //  4
            "flw      %[ft0], 0(%[ptr_a0])               \n"  //  5
            // row 1
            "vfmacc.vf v8,  %[ft1], v24                  \n"  //  6
            "add      %[ptr_a1], %[ptr_a1], %[inc_a]     \n"  //  7
            "flw      %[ft1], 0(%[ptr_a1])               \n"  //  8
            // row 2
            "vfmacc.vf v16, %[ft2], v24                  \n"  //  9
            "add      %[ptr_a2], %[ptr_a2], %[inc_a]     \n"  // 10
            "flw      %[ft2], 0(%[ptr_a2])               \n"  // 11
            // --- 11-instruction block (end) ---
            : [ ptr_b ] "+r"(ptr_b), [ ptr_a0 ] "+r"(ptr_a0),
              [ ptr_a1 ] "+r"(ptr_a1), [ ptr_a2 ] "+r"(ptr_a2),
              [ ft0 ] "+f"(t0), [ ft1 ] "+f"(t1), [ ft2 ] "+f"(t2)
            : [ inc_b ] "r"(inc_b), [ inc_a ] "r"(inc_a), [ n_frep ] "r"(n_frep)
            : "v0", "v8", "v16", "v24", "memory");

        // Peeled k = K_DIM-1: ft0/ft1/ft2 = A[0/1/2][K_DIM-1] already prefetched
        // by last frep flw
        asm volatile(
            "vle32.v   v24, (%[ptr_b])       \n"
            "vfmacc.vf v0,  %[ft0], v24      \n"
            "vfmacc.vf v8,  %[ft1], v24      \n"
            "vfmacc.vf v16, %[ft2], v24      \n"
            :
            : [ ptr_b ] "r"(ptr_b), [ ft0 ] "f"(t0), [ ft1 ] "f"(t1),
              [ ft2 ] "f"(t2)
            : "v0", "v8", "v16", "v24", "memory");

        // Store the 3 result rows into the current N-tile of C
        float *ptr_c0 = &C[0][j_tile];
        float *ptr_c1 = &C[1][j_tile];
        float *ptr_c2 = &C[2][j_tile];

        asm volatile("vse32.v v0,  (%0)" : : "r"(ptr_c0) : "memory");
        asm volatile("vse32.v v8,  (%0)" : : "r"(ptr_c1) : "memory");
        asm volatile("vse32.v v16, (%0)" : : "r"(ptr_c2) : "memory");

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
            "vfu_gemm_dummy PASS: 3x16 C=A*B, K=10 frep iterations, 256-bit "
            "SIMD\n");

    return errors;
#else
    return 0;
#endif
}
