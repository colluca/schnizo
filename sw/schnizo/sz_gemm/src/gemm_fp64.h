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

// The pointer are called according to which loop they are updated in
static inline void gemm_fp64_vec_naive_2sregs(uint32_t setup_ssr, uint32_t partition_banks,
                                       uint32_t transa, uint32_t transb,
                                       uint32_t M, uint32_t N, uint32_t K,
                                       void *A_p, uint32_t lda, void *B_p, uint32_t ldb,
                                       uint32_t beta, void *C_p, uint32_t ldc) {
    // Only supports !transa && !transb and non bank-partitioned layout.
    if (transa || transb || partition_banks)
        return; // Fallback not implemented here.

    snrt_mcycle();

    int computed_col = 0;
    while (computed_col < N) {

        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e64, m1, ta, ma"
                 : [vl] "=r"(vl)
                 : [rvl] "r"(N-computed_col));

        double * C_l1 = (double *)C_p + computed_col;
        double * B_l1 = (double *)B_p + computed_col;

        for(int i = 0; i < M; i+=2) {
            double *C_l2_1 = C_l1 + ldc*i;
            double *C_l2_2 = C_l1 + ldc*(i+1);

            uint8_t use_second = i+1 < M;

            if (beta) {
                asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
                if (use_second) asm volatile("vle64.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                if (use_second) asm volatile("vmv.v.i v8, 0");
            }
            
            double * B_l3_1 = B_l1;

            double *A_l3_1 = (double *)A_p + lda*i;
            double *A_l3_2 = (double *)A_p + lda*(i+1);

            double t0 = *A_l3_1;
            double t1 = *A_l3_2;

            // #pragma clang loop unroll(disable)
            for (int j = 0; j < K; j++) {
                asm volatile("vle64.v v16, (%0);" ::"r"(B_l3_1));
                // B_l3_1 += ldb;
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
                // A_l3_1++; t0 = *A_l3_1;
                asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
                // A_l3_2++; t1 = *A_l3_2;
            }

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1));
            if (use_second) asm volatile("vse64.v v8, (%0);" ::"r"(C_l2_2));
        }

        computed_col += vl;
    }

    snrt_mcycle();
}

// The pointer are called according to which loop they are updated in
static inline void gemm_fp64_vec_naive_2sregs_unrolled(uint32_t setup_ssr, uint32_t partition_banks,
                                       uint32_t transa, uint32_t transb,
                                       uint32_t M, uint32_t N, uint32_t K,
                                       void *A_p, uint32_t lda, void *B_p, uint32_t ldb,
                                       uint32_t beta, void *C_p, uint32_t ldc) {
    // Only supports !transa && !transb and non bank-partitioned layout.
    if (transa || transb || partition_banks)
        return; // Fallback not implemented here.

    snrt_mcycle();

    int computed_col = 0;
    while (computed_col < N) {

        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e64, m1, ta, ma"
                 : [vl] "=r"(vl)
                 : [rvl] "r"(N-computed_col));

        double * C_l1 = (double *)C_p + computed_col;
        double * B_l1 = (double *)B_p + computed_col;

        for(int i = 0; i < M; i+=2) {
            double *C_l2_1 = C_l1 + ldc*i;
            double *C_l2_2 = C_l1 + ldc*(i+1);

            uint8_t use_second = i+1 < M;

            if (beta) {
                asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
                if (use_second) asm volatile("vle64.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                if (use_second) asm volatile("vmv.v.i v8, 0");
            }
            
            double * B_l3_1 = B_l1;

            double *A_l3_1 = (double *)A_p + lda*i;
            double *A_l3_2 = (double *)A_p + lda*(i+1);

            double t0 = *A_l3_1;
            double t1 = *A_l3_2;

            #pragma clang loop unroll(disable)
            for (int j = 0; j + 1 < K; j+=2) {
                asm volatile("vle64.v v16, (%0);" ::"r"(B_l3_1));
                B_l3_1 += ldb;
                asm volatile("vle64.v v24, (%0);" ::"r"(B_l3_1));
                B_l3_1 += ldb;
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
                A_l3_1++; t0 = *A_l3_1;
                asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
                A_l3_2++; t1 = *A_l3_2;
                asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
                A_l3_1++; t0 = *A_l3_1;
                asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
                A_l3_2++; t1 = *A_l3_2;
            }

            if (K%2) {
                asm volatile("vle64.v v16, (%0);" ::"r"(B_l3_1));
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
                asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
            }

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1));
            if (use_second) asm volatile("vse64.v v8, (%0);" ::"r"(C_l2_2));
        }

        computed_col += vl;
    }

    snrt_mcycle();
}

