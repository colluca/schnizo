// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Schnizo SIMD-only fp64 GEMM kernels: C = beta*C + A*B
//
// All kernels require !transa, !transb, !partition_banks.
// Fixed 256-bit vector width: VL=4 (e64, m1).
// The outer N-tile loop processes 4 columns of C per iteration.
// Available M-unroll variants: 1x, 2x, 4x, 6x, 8x.
//
// frep body instruction counts (same structure as fp32, fp64 encoding):
//   1x: 5   2x: 8   4x: 14   6x: 21   8x: 27

#pragma once
#include <stdint.h>
#include "snrt.h"

// ---------------------------------------------------------------------------
// gemm_fp64_simd_1x  — 1 output row per M-loop iteration
// ---------------------------------------------------------------------------
static inline void gemm_fp64_simd_1x(
    uint32_t setup_ssr, uint32_t partition_banks,
    uint32_t transa, uint32_t transb,
    uint32_t M, uint32_t N, uint32_t K,
    void* A_p, uint32_t lda, void* B_p, uint32_t ldb,
    uint32_t beta, void* C_p, uint32_t ldc)
{
    if (transa || transb || partition_banks) return;

    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    snrt_mcycle();

    uint32_t inc_b = ldb * sizeof(double);
    uint32_t inc_a = sizeof(double);
    const uint32_t VL = 4;

    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" : : "r"(VL));

    for (int j_tile = 0; j_tile < (int)N; j_tile += VL) {
        for (int i = 0; i < (int)M; i++) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double t0 = *ptr_a0;

            if (beta) {
                asm volatile("vle64.v v0, (%0)" : : "r"(C + i*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b]  "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
                asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
                ptr_a0++; t0 = *ptr_a0;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b]  "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            }
            asm volatile("vse64.v v0, (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
        }
    }

    asm volatile("fence");
    snrt_mcycle();
}

// ---------------------------------------------------------------------------
// gemm_fp64_simd_2x  — 2 output rows per M-loop iteration
// ---------------------------------------------------------------------------
static inline void gemm_fp64_simd_2x(
    uint32_t setup_ssr, uint32_t partition_banks,
    uint32_t transa, uint32_t transb,
    uint32_t M, uint32_t N, uint32_t K,
    void* A_p, uint32_t lda, void* B_p, uint32_t ldb,
    uint32_t beta, void* C_p, uint32_t ldc)
{
    if (transa || transb || partition_banks) return;

    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    snrt_mcycle();

    uint32_t inc_b = ldb * sizeof(double);
    uint32_t inc_a = sizeof(double);
    const uint32_t VL = 4;

    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" : : "r"(VL));

    for (int j_tile = 0; j_tile < (int)N; j_tile += VL) {
        int i = 0;
        for (; i + 1 < (int)M; i += 2) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double *ptr_a1 = A + (i+1) * lda;
            double t0 = *ptr_a0, t1 = *ptr_a1;

            if (beta) {
                asm volatile("vle64.v v0, (%0)" : : "r"(C + i*ldc + j_tile));
                asm volatile("vle64.v v8, (%0)" : : "r"(C + (i+1)*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 8, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1),
                      [ft0] "+f"(t0), [ft1] "+f"(t1)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v8", "v24", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
                asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
                ptr_a0++; t0 = *ptr_a0;
                asm volatile("vfmul.vf v8, v24, %0" : : "f"(t1));
                ptr_a1++; t1 = *ptr_a1;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 8, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1),
                      [ft0] "+f"(t0), [ft1] "+f"(t1)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v8", "v24", "memory"
                );
            }
            asm volatile("vse64.v v0, (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
            asm volatile("vse64.v v8, (%0)" : : "r"(C + (i+1)*ldc + j_tile) : "memory");
        }
        for (; i < (int)M; i++) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double t0 = *ptr_a0;
            if (beta) {
                asm volatile("vle64.v v0, (%0)" : : "r"(C + i*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
                asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
                ptr_a0++; t0 = *ptr_a0;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            }
            asm volatile("vse64.v v0, (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
        }
    }

    asm volatile("fence");
    snrt_mcycle();
}

// ---------------------------------------------------------------------------
// gemm_fp64_simd_4x  — 4 output rows per M-loop iteration
// ---------------------------------------------------------------------------
static inline void gemm_fp64_simd_4x(
    uint32_t setup_ssr, uint32_t partition_banks,
    uint32_t transa, uint32_t transb,
    uint32_t M, uint32_t N, uint32_t K,
    void* A_p, uint32_t lda, void* B_p, uint32_t ldb,
    uint32_t beta, void* C_p, uint32_t ldc)
{
    if (transa || transb || partition_banks) return;

    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    snrt_mcycle();

    uint32_t inc_b = ldb * sizeof(double);
    uint32_t inc_a = sizeof(double);
    const uint32_t VL = 4;

    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" : : "r"(VL));

    for (int j_tile = 0; j_tile < (int)N; j_tile += VL) {
        int i = 0;
        for (; i + 3 < (int)M; i += 4) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double *ptr_a1 = A + (i+1) * lda;
            double *ptr_a2 = A + (i+2) * lda;
            double *ptr_a3 = A + (i+3) * lda;
            double t0 = *ptr_a0, t1 = *ptr_a1, t2 = *ptr_a2, t3 = *ptr_a3;

            if (beta) {
                asm volatile("vle64.v v0,  (%0)" : : "r"(C + i*ldc + j_tile));
                asm volatile("vle64.v v8,  (%0)" : : "r"(C + (i+1)*ldc + j_tile));
                asm volatile("vle64.v v16, (%0)" : : "r"(C + (i+2)*ldc + j_tile));
                asm volatile("vle64.v v28, (%0)" : : "r"(C + (i+3)*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 14, 0, 0              \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    "vfmacc.vf v16, %[ft2], v24              \n"
                    "add      %[ptr_a2], %[ptr_a2], %[inc_a] \n"
                    "fld      %[ft2], 0(%[ptr_a2])           \n"
                    "vfmacc.vf v28, %[ft3], v24              \n"
                    "add      %[ptr_a3], %[ptr_a3], %[inc_a] \n"
                    "fld      %[ft3], 0(%[ptr_a3])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1),
                      [ptr_a2] "+r"(ptr_a2), [ptr_a3] "+r"(ptr_a3),
                      [ft0] "+f"(t0), [ft1] "+f"(t1), [ft2] "+f"(t2), [ft3] "+f"(t3)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v8", "v16", "v24", "v28", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
                asm volatile("vfmul.vf v0,  v24, %0" : : "f"(t0));
                ptr_a0++; t0 = *ptr_a0;
                asm volatile("vfmul.vf v8,  v24, %0" : : "f"(t1));
                ptr_a1++; t1 = *ptr_a1;
                asm volatile("vfmul.vf v16, v24, %0" : : "f"(t2));
                ptr_a2++; t2 = *ptr_a2;
                asm volatile("vfmul.vf v28, v24, %0" : : "f"(t3));
                ptr_a3++; t3 = *ptr_a3;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 14, 0, 0              \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    "vfmacc.vf v16, %[ft2], v24              \n"
                    "add      %[ptr_a2], %[ptr_a2], %[inc_a] \n"
                    "fld      %[ft2], 0(%[ptr_a2])           \n"
                    "vfmacc.vf v28, %[ft3], v24              \n"
                    "add      %[ptr_a3], %[ptr_a3], %[inc_a] \n"
                    "fld      %[ft3], 0(%[ptr_a3])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1),
                      [ptr_a2] "+r"(ptr_a2), [ptr_a3] "+r"(ptr_a3),
                      [ft0] "+f"(t0), [ft1] "+f"(t1), [ft2] "+f"(t2), [ft3] "+f"(t3)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v8", "v16", "v24", "v28", "memory"
                );
            }
            asm volatile("vse64.v v0,  (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
            asm volatile("vse64.v v8,  (%0)" : : "r"(C + (i+1)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v16, (%0)" : : "r"(C + (i+2)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v28, (%0)" : : "r"(C + (i+3)*ldc + j_tile) : "memory");
        }
        for (; i < (int)M; i++) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double t0 = *ptr_a0;
            if (beta) {
                asm volatile("vle64.v v0, (%0)" : : "r"(C + i*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
                asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
                ptr_a0++; t0 = *ptr_a0;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            }
            asm volatile("vse64.v v0, (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
        }
    }

    asm volatile("fence");
    snrt_mcycle();
}

// ---------------------------------------------------------------------------
// gemm_fp64_simd_6x  — 6 output rows per M-loop iteration
// Rows 0-2 via v24; rows 3-5 via v26. frep body: 21 instructions.
// ---------------------------------------------------------------------------
static inline void gemm_fp64_simd_6x(
    uint32_t setup_ssr, uint32_t partition_banks,
    uint32_t transa, uint32_t transb,
    uint32_t M, uint32_t N, uint32_t K,
    void* A_p, uint32_t lda, void* B_p, uint32_t ldb,
    uint32_t beta, void* C_p, uint32_t ldc)
{
    if (transa || transb || partition_banks) return;

    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    snrt_mcycle();

    uint32_t inc_b = ldb * sizeof(double);
    uint32_t inc_a = sizeof(double);
    const uint32_t VL = 4;

    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" : : "r"(VL));

    for (int j_tile = 0; j_tile < (int)N; j_tile += VL) {
        int i = 0;
        for (; i + 5 < (int)M; i += 6) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double *ptr_a1 = A + (i+1) * lda;
            double *ptr_a2 = A + (i+2) * lda;
            double *ptr_a3 = A + (i+3) * lda;
            double *ptr_a4 = A + (i+4) * lda;
            double *ptr_a5 = A + (i+5) * lda;
            double t0 = *ptr_a0, t1 = *ptr_a1, t2 = *ptr_a2;
            double t3 = *ptr_a3, t4 = *ptr_a4, t5 = *ptr_a5;

            if (beta) {
                asm volatile("vle64.v v0,  (%0)" : : "r"(C + i*ldc + j_tile));
                asm volatile("vle64.v v8,  (%0)" : : "r"(C + (i+1)*ldc + j_tile));
                asm volatile("vle64.v v16, (%0)" : : "r"(C + (i+2)*ldc + j_tile));
                asm volatile("vle64.v v28, (%0)" : : "r"(C + (i+3)*ldc + j_tile));
                asm volatile("vle64.v v4,  (%0)" : : "r"(C + (i+4)*ldc + j_tile));
                asm volatile("vle64.v v12, (%0)" : : "r"(C + (i+5)*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 21, 0, 0              \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "vle64.v  v26, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    "vfmacc.vf v16, %[ft2], v24              \n"
                    "add      %[ptr_a2], %[ptr_a2], %[inc_a] \n"
                    "fld      %[ft2], 0(%[ptr_a2])           \n"
                    "vfmacc.vf v28, %[ft3], v26              \n"
                    "add      %[ptr_a3], %[ptr_a3], %[inc_a] \n"
                    "fld      %[ft3], 0(%[ptr_a3])           \n"
                    "vfmacc.vf v4,  %[ft4], v26              \n"
                    "add      %[ptr_a4], %[ptr_a4], %[inc_a] \n"
                    "fld      %[ft4], 0(%[ptr_a4])           \n"
                    "vfmacc.vf v12, %[ft5], v26              \n"
                    "add      %[ptr_a5], %[ptr_a5], %[inc_a] \n"
                    "fld      %[ft5], 0(%[ptr_a5])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1), [ptr_a2] "+r"(ptr_a2),
                      [ptr_a3] "+r"(ptr_a3), [ptr_a4] "+r"(ptr_a4), [ptr_a5] "+r"(ptr_a5),
                      [ft0] "+f"(t0), [ft1] "+f"(t1), [ft2] "+f"(t2),
                      [ft3] "+f"(t3), [ft4] "+f"(t4), [ft5] "+f"(t5)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v4", "v8", "v12", "v16", "v24", "v26", "v28", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
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
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 21, 0, 0              \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "vle64.v  v26, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    "vfmacc.vf v16, %[ft2], v24              \n"
                    "add      %[ptr_a2], %[ptr_a2], %[inc_a] \n"
                    "fld      %[ft2], 0(%[ptr_a2])           \n"
                    "vfmacc.vf v28, %[ft3], v26              \n"
                    "add      %[ptr_a3], %[ptr_a3], %[inc_a] \n"
                    "fld      %[ft3], 0(%[ptr_a3])           \n"
                    "vfmacc.vf v4,  %[ft4], v26              \n"
                    "add      %[ptr_a4], %[ptr_a4], %[inc_a] \n"
                    "fld      %[ft4], 0(%[ptr_a4])           \n"
                    "vfmacc.vf v12, %[ft5], v26              \n"
                    "add      %[ptr_a5], %[ptr_a5], %[inc_a] \n"
                    "fld      %[ft5], 0(%[ptr_a5])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1), [ptr_a2] "+r"(ptr_a2),
                      [ptr_a3] "+r"(ptr_a3), [ptr_a4] "+r"(ptr_a4), [ptr_a5] "+r"(ptr_a5),
                      [ft0] "+f"(t0), [ft1] "+f"(t1), [ft2] "+f"(t2),
                      [ft3] "+f"(t3), [ft4] "+f"(t4), [ft5] "+f"(t5)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v4", "v8", "v12", "v16", "v24", "v26", "v28", "memory"
                );
            }
            asm volatile("vse64.v v0,  (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
            asm volatile("vse64.v v8,  (%0)" : : "r"(C + (i+1)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v16, (%0)" : : "r"(C + (i+2)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v28, (%0)" : : "r"(C + (i+3)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v4,  (%0)" : : "r"(C + (i+4)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v12, (%0)" : : "r"(C + (i+5)*ldc + j_tile) : "memory");
        }
        for (; i < (int)M; i++) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double t0 = *ptr_a0;
            if (beta) {
                asm volatile("vle64.v v0, (%0)" : : "r"(C + i*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
                asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
                ptr_a0++; t0 = *ptr_a0;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            }
            asm volatile("vse64.v v0, (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
        }
    }

    asm volatile("fence");
    snrt_mcycle();
}

// ---------------------------------------------------------------------------
// gemm_fp64_simd_8x  — 8 output rows per M-loop iteration  [DEFAULT]
// Rows 0-3 via v24; rows 4-7 via v26. frep body: 27 instructions.
// ---------------------------------------------------------------------------
static inline void gemm_fp64_simd_8x(
    uint32_t setup_ssr, uint32_t partition_banks,
    uint32_t transa, uint32_t transb,
    uint32_t M, uint32_t N, uint32_t K,
    void* A_p, uint32_t lda, void* B_p, uint32_t ldb,
    uint32_t beta, void* C_p, uint32_t ldc)
{
    if (transa || transb || partition_banks) return;

    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    snrt_mcycle();

    uint32_t inc_b = ldb * sizeof(double);
    uint32_t inc_a = sizeof(double);
    const uint32_t VL = 4;

    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" : : "r"(VL));

    for (int j_tile = 0; j_tile < (int)N; j_tile += VL) {
        int i = 0;
        for (; i + 7 < (int)M; i += 8) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double *ptr_a1 = A + (i+1) * lda;
            double *ptr_a2 = A + (i+2) * lda;
            double *ptr_a3 = A + (i+3) * lda;
            double *ptr_a4 = A + (i+4) * lda;
            double *ptr_a5 = A + (i+5) * lda;
            double *ptr_a6 = A + (i+6) * lda;
            double *ptr_a7 = A + (i+7) * lda;
            double t0 = *ptr_a0, t1 = *ptr_a1, t2 = *ptr_a2, t3 = *ptr_a3;
            double t4 = *ptr_a4, t5 = *ptr_a5, t6 = *ptr_a6, t7 = *ptr_a7;

            if (beta) {
                asm volatile("vle64.v v0,  (%0)" : : "r"(C + i*ldc + j_tile));
                asm volatile("vle64.v v8,  (%0)" : : "r"(C + (i+1)*ldc + j_tile));
                asm volatile("vle64.v v16, (%0)" : : "r"(C + (i+2)*ldc + j_tile));
                asm volatile("vle64.v v28, (%0)" : : "r"(C + (i+3)*ldc + j_tile));
                asm volatile("vle64.v v4,  (%0)" : : "r"(C + (i+4)*ldc + j_tile));
                asm volatile("vle64.v v12, (%0)" : : "r"(C + (i+5)*ldc + j_tile));
                asm volatile("vle64.v v20, (%0)" : : "r"(C + (i+6)*ldc + j_tile));
                asm volatile("vle64.v v22, (%0)" : : "r"(C + (i+7)*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 27, 0, 0              \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "vle64.v  v26, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    "vfmacc.vf v16, %[ft2], v24              \n"
                    "add      %[ptr_a2], %[ptr_a2], %[inc_a] \n"
                    "fld      %[ft2], 0(%[ptr_a2])           \n"
                    "vfmacc.vf v28, %[ft3], v24              \n"
                    "add      %[ptr_a3], %[ptr_a3], %[inc_a] \n"
                    "fld      %[ft3], 0(%[ptr_a3])           \n"
                    "vfmacc.vf v4,  %[ft4], v26              \n"
                    "add      %[ptr_a4], %[ptr_a4], %[inc_a] \n"
                    "fld      %[ft4], 0(%[ptr_a4])           \n"
                    "vfmacc.vf v12, %[ft5], v26              \n"
                    "add      %[ptr_a5], %[ptr_a5], %[inc_a] \n"
                    "fld      %[ft5], 0(%[ptr_a5])           \n"
                    "vfmacc.vf v20, %[ft6], v26              \n"
                    "add      %[ptr_a6], %[ptr_a6], %[inc_a] \n"
                    "fld      %[ft6], 0(%[ptr_a6])           \n"
                    "vfmacc.vf v22, %[ft7], v26              \n"
                    "add      %[ptr_a7], %[ptr_a7], %[inc_a] \n"
                    "fld      %[ft7], 0(%[ptr_a7])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1),
                      [ptr_a2] "+r"(ptr_a2), [ptr_a3] "+r"(ptr_a3),
                      [ptr_a4] "+r"(ptr_a4), [ptr_a5] "+r"(ptr_a5),
                      [ptr_a6] "+r"(ptr_a6), [ptr_a7] "+r"(ptr_a7),
                      [ft0] "+f"(t0), [ft1] "+f"(t1), [ft2] "+f"(t2), [ft3] "+f"(t3),
                      [ft4] "+f"(t4), [ft5] "+f"(t5), [ft6] "+f"(t6), [ft7] "+f"(t7)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v4", "v8", "v12", "v16", "v20", "v22", "v24", "v26", "v28", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
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
                asm volatile("vfmul.vf v20, v24, %0" : : "f"(t6));
                ptr_a6++; t6 = *ptr_a6;
                asm volatile("vfmul.vf v22, v24, %0" : : "f"(t7));
                ptr_a7++; t7 = *ptr_a7;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 27, 0, 0              \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "vle64.v  v26, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    "vfmacc.vf v8,  %[ft1], v24              \n"
                    "add      %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld      %[ft1], 0(%[ptr_a1])           \n"
                    "vfmacc.vf v16, %[ft2], v24              \n"
                    "add      %[ptr_a2], %[ptr_a2], %[inc_a] \n"
                    "fld      %[ft2], 0(%[ptr_a2])           \n"
                    "vfmacc.vf v28, %[ft3], v24              \n"
                    "add      %[ptr_a3], %[ptr_a3], %[inc_a] \n"
                    "fld      %[ft3], 0(%[ptr_a3])           \n"
                    "vfmacc.vf v4,  %[ft4], v26              \n"
                    "add      %[ptr_a4], %[ptr_a4], %[inc_a] \n"
                    "fld      %[ft4], 0(%[ptr_a4])           \n"
                    "vfmacc.vf v12, %[ft5], v26              \n"
                    "add      %[ptr_a5], %[ptr_a5], %[inc_a] \n"
                    "fld      %[ft5], 0(%[ptr_a5])           \n"
                    "vfmacc.vf v20, %[ft6], v26              \n"
                    "add      %[ptr_a6], %[ptr_a6], %[inc_a] \n"
                    "fld      %[ft6], 0(%[ptr_a6])           \n"
                    "vfmacc.vf v22, %[ft7], v26              \n"
                    "add      %[ptr_a7], %[ptr_a7], %[inc_a] \n"
                    "fld      %[ft7], 0(%[ptr_a7])           \n"
                    : [ptr_b]  "+r"(ptr_b),
                      [ptr_a0] "+r"(ptr_a0), [ptr_a1] "+r"(ptr_a1),
                      [ptr_a2] "+r"(ptr_a2), [ptr_a3] "+r"(ptr_a3),
                      [ptr_a4] "+r"(ptr_a4), [ptr_a5] "+r"(ptr_a5),
                      [ptr_a6] "+r"(ptr_a6), [ptr_a7] "+r"(ptr_a7),
                      [ft0] "+f"(t0), [ft1] "+f"(t1), [ft2] "+f"(t2), [ft3] "+f"(t3),
                      [ft4] "+f"(t4), [ft5] "+f"(t5), [ft6] "+f"(t6), [ft7] "+f"(t7)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v4", "v8", "v12", "v16", "v20", "v22", "v24", "v26", "v28", "memory"
                );
            }
            asm volatile("vse64.v v0,  (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
            asm volatile("vse64.v v8,  (%0)" : : "r"(C + (i+1)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v16, (%0)" : : "r"(C + (i+2)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v28, (%0)" : : "r"(C + (i+3)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v4,  (%0)" : : "r"(C + (i+4)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v12, (%0)" : : "r"(C + (i+5)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v20, (%0)" : : "r"(C + (i+6)*ldc + j_tile) : "memory");
            asm volatile("vse64.v v22, (%0)" : : "r"(C + (i+7)*ldc + j_tile) : "memory");
        }
        for (; i < (int)M; i++) {
            double *ptr_b  = B + j_tile;
            double *ptr_a0 = A + i * lda;
            double t0 = *ptr_a0;
            if (beta) {
                asm volatile("vle64.v v0, (%0)" : : "r"(C + i*ldc + j_tile));
                uint32_t n_frep = K - 1;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            } else {
                asm volatile("vle64.v v24, (%0)" : : "r"(ptr_b));
                ptr_b += ldb;
                asm volatile("vfmul.vf v0, v24, %0" : : "f"(t0));
                ptr_a0++; t0 = *ptr_a0;
                uint32_t n_frep = K - 2;
                asm volatile(
                    "frep.o %[n_frep], 5, 0, 0               \n"
                    "vle64.v  v24, (%[ptr_b])                \n"
                    "add      %[ptr_b],  %[ptr_b],  %[inc_b] \n"
                    "vfmacc.vf v0,  %[ft0], v24              \n"
                    "add      %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld      %[ft0], 0(%[ptr_a0])           \n"
                    : [ptr_b] "+r"(ptr_b), [ptr_a0] "+r"(ptr_a0), [ft0] "+f"(t0)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(n_frep)
                    : "v0", "v24", "memory"
                );
            }
            asm volatile("vse64.v v0, (%0)" : : "r"(C + i*ldc + j_tile) : "memory");
        }
    }

    asm volatile("fence");
    snrt_mcycle();
}
