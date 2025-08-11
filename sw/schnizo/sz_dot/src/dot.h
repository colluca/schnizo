// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"

static inline void dot_frep(uint32_t n, double *x, double *y, double *output) {
    double sum = 0;
    int inc = sizeof(double);
    double *x_addr = &x[0];
    double *y_addr = &y[0];

    asm volatile (
        // Code
        "frep.o  %[n_frep], 5, 0, 0\n"
        "fld     ft0, 0(%[xa])\n"
        "fld     ft1, 0(%[ya])\n"
        "fmadd.d %[sum], ft0, ft1, %[sum]\n"
        "addi    %[xa], %[xa],   %[inc]\n"
        "addi    %[ya], %[ya],   %[inc]\n"
        // Outputs
        : [sum]"+f"(sum), [xa]"+r"(x_addr), [ya]"+r"(y_addr)
        // Inputs
        : [n_frep]"r"(n-1), [inc]"i"(inc)
        // Clobbers
        : "t0", "ft0", "ft1", "memory"
    );

    output[0] = sum;
}

static inline void dot_frep_4unrolled(uint32_t n, double *x, double *y, double *output) {
    register volatile double sum1 asm("ft0") = 0;
    register volatile double sum2 asm("ft1") = 0;
    register volatile double sum3 asm("ft2") = 0;
    register volatile double sum4 asm("ft3") = 0;

    int inc = sizeof(double) * 4;
    double *x_addr = &x[0];
    double *y_addr = &y[0];

    asm volatile (
        // Loop
        "frep.o  %[n_frep], 14,      0,     0      \n"
        "fld     fa0,       0(%[xa])               \n"
        "fld     fa1,       0(%[ya])               \n"
        "fld     fa2,       8(%[xa])               \n"
        "fld     fa3,       8(%[ya])               \n"
        "fld     fa4,      16(%[xa])               \n"
        "fld     fa5,      16(%[ya])               \n"
        "fld     fa6,      24(%[xa])               \n"
        "fld     fa7,      24(%[ya])               \n"  // moving adds before fmadd won't reduce
        "fmadd.d %[sum1],  fa0,      fa1,    %[sum1]\n" // LCP overhead as the 1st fmadd can start
        "fmadd.d %[sum2],  fa2,      fa3,    %[sum2]\n" // immediately.
        "fmadd.d %[sum3],  fa4,      fa5,    %[sum3]\n"
        "fmadd.d %[sum4],  fa6,      fa7,    %[sum4]\n"
        "addi    %[xa],    %[xa],    %[inc]        \n"
        "addi    %[ya],    %[ya],    %[inc]        \n"
        // Reduction
        "fadd.d  %[sum1],  %[sum1],  %[sum2]       \n"
        "fadd.d  %[sum3],  %[sum3],  %[sum4]       \n"
        "fadd.d  %[sum1],  %[sum1],  %[sum3]       \n"
        // Outputs
        : [sum1]"+f"(sum1), [sum2]"+f"(sum2), [sum3]"+f"(sum3), [sum4]"+f"(sum4),
          [xa]"+r"(x_addr), [ya]"+r"(y_addr)
        // Inputs - frep loops once more than the actual value - reduce by 4 due to unrolling
        : [n_frep]"r"((n >> 2) - 1), [inc]"i"(inc)
        // Clobbers
        : "t0", "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7"
    );

    output[0] = sum1;
}

// requires 2 (or maybe 1) ALU, 2 LSU with 6 slot each and 1 FPU with 6 slots.
static inline void dot_frep_6unrolled(uint32_t n, double *x, double *y, double *output) {
    register volatile double sum1 asm("ft0") = 0;
    register volatile double sum2 asm("ft1") = 0;
    register volatile double sum3 asm("ft2") = 0;
    register volatile double sum4 asm("ft3") = 0;
    register volatile double sum5 asm("ft4") = 0;
    register volatile double sum6 asm("ft5") = 0;

    int inc = sizeof(double) * 6;
    double *x_addr = &x[0];
    double *y_addr = &y[0];

    asm volatile (
        // Loop
        "frep.o  %[n_frep], 20,      0,     0       \n"
        "fld     fa0,       0(%[xa])                \n"
        "fld     fa1,       0(%[ya])                \n"
        "fld     fa2,       8(%[xa])                \n"
        "fld     fa3,       8(%[ya])                \n"
        "fld     fa4,      16(%[xa])                \n"
        "fld     fa5,      16(%[ya])                \n"
        "fld     fa6,      24(%[xa])                \n"
        "fld     fa7,      24(%[ya])                \n"
        "fld     fs0,      32(%[xa])                \n"
        "fld     fs1,      32(%[ya])                \n"
        "fld     fs2,      40(%[xa])                \n"
        "fld     fs3,      40(%[ya])                \n"
        "fmadd.d %[sum1],  fa0,      fa1,    %[sum1]\n"
        "fmadd.d %[sum2],  fa2,      fa3,    %[sum2]\n"
        "fmadd.d %[sum3],  fa4,      fa5,    %[sum3]\n"
        "fmadd.d %[sum4],  fa6,      fa7,    %[sum4]\n"
        "fmadd.d %[sum5],  fs0,      fs1,    %[sum5]\n"
        "fmadd.d %[sum6],  fs2,      fs3,    %[sum6]\n"
        "addi    %[xa],    %[xa],    %[inc]         \n"
        "addi    %[ya],    %[ya],    %[inc]         \n"
        // Reduction
        "fadd.d  %[sum1],  %[sum1],  %[sum2]        \n"
        "fadd.d  %[sum3],  %[sum3],  %[sum4]        \n"
        "fadd.d  %[sum5],  %[sum5],  %[sum6]        \n"
        "fadd.d  %[sum1],  %[sum1],  %[sum3]        \n"
        "fadd.d  %[sum1],  %[sum1],  %[sum5]        \n"
        // Outputs
        : [sum1]"+f"(sum1), [sum2]"+f"(sum2), [sum3]"+f"(sum3), [sum4]"+f"(sum4),
          [sum5]"+f"(sum5), [sum6]"+f"(sum6),
          [xa]"+r"(x_addr), [ya]"+r"(y_addr)
        // Inputs - frep loops once more than the actual value
        : [n_frep]"r"(n/6-1), [inc]"i"(inc)
        // Clobbers
        : "t0", "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7", "fs0", "fs1", "fs2", "fs3"
    );

    output[0] = sum1;
}

