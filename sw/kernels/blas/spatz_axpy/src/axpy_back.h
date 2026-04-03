// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "args.h"
#include "snrt.h"

#define BANK_ALIGNMENT 8
#define TCDM_ALIGNMENT (32 * BANK_ALIGNMENT)
#define ALIGN_UP(addr, size) (((addr) + (size)-1) & ~((size)-1))
#define ALIGN_UP_TCDM(addr) ALIGN_UP(addr, TCDM_ALIGNMENT)

static inline void axpy_naive(uint32_t n, double a, double *x, double *y,
                              double *z) {
    int core_idx = snrt_cluster_core_idx();
    int frac = n / snrt_cluster_compute_core_num();
    int offset = core_idx;

    for (int i = offset; i < n; i += snrt_cluster_compute_core_num()) {
        z[i] = a * x[i] + y[i];
    }
    snrt_fpu_fence();
}

static inline void axpy_fma(uint32_t n, double a, double *x, double *y,
                            double *z) {
    int core_idx = snrt_cluster_core_idx();
    int frac = n / snrt_cluster_compute_core_num();
    int offset = core_idx;

    for (int i = offset; i < n; i += snrt_cluster_compute_core_num()) {
        asm volatile("fmadd.d %[z], %[a], %[x], %[y] \n"
                     : [ z ] "=f"(z[i])
                     : [ a ] "f"(a), [ x ] "f"(x[i]), [ y ] "f"(y[i]));
    }
    snrt_fpu_fence();
}

static inline void axpy_opt(uint32_t n, double a, double *x, double *y,
                            double *z) {
    int core_idx = snrt_cluster_core_idx();
    int frac = n / snrt_cluster_compute_core_num();
    int offset = core_idx;

    snrt_ssr_loop_1d(SNRT_SSR_DM_ALL, frac,
                     snrt_cluster_compute_core_num() * sizeof(double));

    snrt_ssr_read(SNRT_SSR_DM0, SNRT_SSR_1D, x + offset);
    snrt_ssr_read(SNRT_SSR_DM1, SNRT_SSR_1D, y + offset);
    snrt_ssr_write(SNRT_SSR_DM2, SNRT_SSR_1D, z + offset);

    snrt_ssr_enable();

    asm volatile(
        "frep.o %[n_frep], 1, 0, 0 \n"
        "fmadd.d ft2, %[a], ft0, ft1\n"
        :
        : [ n_frep ] "r"(frac - 1), [ a ] "f"(a)
        : "ft0", "ft1", "ft2", "memory");

    snrt_fpu_fence();
    snrt_ssr_disable();
}

static inline void axpy_baseline(uint32_t n, double a, double *x, double *y,
                                 double *z) {
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac = n / num_cores;
    int offset = core_idx;

    snrt_mcycle();

    double *x_base = &x[offset];
    double *y_base = &y[offset];
    double *z_base = &z[offset];
    uint32_t stride = num_cores * sizeof(double);
    uint32_t stride_4x = 4 * stride;
    uint32_t loop_count = (frac / 4) - 1;

    asm volatile(
        "frep.i %[loop_count], 19, 0, 0 \n"
        // Load x0, y0
        "fld     ft0, 0(%[x_base])         \n"
        "fld     ft1, 0(%[y_base])         \n"
        // Load x1, y1
        "fld     ft2, %[stride](%[x_base])  \n"
        "fld     ft3, %[stride](%[y_base])  \n"
        // Load x2, y2
        "fld     ft4, %[stride_2x](%[x_base])      \n"
        "fld     ft5, %[stride_2x](%[y_base])      \n"
        // Load x3, y3
        "fld     ft6, %[stride_3x](%[x_base])      \n"
        "fld     ft7, %[stride_3x](%[y_base])      \n"
        // Compute z0 = a*x0 + y0, z1 = a*x1 + y1
        "fmadd.d fs0, %[a], ft0, ft1       \n"
        "fmadd.d fs1, %[a], ft2, ft3       \n"
        // Compute z2 = a*x2 + y2, z3 = a*x3 + y3
        "fmadd.d fs2, %[a], ft4, ft5       \n"
        "fmadd.d fs3, %[a], ft6, ft7       \n"
        // Store z0, z1, z2, z3
        "fsd     fs0, 0(%[z_base])         \n"
        "fsd     fs1, %[stride](%[z_base])  \n"
        "fsd     fs2, %[stride_2x](%[z_base])      \n"
        "fsd     fs3, %[stride_3x](%[z_base])      \n"
        // Increment pointers
        "add     %[x_base], %[x_base], %[stride_4x] \n"
        "add     %[y_base], %[y_base], %[stride_4x] \n"
        "add     %[z_base], %[z_base], %[stride_4x] \n"
        : [ x_base ] "+r"(x_base), [ y_base ] "+r"(y_base),
          [ z_base ] "+r"(z_base)
        : [ a ] "f"(a), [ loop_count ] "r"(loop_count),
          [ stride_4x ] "r"(stride_4x), [ stride ] "i"(stride),
          [ stride_2x ] "i"(2 * stride), [ stride_3x ] "i"(3 * stride)
        : "ft0", "ft1", "ft2", "ft3", "ft4", "ft5", "ft6", "ft7", "fs0", "fs1",
          "fs2", "fs3", "memory");

    snrt_fpu_fence();
    snrt_mcycle();
}

