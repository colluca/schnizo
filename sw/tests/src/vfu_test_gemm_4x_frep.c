// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

// 256-bit SIMD: 8 x fp32 per vector register (m1 LMUL)
#define VL 8
// Unroll factor: process 4 rows at a time
#define M_UNROLL 4
// Matrix dimensions: M rows (processed in blocks of M_UNROLL), N, K.
// M_DIM must be a multiple of M_UNROLL (the inner kernel handles M_UNROLL rows).
#define M_DIM (M_UNROLL)
#define N_DIM (VL)
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

    // --- Start cycle measurement of the GEMM computation only ---
    // (fence so the timer boundary is clean w.r.t. the setup above)
    uint32_t cyc_start, cyc_end;
    asm volatile("fence");
    asm volatile("csrr %0, mcycle" : "=r"(cyc_start));

    // --- Outer N-tile loop: process VL columns of C per iteration ---
    for (int j_tile = 0; j_tile < N_DIM; j_tile += VL) {
        // --- Row-block loop: process M_UNROLL rows of C per iteration ---
        for (int m_blk = 0; m_blk < M_DIM; m_blk += M_UNROLL) {
            // Reset pointers for this row-block / N-tile
            float *ptr_b1 = &B[0][j_tile];
            float *ptr_b2 = &B[0][j_tile];
            float *ptr_a0 = &A[m_blk + 0][0];
            float *ptr_a1 = &A[m_blk + 1][0];
            float *ptr_a2 = &A[m_blk + 2][0];
            float *ptr_a3 = &A[m_blk + 3][0];

            // --- 4-row unrolled kernel (k=0 initialisation, then k=1..K-1 via frep) ---
            float t0 = *ptr_a0;
            float t1 = *ptr_a1;
            float t2 = *ptr_a2;
            float t3 = *ptr_a3;

            // k=0: load B row 0 at column j_tile, multiply into 4 accumulators,
            //      advance A pointers to k=1
            asm volatile("vle32.v v24, (%0)" : : "r"(ptr_b1));
            ptr_b1 += N_DIM;
            ptr_b2 += N_DIM;

            asm volatile("vfmul.vf v0,  v24, %0" : : "f"(t0));
            ptr_a0++;
            t0 = *ptr_a0;

            asm volatile("vfmul.vf v8,  v24, %0" : : "f"(t1));
            ptr_a1++;
            t1 = *ptr_a1;

            asm volatile("vfmul.vf v16, v24, %0" : : "f"(t2));
            ptr_a2++;
            t2 = *ptr_a2;

            asm volatile("vfmul.vf v28, v24, %0" : : "f"(t3));
            ptr_a3++;
            t3 = *ptr_a3;

            // frep.o hardware loop for k = 1 .. K_DIM-1
            uint32_t n_frep = K_DIM - 2;  // already handled k=0

            // The body of the loop is exactly 15 instructions (see below).
            // frep.o repeats the next 15 instructions n_frep times.
            asm volatile(
                "frep.o %[n_frep], 14, 0, 0                  \n"
                // --- 15-instruction block (start) ---
                "vle32.v  v24, (%[ptr_b1])                    \n"   //  1
                "add      %[ptr_b1],  %[ptr_b1],  %[inc_b]     \n"  //  2
                // row 0
                "vfmacc.vf v0,  %[ft0], v24                  \n"  //  3
                "add      %[ptr_a0], %[ptr_a0], %[inc_a]     \n"  //  4
                "flw      %[ft0], 0(%[ptr_a0])               \n"  //  5
                // row 1
                "vfmacc.vf v8,  %[ft1], v24                  \n"  //  6
                "add      %[ptr_a1], %[ptr_a1], %[inc_a]     \n"  //  7
                "flw      %[ft1], 0(%[ptr_a1])               \n"  //  8

                // "vle32.v  v26, (%[ptr_b2])                    \n"   //  1
                // "add      %[ptr_b2],  %[ptr_b2],  %[inc_b]     \n"  //  2
                // row 2
                "vfmacc.vf v16, %[ft2], v24                  \n"  //  9
                "add      %[ptr_a2], %[ptr_a2], %[inc_a]     \n"  // 10
                "flw      %[ft2], 0(%[ptr_a2])               \n"  // 11
                // row 3
                "vfmacc.vf v28, %[ft3], v24                  \n"  // 12
                "add      %[ptr_a3], %[ptr_a3], %[inc_a]     \n"  // 13
                "flw      %[ft3], 0(%[ptr_a3])               \n"  // 14
                // --- 15-instruction block (end) ---
                : [ ptr_b1 ] "+r"(ptr_b1), [ ptr_b2 ] "+r"(ptr_b2),
                  [ ptr_a0 ] "+r"(ptr_a0), [ ptr_a1 ] "+r"(ptr_a1),
                  [ ptr_a2 ] "+r"(ptr_a2), [ ptr_a3 ] "+r"(ptr_a3),
                  [ ft0 ] "+f"(t0), [ ft1 ] "+f"(t1), [ ft2 ] "+f"(t2),
                  [ ft3 ] "+f"(t3)
                : [ inc_b ] "r"(inc_b), [ inc_a ] "r"(inc_a),
                  [ n_frep ] "r"(n_frep)
                : "v0", "v8", "v16", "v28", "v24", "memory");

            // Store the 4 result rows into the current N-tile of C
            float *ptr_c0 = &C[m_blk + 0][j_tile];
            float *ptr_c1 = &C[m_blk + 1][j_tile];
            float *ptr_c2 = &C[m_blk + 2][j_tile];
            float *ptr_c3 = &C[m_blk + 3][j_tile];

            asm volatile("vse32.v v0,  (%0)" : : "r"(ptr_c0) : "memory");
            asm volatile("vse32.v v8,  (%0)" : : "r"(ptr_c1) : "memory");
            asm volatile("vse32.v v16, (%0)" : : "r"(ptr_c2) : "memory");
            asm volatile("vse32.v v28, (%0)" : : "r"(ptr_c3) : "memory");

            snrt_fpu_fence();
        }
    }

    // --- Stop cycle measurement (fence so all vector stores have retired) ---
    asm volatile("fence");
    asm volatile("csrr %0, mcycle" : "=r"(cyc_end));

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
            "vfu_gemm_dummy PASS: %dx%d C=A*B, K=%d frep iterations, "
            "256-bit SIMD\n",
            M_DIM, N_DIM, K_DIM);

    // Report the measured GEMM compute cycles. Peak (1 vfmacc/cycle) would be
    // M_DIM * N_DIM * K_DIM / VL macc-vector-ops; print both for comparison.
    uint32_t cycles = cyc_end - cyc_start;
    uint32_t ideal = (uint32_t)M_DIM * N_DIM * K_DIM / VL;
    printf("GEMM compute: %u cycles  (ideal vfmacc-bound = %u, %u%% util)\n",
           cycles, ideal, ideal * 100u / cycles);

    return errors;
#else
    return 0;
#endif
}