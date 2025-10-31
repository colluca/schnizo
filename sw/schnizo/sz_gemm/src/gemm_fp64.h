// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Adapted version for Schnizo
//
// Author: Pascal Etterli <petterli@student.ethz.ch>
//         Tim Fischer <fischeti@iis.ee.ethz.ch>
//         Luca Bertaccini <lbertaccini@iis.ee.ethz.ch>
//         Luca Colagrande <colluca@iis.ee.ethz.ch>
//         Viviane Potocnik <vivianep@iis.ee.ethz.ch>

// Floating-point multiplications by zero cannot be optimized as in some
// edge cases they do not yield zero:
// - 0f * NaN = NaN
// - 0f * INFINITY == NaN
// Thus in order to optimize it, we need to test for zero. You can use this
// function for free when `multiplier` is a constant.
static inline double multiply_opt(double multiplicand, double multiplier) {
    if (multiplier)
        return multiplicand * multiplier;
    else
        return 0;
}

static inline void gemm_fp64_naive(uint32_t setup_ssr, uint32_t partition_banks,
                                   uint32_t transa, uint32_t transb, uint32_t M,
                                   uint32_t N, uint32_t K, void* A_p,
                                   uint32_t lda, void* B_p, uint32_t ldb,
                                   uint32_t beta, void* C_p, uint32_t ldc) {
    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    uint32_t elems_per_line =
        (snrt_cluster_compute_core_num() * SNRT_TCDM_BANK_WIDTH) /
        sizeof(double);

    if (!transa && !transb) {
        snrt_mcycle();
        for (uint32_t m = 0; m < M; m++) {
            for (uint32_t n = 0; n < N; n++) {
                uint32_t c_idx;
                uint32_t n_inner, n_outer, n_outer_stride;
                if (partition_banks) {
                    n_inner = n % elems_per_line;
                    n_outer = n / elems_per_line;
                    n_outer_stride = SNRT_TCDM_HYPERBANK_WIDTH / sizeof(double);
                    c_idx = m * ldc + n_outer * n_outer_stride + n_inner;
                } else {
                    c_idx = m * ldc + n;
                }
                double c0 = multiply_opt(C[c_idx], beta);
                for (uint32_t k = 0; k < K; k++) {
                    uint32_t a_idx, b_idx;
                    if (partition_banks) {
                        uint32_t k_inner = k % elems_per_line;
                        uint32_t k_outer = k / elems_per_line;
                        uint32_t k_outer_stride =
                            SNRT_TCDM_HYPERBANK_WIDTH / sizeof(double);
                        a_idx = m * lda + k_outer * k_outer_stride + k_inner;
                        b_idx = k * ldb + n_outer * n_outer_stride + n_inner;
                    } else {
                        a_idx = m * lda + k;
                        b_idx = k * ldb + n;
                    }
                    c0 += A[a_idx] * B[b_idx];
                }
                C[c_idx] = c0;
            }
        }
        snrt_mcycle();
    } else if (transa && !transb) {
        snrt_mcycle();
        for (uint32_t m = 0; m < M; m++) {
            for (uint32_t n = 0; n < N; n++) {
                double c0 = multiply_opt(C[m * ldc + n], beta);
                for (uint32_t k = 0; k < K; k++) {
                    c0 += A[k * M * lda + m * lda] * B[k * ldb + n];
                }
                C[m * ldc + n] = c0;
            }
        }
        snrt_mcycle();
    } else if (!transa && transb) {
        snrt_mcycle();
        for (uint32_t m = 0; m < M; m++) {
            for (uint32_t n = 0; n < N; n++) {
                double c0 = multiply_opt(C[m * ldc + n], beta);
                for (uint32_t k = 0; k < K; k++) {
                    c0 += A[m * lda + k] * B[n * ldb + k];
                }
                C[m * ldc + n] = c0;
            }
        }
        snrt_mcycle();
    } else {
        snrt_mcycle();
        for (uint32_t m = 0; m < M; m++) {
            for (uint32_t n = 0; n < N; n++) {
                double c0 = multiply_opt(C[m * ldc + n], beta);
                for (uint32_t k = 0; k < K; k++) {
                    c0 += A[k * M * lda + m * lda] * B[k + n * ldb];
                }
                C[m * ldc + n] = c0;
            }
        }
        snrt_mcycle();
    }
}