static inline void axpy_schnizo(uint32_t n, double a, double *x, double *y,
                                double *z) {
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac = n / num_cores;
    int offset = core_idx;

    double *x_addr = &x[offset];
    double *y_addr = &y[offset];
    double *z_addr = &z[offset];

    snrt_mcycle();

    asm volatile(
        "frep.o  %[n_frep], 7, 0, 0   \n"
        "fld     ft0, 0(%[xa])        \n"
        "fld     ft1, 0(%[ya])        \n"
        "add     %[xa], %[xa], %[inc] \n"  // move adds before fmadd to hide it beneath the fld
        "add     %[ya], %[ya], %[inc] \n"  // latency. This reduces the LCP overhead.
        "fmadd.d ft0, %[a], ft0, ft1  \n"
        "fsd     ft0, 0(%[za])        \n"
        "add     %[za], %[za], %[inc] \n"
        : [ xa ] "+r"(x_addr), [ ya ] "+r"(y_addr), [ za ] "+r"(z_addr)
        : [ n_frep ] "r"(frac - 1), [ a ] "f"(a),
          [ inc ] "r"(sizeof(double) * num_cores)
        : "t0", "ft0", "ft1", "memory");
    snrt_mcycle();
}

static inline void axpy_job(axpy_args_t *args) {
    snrt_mcycle();
    uint32_t frac, offset, size;
    uint64_t local_x0_addr, local_y0_addr, local_z0_addr, local_x1_addr,
        local_y1_addr, local_z1_addr;
    double *local_x[2];
    double *local_y[2];
    double *local_z[2];
    double *remote_x, *remote_y, *remote_z;
    uint32_t iterations, i, i_dma_in, i_compute, i_dma_out, buff_idx;

#ifndef JOB_ARGS_PRELOADED
    // Allocate space for job arguments in TCDM
    axpy_args_t *local_args = (axpy_args_t *)snrt_l1_next();

    // Copy job arguments to TCDM
    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_args, args, sizeof(axpy_args_t));
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();
    args = local_args;
#endif

    // Calculate size of each tile
    frac = args->n / args->n_tiles;
    size = frac * sizeof(double);

    // Aliases
    uint32_t double_buffer = args->double_buffer;

    // Allocate space for job operands in TCDM
    // Align X with the 1st bank in TCDM, Y with the 8th and Z with the 16th.
    local_x0_addr = ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t));
    local_y0_addr = ALIGN_UP_TCDM(local_x0_addr + size) + 8 * BANK_ALIGNMENT;
    local_z0_addr = ALIGN_UP_TCDM(local_y0_addr + size) + 16 * BANK_ALIGNMENT;
    local_x[0] = (double *)local_x0_addr;
    local_y[0] = (double *)local_y0_addr;
    local_z[0] = (double *)local_z0_addr;
    if (double_buffer) {
        local_x1_addr = ALIGN_UP_TCDM(local_z0_addr + size);
        local_y1_addr =
            ALIGN_UP_TCDM(local_x1_addr + size) + 8 * BANK_ALIGNMENT;
        local_z1_addr =
            ALIGN_UP_TCDM(local_y1_addr + size) + 16 * BANK_ALIGNMENT;
        local_x[1] = (double *)local_x1_addr;
        local_y[1] = (double *)local_y1_addr;
        local_z[1] = (double *)local_z1_addr;
    }

    // Calculate number of iterations
    iterations = args->n_tiles;
    if (double_buffer) iterations += 2;

    // Iterate over all tiles
    for (i = 0; i < iterations; i++) {
        if (snrt_is_dm_core()) {
            // DMA in
            if (!double_buffer || (i < args->n_tiles)) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_dma_in = i;
                buff_idx = double_buffer ? i_dma_in % 2 : 0;

                // Calculate size and pointers to current tile
                offset = i_dma_in * frac;
                remote_x = args->x + offset;
                remote_y = args->y + offset;

                // Copy job operands in TCDM
                snrt_dma_start_1d(local_x[buff_idx], remote_x, size);
                snrt_dma_start_1d(local_y[buff_idx], remote_y, size);
                snrt_dma_wait_all();

                snrt_mcycle();
            }

            // Additional barriers required when not double buffering
            if (!double_buffer) snrt_cluster_hw_barrier();
            if (!double_buffer) snrt_cluster_hw_barrier();

            // DMA out
            if (!double_buffer || (i > 1)) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_dma_out = double_buffer ? i - 2 : i;
                buff_idx = double_buffer ? i_dma_out % 2 : 0;

                // Calculate pointers to current tile
                offset = i_dma_out * frac;
                remote_z = args->z + offset;

                // Copy job outputs from TCDM
                snrt_dma_start_1d(remote_z, local_z[buff_idx], size);
                snrt_dma_wait_all();

                snrt_mcycle();
            }
        }

        // Compute
        if (snrt_is_compute_core()) {
            // Additional barrier required when not double buffering
            if (!double_buffer) snrt_cluster_hw_barrier();

            if (!double_buffer || (i > 0 && i < (args->n_tiles + 1))) {
                // Compute tile and buffer indices
                i_compute = double_buffer ? i - 1 : i;
                buff_idx = double_buffer ? i_compute % 2 : 0;

                // Perform tile computation
                axpy_fp_t fp = args->funcptr;
                fp(frac, args->a, local_x[buff_idx], local_y[buff_idx],
                   local_z[buff_idx]);
            }

            // Additional barrier required when not double buffering
            if (!double_buffer) snrt_cluster_hw_barrier();
        }

        // Synchronize cores after every iteration
        snrt_cluster_hw_barrier();
    }
    snrt_mcycle();
}
