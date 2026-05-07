// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <snrt.h>
#include <stdint.h>
#include "printf.h"

// 256-bit SIMD: 8 x fp32 per vector register (m1 LMUL)
#define VL 8
// Matrix dimensions: M=3 rows matches the 3-row-unrolled inner kernel,
// N=VL so exactly one 256-bit vector covers the column dimension (no outer N loop),
// K=10 gives 10 inner-loop iterations.
#define M_DIM  3
#define N_DIM  VL
#define K_DIM  10

int main() {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_dm_core()) return 0;

    // Row-major storage: A[M×K], B[K×N], C[M×N]
    float A[M_DIM][K_DIM];
    float B[K_DIM][N_DIM];
    float C[M_DIM][N_DIM];
    float golden[M_DIM][N_DIM];

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

    // Row strides
    uint32_t inc_b = N_DIM * sizeof(float);  // bytes per B row
    uint32_t inc_a = sizeof(float);          // bytes per A element (column step)

    float *ptr_b  = &B[0][0];
    float *ptr_a0 = &A[0][0];
    float *ptr_a1 = &A[1][0];
    float *ptr_a2 = &A[2][0];
    float *ptr_c0 = &C[0][0];
    float *ptr_c1 = &C[1][0];
    float *ptr_c2 = &C[2][0];

    // Set vector length to exactly 8 elements (256-bit SIMD, e32, m1)
    asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"(VL));

    // --- Innermost 3-row-unrolled kernel (from gemm_fp32_vec_frep_opt), K=10 ---
    //
    // beta=0 path: initialise v0/v8/v16 via vfmul with B[0] (k=0),
    // then frep.o handles k=1..K-1 (9 more iterations = 10 total).

    float t0 = *ptr_a0;
    float t1 = *ptr_a1;
    float t2 = *ptr_a2;

    // k=0: load B row 0, multiply into accumulators, advance A pointers to k=1
    asm volatile("vle32.v v24, (%0)" : : "r"(ptr_b));
    ptr_b += N_DIM;

    asm volatile("vfmul.vf v0,  v24, %0" : : "f"(t0));
    ptr_a0++; t0 = *ptr_a0;

    asm volatile("vfmul.vf v8,  v24, %0" : : "f"(t1));
    ptr_a1++; t1 = *ptr_a1;

    asm volatile("vfmul.vf v16, v24, %0" : : "f"(t2));
    ptr_a2++; t2 = *ptr_a2;

    // k=1..K-1: same body as the frep, now driven by a C for loop
    for (int k = 1; k < K_DIM; k++) {
        asm volatile(
            "vle32.v   v24, (%[ptr_b])                   \n"
            "add       %[ptr_b],  %[ptr_b],  %[inc_b]    \n"
            "vfmacc.vf v0,  %[ft0], v24                  \n"
            "add       %[ptr_a0], %[ptr_a0], %[inc_a]    \n"
            "flw       %[ft0], 0(%[ptr_a0])              \n"
            "vfmacc.vf v8,  %[ft1], v24                  \n"
            "add       %[ptr_a1], %[ptr_a1], %[inc_a]    \n"
            "flw       %[ft1], 0(%[ptr_a1])              \n"
            "vfmacc.vf v16, %[ft2], v24                  \n"
            "add       %[ptr_a2], %[ptr_a2], %[inc_a]    \n"
            "flw       %[ft2], 0(%[ptr_a2])              \n"
            : [ptr_b]  "+r"(ptr_b),
              [ptr_a0] "+r"(ptr_a0),
              [ptr_a1] "+r"(ptr_a1),
              [ptr_a2] "+r"(ptr_a2),
              [ft0]    "+f"(t0),
              [ft1]    "+f"(t1),
              [ft2]    "+f"(t2)
            : [inc_b] "r"(inc_b),
              [inc_a] "r"(inc_a)
            :);
    }

    asm volatile("vse32.v v0,  (%0)" : : "r"(ptr_c0) : "memory");
    asm volatile("vse32.v v8,  (%0)" : : "r"(ptr_c1) : "memory");
    asm volatile("vse32.v v16, (%0)" : : "r"(ptr_c2) : "memory");

    snrt_fpu_fence();

    // Verify against golden reference
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
        printf("vfu_gemm_dummy PASS: 3x8 C=A*B, K=10 frep iterations, 256-bit SIMD\n");

    return errors;
#else
    return 0;
#endif
}