// Requires that A and B is regular and not transposed!
static inline void gemm_fp64_vec_frep_unrolled(
    uint32_t setup_ssr, uint32_t partition_banks, uint32_t transa,
    uint32_t transb, uint32_t M, uint32_t N, uint32_t K, void* A_p,
    uint32_t lda, void* B_p, uint32_t ldb, uint32_t beta, void* C_p,
    uint32_t ldc) {
    if (transa || transb || partition_banks)
        return;  // Fallback not implemented here.

    snrt_mcycle();

    uint64_t inc_b = (uint64_t)ldb * sizeof(double);
    uint64_t inc_a = sizeof(double);

    int computed_col = 0;
    while (computed_col < N) {
        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e64, m1, ta, ma"
                     : [vl] "=r"(vl)
                     : [rvl] "r"(N - computed_col));

        double* C_l1 = (double*)C_p + computed_col;
        double* B_l1 = (double*)B_p + computed_col;

        for (int i = 0; i < M; i += 2) {
            double* C_l2_1 = C_l1 + ldc * i;
            double* C_l2_2 = C_l1 + ldc * (i + 1);

            uint8_t use_second = i + 1 < M;

            if (beta) {
                asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
                if (use_second) asm volatile("vle64.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                if (use_second) asm volatile("vmv.v.i v8, 0");
            }

            double* B_l3_1 = B_l1;
            double* A_l3_1 = (double*)A_p + lda * i;
            double* A_l3_2 = (double*)A_p + lda * (i + 1);

            // Load the first two scalar values
            double t0 = *A_l3_1;
            double t1 = *A_l3_2;

            asm volatile(
                    "frep.o  %[n_frep], 16, 0, 0 \n"
                    // Body:
                    "vle64.v v16, (%[ptr_b]) \n"
                    "add     %[ptr_b], %[ptr_b], %[inc_b] \n"
                    "vle64.v v24, (%[ptr_b]) \n"
                    "add     %[ptr_b], %[ptr_b], %[inc_b] \n"
                    "vfmacc.vf v0, %[ft0], v16 \n"
                    "add     %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld     %[ft0], 0(%[ptr_a0]) \n"
                    "vfmacc.vf v8, %[ft1], v16 \n"
                    "add     %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld     %[ft1], 0(%[ptr_a1]) \n"
                    "vfmacc.vf v0, %[ft0], v24 \n"
                    "add     %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                    "fld     %[ft0], 0(%[ptr_a0]) \n"
                    "vfmacc.vf v8, %[ft1], v24 \n"
                    "add     %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                    "fld     %[ft1], 0(%[ptr_a1]) \n"
                    : [ptr_b] "+r"(B_l3_1), [ptr_a0] "+r"(A_l3_1),
                      [ptr_a1] "+r"(A_l3_2), [ft0] "+f"(t0), [ft1] "+f"(t1)
                    : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a),
                      [n_frep] "r"(K/2 - 1)
                    :);

            if (K%2) {
                asm volatile(
                    "vle64.v v16, (%[ptr_b]) \n"
                    "vfmacc.vf v0, %[ft0], v16 \n"
                    "vfmacc.vf v8, %[ft1], v16 \n"
                    :
                    : [ptr_b] "r"(B_l3_1), [ft0] "f"(t0), [ft1] "f"(t1)
                    :);
            }

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1) : "memory");
            if (use_second)
                asm volatile("vse64.v v8, (%0);" ::"r"(C_l2_2) : "memory");
        }

        computed_col += vl;
    }

    snrt_mcycle();
}

