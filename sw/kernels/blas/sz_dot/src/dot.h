// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "args.h"
#include "snrt.h"

#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif

inline void dot_naive(uint32_t n, double *x, double *y, double *output) {
    double sum = 0;
    for (int i = 0; i < n; i++) {
        sum += x[i] * y[i];
    }
    *output = sum;
}

inline void dot_baseline(uint32_t n, double *x, double *y, double *output) {
    double res0 = 0, res1 = 0, res2 = 0, res3 = 0;

    int i = 0;

    for (; i + 3 < n; i += 4) {
        res0 += x[i + 0] * y[i + 0];
        res1 += x[i + 1] * y[i + 1];
        res2 += x[i + 2] * y[i + 2];
        res3 += x[i + 3] * y[i + 3];
    }

    // Reduce the 4 streams
    res0 += res1;
    res2 += res3;
    res0 += res2;

    snrt_fpu_fence();

    *output = res0;
}

inline void dot_opt(uint32_t n, double *x, double *y, double *output) {
    // Start of SSR region.
    register volatile double ft0 asm("ft0");
    register volatile double ft1 asm("ft1");
    asm volatile("" : "=f"(ft0), "=f"(ft1));

    snrt_ssr_loop_1d(SNRT_SSR_DM0, n, sizeof(double));
    snrt_ssr_loop_1d(SNRT_SSR_DM1, n, sizeof(double));

    snrt_ssr_read(SNRT_SSR_DM0, SNRT_SSR_1D, x);
    snrt_ssr_read(SNRT_SSR_DM1, SNRT_SSR_1D, y);

    register volatile double res_ssr_0 asm("fs0") = 0;
    register volatile double res_ssr_1 asm("fs1") = 0;
    register volatile double res_ssr_2 asm("fs2") = 0;
    register volatile double res_ssr_3 asm("fs3") = 0;

    snrt_ssr_enable();

    const register uint32_t Nm1 asm("t0") = (n >> 2) - 1;
    asm volatile(
        "frep.o %[n_frep], 4, 0, 0 \n"
        "fmadd.d %0, ft0, ft1, %0 \n"
        "fmadd.d %1, ft0, ft1, %1 \n"
        "fmadd.d %2, ft0, ft1, %2 \n"
        "fmadd.d %3, ft0, ft1, %3"
        : "=f"(res_ssr_0), "=f"(res_ssr_1), "=f"(res_ssr_2),
          "=f"(res_ssr_3) /* output operands */
        : "f"(ft0), "f"(ft1), "0"(res_ssr_0), "1"(res_ssr_1), "2"(res_ssr_2),
          "3"(res_ssr_3), [ n_frep ] "r"(Nm1) /* input operands */
        :);

    // End of SSR region.
    snrt_fpu_fence();
    snrt_ssr_disable();

    asm volatile(
        "fadd.d %[res_ssr_0], %[res_ssr_0], %[res_ssr_1] \n"
        "fadd.d %[res_ssr_2], %[res_ssr_2], %[res_ssr_3] \n"
        "fadd.d %[res_ssr_0], %[res_ssr_0], %[res_ssr_2]"
        : [ res_ssr_0 ] "=f"(res_ssr_0),
          [ res_ssr_2 ] "=f"(res_ssr_2) /* output operands */
        : [ res_ssr_1 ] "f"(res_ssr_1),
          [ res_ssr_3 ] "f"(res_ssr_3) /* input operands */
        :);

    asm volatile("" : : "f"(ft0), "f"(ft1));
    output[0] = res_ssr_0;
}

static inline void dot_schnizo(uint32_t n, double *x, double *y,
                               double *output) {
    double sum1 = 0;
    double sum2 = 0;
    double sum3 = 0;
    double sum4 = 0;

    int unroll = 4;

    int inc = sizeof(double) * unroll;
    int n_iter_m1 = (n / unroll) - 1;
    double *x_addr = &x[0];
    double *y_addr = &y[0];

    asm volatile(
        // clang-format off
        FREP   " %[n_frep], 14, 0, 0         \n"
        "fld     fa0,  0(%[xa])              \n"
        "fld     fa1,  0(%[ya])              \n"
        "fld     fa2,  8(%[xa])              \n"
        "fld     fa3,  8(%[ya])              \n"
        "fld     fa4, 16(%[xa])              \n"
        "fld     fa5, 16(%[ya])              \n"
        "fld     fa6, 24(%[xa])              \n"
        "fld     fa7, 24(%[ya])              \n"  // moving adds before fmadd won't reduce
        "fmadd.d %[sum1], fa0, fa1, %[sum1]  \n"  // LCP overhead as the 1st fmadd can start
        "fmadd.d %[sum2], fa2, fa3, %[sum2]  \n"  // immediately.
        "fmadd.d %[sum3], fa4, fa5, %[sum3]  \n"
        "fmadd.d %[sum4], fa6, fa7, %[sum4]  \n"
        "addi    %[xa], %[xa], %[inc]        \n"
        "addi    %[ya], %[ya], %[inc]        \n"
        // clang-format on
        : [ sum1 ] "+f"(sum1), [ sum2 ] "+f"(sum2), [ sum3 ] "+f"(sum3),
          [ sum4 ] "+f"(sum4), [ xa ] "+r"(x_addr), [ ya ] "+r"(y_addr)
        : [ n_frep ] "r"(n_iter_m1), [ inc ] "i"(inc)
        : "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7");

    // Reduce the 4 streams
    sum1 += sum2;
    sum3 += sum4;
    sum1 += sum3;

    *output = sum1;
}

static inline void dot(uint32_t n, double *x, double *y, double *result,
                       dot_fp_t funcptr) {
    double *local_x, *local_y, *partial_sums;

    uint32_t start_cycle, end_cycle;

    // Allocate space in TCDM
    local_x = (double *)snrt_l1_next();
    local_y = local_x + n;
    partial_sums = local_y + n;

    // Copy data in TCDM
    if (snrt_is_dm_core()) {
        size_t size = n * sizeof(double);
        snrt_dma_start_1d(local_x, x, size);
        snrt_dma_start_1d(local_y, y, size);
        snrt_dma_wait_all();
    }

    // Calculate size and pointers for each core
    int core_idx = snrt_cluster_core_idx();
    int frac_core = n / snrt_cluster_compute_core_num();
    int offset_core = core_idx * frac_core;
    local_x += offset_core;
    local_y += offset_core;

    snrt_cluster_hw_barrier();

    start_cycle = snrt_mcycle();

    // Compute partial sums
    if (snrt_is_compute_core()) {
        funcptr(frac_core, local_x, local_y, &partial_sums[core_idx]);
    }

    snrt_cluster_hw_barrier();
    snrt_mcycle();

    // Reduce partial sums on core 0
#ifndef _DOTP_EXCLUDE_FINAL_SYNC_
    if (snrt_cluster_core_idx() == 0) {
        for (uint32_t i = 1; i < snrt_cluster_compute_core_num(); i++) {
            partial_sums[0] += partial_sums[i];
        }
        snrt_fpu_fence();
    }
#endif

    snrt_cluster_hw_barrier();
    end_cycle = snrt_mcycle();  // common end tile

    // Copy data out of TCDM
    if (snrt_is_dm_core()) {
        *result = partial_sums[0];
    }

    snrt_cluster_hw_barrier();
}