static inline void dot_frep_4unrolled_address(uint32_t n, double *x, double *y, double *output) {
    register volatile double sum1 asm("ft0") = 0;
    register volatile double sum2 asm("ft1") = 0;
    register volatile double sum3 asm("ft2") = 0;
    register volatile double sum4 asm("ft3") = 0;

    int inc = sizeof(double);
    double *x_addr1 = &x[0];
    double *x_addr2 = &x[1];
    double *x_addr3 = &x[2];
    double *x_addr4 = &x[3];
    double *y_addr1 = &y[0];
    double *y_addr2 = &y[1];
    double *y_addr3 = &y[2];
    double *y_addr4 = &y[3];

    asm volatile (
        // Loop
        "frep.o  %[n_frep], 20,      0,     0      \n"
        "fld     fa0,       0(%[xa1])               \n"
        "fld     fa1,       0(%[ya1])               \n"
        "fld     fa2,       8(%[xa2])               \n"
        "fld     fa3,       8(%[ya2])               \n"
        "fld     fa4,      16(%[xa3])               \n"
        "fld     fa5,      16(%[ya3])               \n"
        "fld     fa6,      24(%[xa4])               \n"
        "fld     fa7,      24(%[ya4])               \n"
        "fmadd.d %[sum1],  fa0,       fa1,   %[sum1]\n"
        "fmadd.d %[sum2],  fa2,       fa3,   %[sum2]\n"
        "fmadd.d %[sum3],  fa4,       fa5,   %[sum3]\n"
        "fmadd.d %[sum4],  fa6,       fa7,   %[sum4]\n"
        "addi    %[xa1],   %[xa1],    %[inc]        \n"
        "addi    %[ya1],   %[ya1],    %[inc]        \n"
        "addi    %[xa2],   %[xa2],    %[inc]        \n"
        "addi    %[ya2],   %[ya2],    %[inc]        \n"
        "addi    %[xa3],   %[xa3],    %[inc]        \n"
        "addi    %[ya3],   %[ya3],    %[inc]        \n"
        "addi    %[xa4],   %[xa4],    %[inc]        \n"
        "addi    %[ya4],   %[ya4],    %[inc]        \n"
        // Reduction
        "fadd.d  %[sum1],  %[sum1],   %[sum2]       \n"
        "fadd.d  %[sum3],  %[sum3],   %[sum4]       \n"
        "fadd.d  %[sum1],  %[sum1],   %[sum3]       \n"
        // Outputs
        : [sum1]"+f"(sum1), [sum2]"+f"(sum2), [sum3]"+f"(sum3), [sum4]"+f"(sum4),
          [xa1]"+r"(x_addr1), [ya1]"+r"(y_addr1),
          [xa2]"+r"(x_addr2), [ya2]"+r"(y_addr2),
          [xa3]"+r"(x_addr3), [ya3]"+r"(y_addr3),
          [xa4]"+r"(x_addr4), [ya4]"+r"(y_addr4)
        // Inputs - frep loops once more than the actual value
        : [n_frep]"r"((n >> 2) - 1), [inc]"i"(inc)
        // Clobbers
        : "t0", "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7"
    );

    output[0] = sum1;
}

inline void dot_seq(uint32_t n, double *x, double *y, double *output) {
    // Start of SSR region.
    register volatile double ft0 asm("ft0");
    register volatile double ft1 asm("ft1");
    asm volatile("" : "=f"(ft0), "=f"(ft1));

    snrt_ssr_loop_1d(SNRT_SSR_DM0, n, sizeof(double));
    snrt_ssr_loop_1d(SNRT_SSR_DM1, n, sizeof(double));

    snrt_ssr_read(SNRT_SSR_DM0, SNRT_SSR_1D, x);
    snrt_ssr_read(SNRT_SSR_DM1, SNRT_SSR_1D, y);

    register volatile double res_ssr asm("fs0") = 0;

    snrt_ssr_enable();

    const register uint32_t Nm1 asm("t0") = n - 1;
    asm volatile(
        "frep.o %[n_frep], 1, 0, 0 \n"
        "fmadd.d %0, ft0, ft1, %0"
        : "=f"(res_ssr) /* output operands */
        : "f"(ft0), "f"(ft1), "0"(res_ssr),
          [ n_frep ] "r"(Nm1) /* input operands */
        :);

    // End of SSR region.
    snrt_fpu_fence();
    snrt_ssr_disable();
    asm volatile("" : : "f"(ft0), "f"(ft1));
    output[0] = res_ssr;
}

inline void dot_seq_4_acc(uint32_t n, double *x, double *y, double *output) {
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

static inline void dot(uint32_t n, double *x, double *y, double *result) {
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
        dot_frep_4unrolled(frac_core, local_x, local_y, &partial_sums[core_idx]);
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
    end_cycle = snrt_mcycle(); // common end tile

    // Copy data out of TCDM
    if (snrt_is_dm_core()) {
        *result = partial_sums[0];
    }

    snrt_cluster_hw_barrier();
}