// Requires that A and B is regular and not transposed!
// Should work for all MNK possible dimensions, not tested for very specific edge cases
static inline void gemm_fp64_vec_frep(uint32_t setup_ssr, uint32_t partition_banks,
                                 uint32_t transa, uint32_t transb, uint32_t M,
                                 uint32_t N, uint32_t K, void* A_p,
                                 uint32_t lda, void* B_p, uint32_t ldb,
                                 uint32_t beta, void* C_p, uint32_t ldc) {

    if (transa || transb || partition_banks)
        return; // Fallback not implemented here.

    snrt_mcycle();

    uint64_t inc_b = (uint64_t)ldb * sizeof(double);
    uint64_t inc_a = sizeof(double);

    int computed_col = 0;
    while (computed_col < N) {

        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e64, m1, ta, ma"
                 : [vl] "=r"(vl)
                 : [rvl] "r"(N-computed_col));

        double * C_l1 = (double *)C_p + computed_col;
        double * B_l1 = (double *)B_p + computed_col;

        for (int i = 0; i < M; i += 2) {
            double* C_l2_1 = C_l1 + ldc * i;
            double* C_l2_2 = C_l1 + ldc * (i + 1);

            uint8_t use_second = i + 1 < M;

            if (beta) {
                asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
                if (use_second) asm volatile("vle64.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                if (use_second) asm volatile("vmv.v.i v8, 0");
            }

            double* B_l3_1 = B_l1;

            double* A_l3_1 = (double*)A_p + lda * i;
            double* A_l3_2 = (double*)A_p + lda * (i + 1);

            double t0 = *A_l3_1;
            double t1 = *A_l3_2;

            asm volatile(
                "frep.o  %[n_frep], 8, 0, 0 \n"
                // Body:
                "vle64.v v16, (%[ptr_b])\n"
                "add     %[ptr_b], %[ptr_b], %[inc_b]\n"
                "vfmacc.vf v0, %[ft0], v16\n"
                "vfmacc.vf v8, %[ft1], v16\n"
                "add     %[ptr_a0], %[ptr_a0], %[inc_a]\n"
                "fld     %[ft0], 0(%[ptr_a0])\n"
                "add     %[ptr_a1], %[ptr_a1], %[inc_a]\n"
                "fld     %[ft1], 0(%[ptr_a1])\n"
                : [ptr_b] "+r"(B_l3_1), [ptr_a0] "+r"(A_l3_1),
                  [ptr_a1] "+r"(A_l3_2), [ft0] "+f"(t0), [ft1] "+f"(t1)
                : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(K - 1)
                : "memory");

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1));
            if (use_second) asm volatile("vse64.v v8, (%0);" ::"r"(C_l2_2));
        }

        computed_col += vl;
    }

    snrt_mcycle();
}



