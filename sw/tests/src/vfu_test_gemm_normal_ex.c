// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

// 256-bit SIMD: 8 x fp32 per vector register (m1 LMUL)
#define VL 8
// Unroll factor: process 6 rows at a time
#define M_UNROLL 6
// Matrix dimensions: M = 6 rows, N = 2*VL (two vector-width tiles), K = 10
#define M_DIM  M_UNROLL
#define N_DIM  (2 * VL)
#define K_DIM  10

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    float A[M_DIM][K_DIM];
    float B[K_DIM][N_DIM];
    float C[M_DIM][N_DIM];
    float golden[M_DIM][N_DIM];

    // Initialise A and B with predictable values
    for (int i = 0; i < M_DIM; i++)
        for (int k = 0; k < K_DIM; k++)
            A[i][k] = (float)(i * K_DIM + k + 1);

    for (int k = 0; k < K_DIM; k++)
        for (int j = 0; j < N_DIM; j++)
            B[k][j] = (float)(k * N_DIM + j + 1);

    for (int i = 0; i < M_DIM; i++)
        for (int j = 0; j < N_DIM; j++)
            C[i][j] = 0.0f;

    // Scalar golden reference: C = A * B
    for (int i = 0; i < M_DIM; i++)
        for (int j = 0; j < N_DIM; j++) {
            golden[i][j] = 0.0f;
            for (int k = 0; k < K_DIM; k++)
                golden[i][j] += A[i][k] * B[k][j];
        }

    // Strides for row-major traversal
    uint32_t inc_b = N_DIM * sizeof(float);  // bytes to next row of B
    uint32_t inc_a = sizeof(float);          // bytes to next column element of A

    // Set vector length to exactly 8 (256-bit SIMD)
    asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"((uint32_t)VL));

    // --- Outer N-tile loop: process VL columns of C per iteration ---
    for (int j_tile = 0; j_tile < N_DIM; j_tile += VL) {

        // Reset A pointers to the start of each row for every N-tile
        float *ptr_b  = &B[0][j_tile];
        float *ptr_a0 = &A[0][0];
        float *ptr_a1 = &A[1][0];
        float *ptr_a2 = &A[2][0];
        float *ptr_a3 = &A[3][0];
        float *ptr_a4 = &A[4][0];
        float *ptr_a5 = &A[5][0];

        // --- 6-row unrolled kernel (k=0 initialisation, then k=1..K-1) ---
        float t0 = *ptr_a0;
        float t1 = *ptr_a1;
        float t2 = *ptr_a2;
        float t3 = *ptr_a3;
        float t4 = *ptr_a4;
        float t5 = *ptr_a5;

        // k=0: load B row 0 at column j_tile, multiply into 6 accumulators,
        //      advance A pointers to k=1
        asm volatile("vle32.v v24, (%0)" : : "r"(ptr_b));
        ptr_b += N_DIM;

        asm volatile("vfmul.vf v0,  v24, %0" : : "f"(t0));
        ptr_a0++; t0 = *ptr_a0;

        asm volatile("vfmul.vf v8,  v24, %0" : : "f"(t1));
        ptr_a1++; t1 = *ptr_a1;

        asm volatile("vfmul.vf v16, v24, %0" : : "f"(t2));
        ptr_a2++; t2 = *ptr_a2;

        asm volatile("vfmul.vf v28, v24, %0" : : "f"(t3));
        ptr_a3++; t3 = *ptr_a3;

        asm volatile("vfmul.vf v4,  v24, %0" : : "f"(t4));
        ptr_a4++; t4 = *ptr_a4;

        asm volatile("vfmul.vf v12, v24, %0" : : "f"(t5));
        ptr_a5++; t5 = *ptr_a5;

        // Replace frep hardware loop with normal software loop
        for (int k = 1; k < K_DIM; k++) {
            asm volatile(
                "vle32.v  v24, (%[ptr_b])                \n"
                "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                // row 0
                "vfmacc.vf v0,  %[ft0], v24              \n"
                "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                "flw      %[ft0], 0(%[ptr_a0])           \n"
                // row 1
                "vfmacc.vf v8,  %[ft1], v24              \n"
                "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                "flw      %[ft1], 0(%[ptr_a1])           \n"
                // row 2
                "vfmacc.vf v16, %[ft2], v24              \n"
                "add      %[ptr_a2], %[ptr_a2], %[inc_a] \n"
                "flw      %[ft2], 0(%[ptr_a2])           \n"
                // row 3
                "vfmacc.vf v28, %[ft3], v24              \n"
                "add      %[ptr_a3], %[ptr_a3], %[inc_a] \n"
                "flw      %[ft3], 0(%[ptr_a3])           \n"
                // row 4
                "vfmacc.vf v4,  %[ft4], v24              \n"
                "add      %[ptr_a4], %[ptr_a4], %[inc_a] \n"
                "flw      %[ft4], 0(%[ptr_a4])           \n"
                // row 5
                "vfmacc.vf v12, %[ft5], v24              \n"
                "add      %[ptr_a5], %[ptr_a5], %[inc_a] \n"
                "flw      %[ft5], 0(%[ptr_a5])           \n"
                : [ptr_b]   "+r"(ptr_b),
                  [ptr_a0]  "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1), [ptr_a2] "+r"(ptr_a2),
                  [ptr_a3]  "+r"(ptr_a3), [ptr_a4] "+r"(ptr_a4), [ptr_a5] "+r"(ptr_a5),
                  [ft0]     "+f"(t0), [ft1] "+f"(t1), [ft2] "+f"(t2),
                  [ft3]     "+f"(t3), [ft4] "+f"(t4), [ft5] "+f"(t5)
                : [inc_b]   "r"(inc_b),
                  [inc_a]   "r"(inc_a)
                : );
        }

        // Store the 6 result rows into the current N-tile of C
        float *ptr_c0 = &C[0][j_tile];
        float *ptr_c1 = &C[1][j_tile];
        float *ptr_c2 = &C[2][j_tile];
        float *ptr_c3 = &C[3][j_tile];
        float *ptr_c4 = &C[4][j_tile];
        float *ptr_c5 = &C[5][j_tile];

        asm volatile("vse32.v v0,  (%0)" : : "r"(ptr_c0) : "memory");
        asm volatile("vse32.v v8,  (%0)" : : "r"(ptr_c1) : "memory");
        asm volatile("vse32.v v16, (%0)" : : "r"(ptr_c2) : "memory");
        asm volatile("vse32.v v28, (%0)" : : "r"(ptr_c3) : "memory");
        asm volatile("vse32.v v4,  (%0)" : : "r"(ptr_c4) : "memory");
        asm volatile("vse32.v v12, (%0)" : : "r"(ptr_c5) : "memory");

        snrt_fpu_fence();
    }

    // Verification
    int errors = 0;
    for (int i = 0; i < M_DIM; i++) {
        for (int j = 0; j < N_DIM; j++) {
            float diff = C[i][j] - golden[i][j];
            if (diff < 0.0f) diff = -diff;
            if (diff > golden[i][j] * 1e-4f) {
                printf("Mismatch C[%d][%d]: got %f expected %f\n",
                       i, j, C[i][j], golden[i][j]);
                errors++;
            }
        }
    }

    if (!errors)
        printf("vfu_gemm_dummy PASS: 6x16 C=A*B, K=10 software-loop iterations, 256-bit SIMD\n");

    return errors;
#else
    return 0;
#endif
}