// Requires that A and B is regular and not transposed!
static inline void gemm_fp64_opt(uint32_t setup_ssr, uint32_t partition_banks,
                                 uint32_t transa, uint32_t transb, uint32_t M,
                                 uint32_t N, uint32_t K, void* A_p,
                                 uint32_t lda, void* B_p, uint32_t ldb,
                                 uint32_t beta, void* C_p, uint32_t ldc) {
    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    // Unrolling factor of most inner loop.
    // Should be at least as high as the FMA delay
    // for maximum utilization
    const uint32_t unroll = 4; // limitted by the number of slots

    // Schnizo frep is non nested so we have to compute the address offsets manually.
    double* ptr_a;
    double* ptr_b;
    uint32_t inc_a, inc_b;

    snrt_mcycle();

    for (uint32_t m = 0; m < M; m++) {
        uint32_t n = 0;
        // Guard that we only compute columns which can be fully unrolled in the N dimension
        for (uint32_t n0 = 0; n0 < N / unroll; n0++) {
            double c[unroll];

            // Start addresses
            // Assumes that A and B is regular and not transposed

            // Set the A pointer to the beginning of the row
            ptr_a = &A[m*lda];
            inc_a = sizeof(double);
            // Set the B pointer to the next columns
            ptr_b = &B[n];
            inc_b = sizeof(double) * ldb;


            // Load intermediate result - beta is always zero
            c[0] = 0.0;
            c[1] = 0.0;
            c[2] = 0.0;
            c[3] = 0.0;

            asm volatile(
            "frep.o %[n_frep], 11, 0, 0 \n"
            "fld     ft0,  0(%[ptr_a])\n"
            "fld     ft1,  0(%[ptr_b])\n"
            "fld     ft3,  8(%[ptr_b])\n"
            "fld     ft5, 16(%[ptr_b])\n"
            "fld     ft7, 24(%[ptr_b])\n"
            "add     %[ptr_a], %[ptr_a], %[inc_a]\n"
            "add     %[ptr_b], %[ptr_b], %[inc_b]\n"
            "fmadd.d %[c0], ft0, ft1, %[c0] \n"
            "fmadd.d %[c1], ft0, ft3, %[c1] \n"
            "fmadd.d %[c2], ft0, ft5, %[c2] \n"
            "fmadd.d %[c3], ft0, ft7, %[c3] \n"
            : [c0] "+f"(c[0]), [c1] "+f"(c[1]),
              [c2] "+f"(c[2]), [c3] "+f"(c[3]),
              [ptr_a] "+r"(ptr_a), [ptr_b] "+r"(ptr_b)
            : [inc_a] "r"(inc_a), [inc_b] "r"(inc_b),
              [n_frep] "r"(K - 1) // frep iterates n+1 times
            : "ft0", "ft1", "ft3", "ft5", "ft7", "memory");

            // Store results back
            C[m * ldc + n + 0] = c[0];
            C[m * ldc + n + 1] = c[1];
            C[m * ldc + n + 2] = c[2];
            C[m * ldc + n + 3] = c[3];
            n += unroll;
        }
    }

    snrt_mcycle();
}


// Requires that A and B is regular and not transposed!
static inline void gemm_fp64_frep_vec(uint32_t setup_ssr, uint32_t partition_banks,
                                 uint32_t transa, uint32_t transb, uint32_t M,
                                 uint32_t N, uint32_t K, void* A_p,
                                 uint32_t lda, void* B_p, uint32_t ldb,
                                 uint32_t beta, void* C_p, uint32_t ldc) {
    double* A = (double*)A_p;
    double* B = (double*)B_p;
    double* C = (double*)C_p;

    // Unrolling factor of most inner loop.
    // Should be at least as high as the FMA delay
    // for maximum utilization
    const uint32_t unroll = 4; // limitted by the number of slots

    // Schnizo frep is non nested so we have to compute the address offsets manually.
    double* ptr_a;
    double* ptr_b;
    uint32_t inc_a, inc_b;

    snrt_mcycle();

    for (uint32_t m = 0; m < M; m++) {
        uint32_t n = 0;
        // Guard that we only compute columns which can be fully unrolled in the N dimension
        for (uint32_t n0 = 0; n0 < N / unroll; n0++) {
            double c[unroll];

            // Start addresses
            // Assumes that A and B is regular and not transposed

            // Set the A pointer to the beginning of the row
            ptr_a = &A[m*lda];
            inc_a = sizeof(double);
            // Set the B pointer to the next columns
            ptr_b = &B[n];
            inc_b = sizeof(double) * ldb;


            // Load intermediate result - beta is always zero
            c[0] = 0.0;
            c[1] = 0.0;
            c[2] = 0.0;
            c[3] = 0.0;

            asm volatile(
            "frep.o %[n_frep], 11, 0, 0 \n"
            "fld     ft0,  0(%[ptr_a])\n"
            "fld     ft1,  0(%[ptr_b])\n"
            "fld     ft3,  8(%[ptr_b])\n"
            "fld     ft5, 16(%[ptr_b])\n"
            "fld     ft7, 24(%[ptr_b])\n"
            "add     %[ptr_a], %[ptr_a], %[inc_a]\n"
            "add     %[ptr_b], %[ptr_b], %[inc_b]\n"
            "fmadd.d %[c0], ft0, ft1, %[c0] \n"
            "fmadd.d %[c1], ft0, ft3, %[c1] \n"
            "fmadd.d %[c2], ft0, ft5, %[c2] \n"
            "fmadd.d %[c3], ft0, ft7, %[c3] \n"
            : [c0] "+f"(c[0]), [c1] "+f"(c[1]),
              [c2] "+f"(c[2]), [c3] "+f"(c[3]),
              [ptr_a] "+r"(ptr_a), [ptr_b] "+r"(ptr_b)
            : [inc_a] "r"(inc_a), [inc_b] "r"(inc_b),
              [n_frep] "r"(K - 1) // frep iterates n+1 times
            : "ft0", "ft1", "ft3", "ft5", "ft7", "memory");

            // Store results back
            C[m * ldc + n + 0] = c[0];
            C[m * ldc + n + 1] = c[1];
            C[m * ldc + n + 2] = c[2];
            C[m * ldc + n + 3] = c[3];
            n += unroll;
        }
    }

    snrt_mcycle();
}