// Requires that A and B is regular and not transposed!
// Should work for all MNK possible dimensions, not tested for very specific
// edge cases
static inline void gemm_fp64_vec_frep_unrolled_mopt(
    uint32_t setup_ssr, uint32_t partition_banks, uint32_t transa,
    uint32_t transb, uint32_t M, uint32_t N, uint32_t K, void* A_p,
    uint32_t lda, void* B_p, uint32_t ldb, uint32_t beta, void* C_p,
    uint32_t ldc) {

    if (transa || transb || partition_banks)
        return;  // Fallback not implemented here.

    snrt_mcycle();

    uint64_t inc_b = (uint64_t)ldb * sizeof(double);
    uint64_t inc_a = sizeof(double);

    int computed_col = 0;
    while (computed_col < N) {
        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e64, m1, ta, ma"
                     : [vl] "=r"(vl)
                     : [rvl] "r"(N - computed_col));

        double* C_l1 = (double*)C_p + computed_col;
        double* B_l1 = (double*)B_p + computed_col;
        
        double* C_l2_1 = C_l1;
        double* C_l2_2 = C_l1 + ldc;
        double* A_l2_1 = (double*)A_p;
        double* A_l2_2 = (double*)A_p + lda;

        for (int i = 0; i+1 < M; i += 2) {

            if (beta) {
                asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
                asm volatile("vle64.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                asm volatile("vmv.v.i v8, 0");
            }

            double* B_l3_1 = B_l1;
            double* A_l3_1 = A_l2_1;
            double* A_l3_2 = A_l2_2;

            // Load the first two scalar values
            double t0 = *A_l3_1;
            double t1 = *A_l3_2;

            asm volatile(
                "frep.o  %[n_frep], 16, 0, 0 \n"
                // Body:
                "vle64.v v16, (%[ptr_b]) \n"
                "add     %[ptr_b], %[ptr_b], %[inc_b] \n"
                "vle64.v v24, (%[ptr_b]) \n"
                "add     %[ptr_b], %[ptr_b], %[inc_b] \n"
                "vfmacc.vf v0, %[ft0], v16 \n"
                "add     %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                "fld     %[ft0], 0(%[ptr_a0]) \n"
                "vfmacc.vf v8, %[ft1], v16 \n"
                "add     %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                "fld     %[ft1], 0(%[ptr_a1]) \n"
                "vfmacc.vf v0, %[ft0], v24 \n"
                "add     %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                "fld     %[ft0], 0(%[ptr_a0]) \n"
                "vfmacc.vf v8, %[ft1], v24 \n"
                "add     %[ptr_a1], %[ptr_a1], %[inc_a] \n"
                "fld     %[ft1], 0(%[ptr_a1]) \n"
                : [ptr_b] "+r"(B_l3_1), [ptr_a0] "+r"(A_l3_1),
                  [ptr_a1] "+r"(A_l3_2), [ft0] "+f"(t0), [ft1] "+f"(t1)
                :
                [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(K / 2 - 1)
                :);

            if (K % 2) {
                asm volatile(
                    "vle64.v v16, (%[ptr_b]) \n"
                    "vfmacc.vf v0, %[ft0], v16 \n"
                    "vfmacc.vf v8, %[ft1], v16 \n"
                    :
                    : [ptr_b] "r"(B_l3_1), [ft0] "f"(t0), [ft1] "f"(t1)
                    :);
            }

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1) : "memory");
            asm volatile("vse64.v v8, (%0);" ::"r"(C_l2_2) : "memory");
            
            C_l2_1 += ldc * 2;
            C_l2_2 = C_l2_1 + ldc;
            A_l2_1 += lda * 2;
            A_l2_2 = A_l2_1 + lda;
        }

        if (M % 2) {
            if (beta) asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
            else asm volatile("vmv.v.i v0, 0");

            double* B_l3_1 = B_l1;
            double* A_l3_1 = A_l2_1;

            double t0 = *A_l3_1;

            asm volatile(
                "frep.o  %[n_frep], 10, 0, 0 \n"
                // Body:
                "vle64.v v16, (%[ptr_b]) \n"
                "add     %[ptr_b], %[ptr_b], %[inc_b] \n"
                "vle64.v v24, (%[ptr_b]) \n"
                "add     %[ptr_b], %[ptr_b], %[inc_b] \n"
                "vfmacc.vf v0, %[ft0], v16 \n"
                "add     %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                "fld     %[ft0], 0(%[ptr_a0]) \n"
                "vfmacc.vf v0, %[ft0], v24 \n"
                "add     %[ptr_a0], %[ptr_a0], %[inc_a] \n"
                "fld     %[ft0], 0(%[ptr_a0]) \n"
                : [ptr_b] "+r"(B_l3_1), [ptr_a0] "+r"(A_l3_1), [ft0] "+f"(t0)
                : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(K / 2 - 1)
                :);

            if (K % 2)
                asm volatile(
                    "vle64.v v16, (%[ptr_b]) \n"
                    "vfmacc.vf v0, %[ft0], v16 \n"
                    :
                    : [ptr_b] "r"(B_l3_1), [ft0] "f"(t0)
                    :);

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1) : "memory");
        }

        computed_col += vl;
    }

    snrt_mcycle();
}


// The pointer are called according to which loop they are updated in
static inline void gemm_fp64_vec_naive_2sregs_unrolled_mopt(uint32_t setup_ssr, uint32_t partition_banks,
                                       uint32_t transa, uint32_t transb,
                                       uint32_t M, uint32_t N, uint32_t K,
                                       void *A_p, uint32_t lda, void *B_p, uint32_t ldb,
                                       uint32_t beta, void *C_p, uint32_t ldc) {
    // Only supports !transa && !transb and non bank-partitioned layout.
    if (transa || transb || partition_banks)
        return; // Fallback not implemented here.

    snrt_mcycle();

    int computed_col = 0;
    while (computed_col < N) {

        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e64, m1, ta, ma"
                 : [vl] "=r"(vl)
                 : [rvl] "r"(N-computed_col));

        double * C_l1 = (double *)C_p + computed_col;
        double * B_l1 = (double *)B_p + computed_col;

        double *C_l2_1 = C_l1;
        double *C_l2_2 = C_l1 + ldc;
        double *A_l2_1 = (double *)A_p;
        double *A_l2_2 = (double *)A_p + lda;

        for(int i = 0; i+1 < M; i+=2) {

            if (beta) {
                asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
                asm volatile("vle64.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                asm volatile("vmv.v.i v8, 0");
            }
            
            double * B_l3_1 = B_l1;

            double *A_l3_1 = A_l2_1;
            double *A_l3_2 = A_l2_2;

            double t0 = *A_l3_1;
            double t1 = *A_l3_2;

            int j;
            #pragma clang loop unroll(disable)
            for (j = 0; j + 1 < K; j+=2) {
                asm volatile("vle64.v v16, (%0);" ::"r"(B_l3_1));
                B_l3_1 += ldb;
                asm volatile("vle64.v v24, (%0);" ::"r"(B_l3_1));
                B_l3_1 += ldb;
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
                A_l3_1++; t0 = *A_l3_1;
                asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
                A_l3_2++; t1 = *A_l3_2;
                asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
                A_l3_1++; t0 = *A_l3_1;
                asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
                A_l3_2++; t1 = *A_l3_2;
            }

            if (K%2) {
                asm volatile("vle64.v v16, (%0);" ::"r"(B_l3_1));
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
                asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
            }

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1));
            asm volatile("vse64.v v8, (%0);" ::"r"(C_l2_2));

            C_l2_1 += ldc * 2;
            C_l2_2 = C_l2_1 + ldc;
            A_l2_1 += lda * 2;
            A_l2_2 = A_l2_1 + lda;
        }

        if (M % 2) {
            if (beta) asm volatile("vle64.v v0, (%0);" ::"r"(C_l2_1));
            else asm volatile("vmv.v.i v0, 0");

            double* B_l3_1 = B_l1;
            double* A_l3_1 = A_l2_1;

            double t0 = *A_l3_1;

            #pragma clang loop unroll(disable)
            for (int j = 0; j + 1 < K; j+=2) {
                asm volatile("vle64.v v16, (%0);" ::"r"(B_l3_1));
                B_l3_1 += ldb;
                asm volatile("vle64.v v24, (%0);" ::"r"(B_l3_1));
                B_l3_1 += ldb;
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
                A_l3_1++; t0 = *A_l3_1;
                asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
                A_l3_1++; t0 = *A_l3_1;
            }

            if (K%2) {
                asm volatile("vle64.v v16, (%0);" ::"r"(B_l3_1));
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
            }

            asm volatile("vse64.v v0, (%0);" ::"r"(C_l2_1) : "memory");
        }

        computed_col += vl;
    }

    snrt_mcycle();
}



// TODO: double check, written by chatgpt
static inline void gemm_fp64_vec_naive_16sregs(uint32_t setup_ssr, uint32_t partition_banks,
                                               uint32_t transa, uint32_t transb,
                                               uint32_t M, uint32_t N, uint32_t K,
                                               void *A_p, uint32_t lda, void *B_p, uint32_t ldb,
                                               uint32_t beta, void *C_p, uint32_t ldc) {
    if (transa || transb || partition_banks)
        return;

    snrt_mcycle();

    int col = 0;
    while (col < (int)N) {

        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e64, m1, ta, ma"
                     : [vl] "=r"(vl)
                     : [rvl] "r"(N - col));

        double *C_col = (double *)C_p + col;
        double *B_col = (double *)B_p + col;

        int row = 0;
        for (; row + 15 < (int)M; row += 16) {

            double *Cptr[16];
            double *Aptr[16];
            for (int r = 0; r < 16; ++r) {
                Cptr[r] = C_col + ldc * (row + r);
                Aptr[r] = (double *)A_p + lda * (row + r);
            }

            if (beta) {
                asm volatile("vle64.v v0,  (%0)" :: "r"(Cptr[0]));
                asm volatile("vle64.v v1,  (%0)" :: "r"(Cptr[1]));
                asm volatile("vle64.v v2,  (%0)" :: "r"(Cptr[2]));
                asm volatile("vle64.v v3,  (%0)" :: "r"(Cptr[3]));
                asm volatile("vle64.v v4,  (%0)" :: "r"(Cptr[4]));
                asm volatile("vle64.v v5,  (%0)" :: "r"(Cptr[5]));
                asm volatile("vle64.v v6,  (%0)" :: "r"(Cptr[6]));
                asm volatile("vle64.v v7,  (%0)" :: "r"(Cptr[7]));
                asm volatile("vle64.v v8,  (%0)" :: "r"(Cptr[8]));
                asm volatile("vle64.v v9,  (%0)" :: "r"(Cptr[9]));
                asm volatile("vle64.v v10, (%0)" :: "r"(Cptr[10]));
                asm volatile("vle64.v v11, (%0)" :: "r"(Cptr[11]));
                asm volatile("vle64.v v12, (%0)" :: "r"(Cptr[12]));
                asm volatile("vle64.v v13, (%0)" :: "r"(Cptr[13]));
                asm volatile("vle64.v v14, (%0)" :: "r"(Cptr[14]));
                asm volatile("vle64.v v15, (%0)" :: "r"(Cptr[15]));
            } else {
                asm volatile("vmv.v.i v0,  0");
                asm volatile("vmv.v.i v1,  0");
                asm volatile("vmv.v.i v2,  0");
                asm volatile("vmv.v.i v3,  0");
                asm volatile("vmv.v.i v4,  0");
                asm volatile("vmv.v.i v5,  0");
                asm volatile("vmv.v.i v6,  0");
                asm volatile("vmv.v.i v7,  0");
                asm volatile("vmv.v.i v8,  0");
                asm volatile("vmv.v.i v9,  0");
                asm volatile("vmv.v.i v10, 0");
                asm volatile("vmv.v.i v11, 0");
                asm volatile("vmv.v.i v12, 0");
                asm volatile("vmv.v.i v13, 0");
                asm volatile("vmv.v.i v14, 0");
                asm volatile("vmv.v.i v15, 0");
            }

            double t[16];
            for (int r = 0; r < 16; ++r)
                t[r] = *Aptr[r];

            for (int k = 0; k < (int)K; ++k) {
                double *B_iter = B_col + k * ldb;
                asm volatile("vle64.v v31, (%0)" :: "r"(B_iter));

                asm volatile("vfmacc.vf v0,  %0, v31" :: "f"(t[0]));
                Aptr[0]++;  t[0]  = *Aptr[0];
                asm volatile("vfmacc.vf v1,  %0, v31" :: "f"(t[1]));
                Aptr[1]++;  t[1]  = *Aptr[1];
                asm volatile("vfmacc.vf v2,  %0, v31" :: "f"(t[2]));
                Aptr[2]++;  t[2]  = *Aptr[2];
                asm volatile("vfmacc.vf v3,  %0, v31" :: "f"(t[3]));
                Aptr[3]++;  t[3]  = *Aptr[3];
                asm volatile("vfmacc.vf v4,  %0, v31" :: "f"(t[4]));
                Aptr[4]++;  t[4]  = *Aptr[4];
                asm volatile("vfmacc.vf v5,  %0, v31" :: "f"(t[5]));
                Aptr[5]++;  t[5]  = *Aptr[5];
                asm volatile("vfmacc.vf v6,  %0, v31" :: "f"(t[6]));
                Aptr[6]++;  t[6]  = *Aptr[6];
                asm volatile("vfmacc.vf v7,  %0, v31" :: "f"(t[7]));
                Aptr[7]++;  t[7]  = *Aptr[7];
                asm volatile("vfmacc.vf v8,  %0, v31" :: "f"(t[8]));
                Aptr[8]++;  t[8]  = *Aptr[8];
                asm volatile("vfmacc.vf v9,  %0, v31" :: "f"(t[9]));
                Aptr[9]++;  t[9]  = *Aptr[9];
                asm volatile("vfmacc.vf v10, %0, v31" :: "f"(t[10]));
                Aptr[10]++; t[10] = *Aptr[10];
                asm volatile("vfmacc.vf v11, %0, v31" :: "f"(t[11]));
                Aptr[11]++; t[11] = *Aptr[11];
                asm volatile("vfmacc.vf v12, %0, v31" :: "f"(t[12]));
                Aptr[12]++; t[12] = *Aptr[12];
                asm volatile("vfmacc.vf v13, %0, v31" :: "f"(t[13]));
                Aptr[13]++; t[13] = *Aptr[13];
                asm volatile("vfmacc.vf v14, %0, v31" :: "f"(t[14]));
                Aptr[14]++; t[14] = *Aptr[14];
                asm volatile("vfmacc.vf v15, %0, v31" :: "f"(t[15]));
                Aptr[15]++; t[15] = *Aptr[15];
            }

            asm volatile("vse64.v v0,  (%0)" :: "r"(Cptr[0]));
            asm volatile("vse64.v v1,  (%0)" :: "r"(Cptr[1]));
            asm volatile("vse64.v v2,  (%0)" :: "r"(Cptr[2]));
            asm volatile("vse64.v v3,  (%0)" :: "r"(Cptr[3]));
            asm volatile("vse64.v v4,  (%0)" :: "r"(Cptr[4]));
            asm volatile("vse64.v v5,  (%0)" :: "r"(Cptr[5]));
            asm volatile("vse64.v v6,  (%0)" :: "r"(Cptr[6]));
            asm volatile("vse64.v v7,  (%0)" :: "r"(Cptr[7]));
            asm volatile("vse64.v v8,  (%0)" :: "r"(Cptr[8]));
            asm volatile("vse64.v v9,  (%0)" :: "r"(Cptr[9]));
            asm volatile("vse64.v v10, (%0)" :: "r"(Cptr[10]));
            asm volatile("vse64.v v11, (%0)" :: "r"(Cptr[11]));
            asm volatile("vse64.v v12, (%0)" :: "r"(Cptr[12]));
            asm volatile("vse64.v v13, (%0)" :: "r"(Cptr[13]));
            asm volatile("vse64.v v14, (%0)" :: "r"(Cptr[14]));
            asm volatile("vse64.v v15, (%0)" :: "r"(Cptr[15]));
        }

        if (row < (int)M) {
            gemm_fp64_vec_naive_2sregs(setup_ssr, partition_banks,
                                       transa, transb,
                                       M - row, vl, K,
                                       (double*)A_p + lda * row, lda,
                                       B_col, ldb, beta,
                                       C_col + lda * row, ldc);
        }

        col += vl;
    }

    snrt_mcycle();
}