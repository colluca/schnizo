// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "args.h"
#include "snrt.h"

#define DOUBLE_BUFFER 0

#define BANK_ALIGNMENT 8
#define TCDM_ALIGNMENT (32 * BANK_ALIGNMENT)
#define ALIGN_UP(addr, size) (((addr) + (size)-1) & ~((size)-1))
#define ALIGN_UP_TCDM(addr) ALIGN_UP(addr, TCDM_ALIGNMENT)


#define ADDI_COMPILE_DYN(a0, a1, inc) "addi"

// configurable array stride
static inline void axpy_frep_increment(uint32_t n, double a, double *x, double *y,
                             double *z, int increment) {
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac = n / num_cores;
    int offset = core_idx;

    // Loop but in assembly
    // for (int i = offset; i < n; i += snrt_cluster_compute_core_num()) {
    //     z[i] = a * x[i] + y[i];
    // }
    double *x_addr = &x[offset];
    double *y_addr = &y[offset];
    double *z_addr = &z[offset];

    snrt_mcycle();
    asm volatile (
        // Code
        "frep.o  %[n_frep], 7, 0, 0\n"
        "fld     ft0,   0(%[xa])          \n"
        "fld     ft1,   0(%[ya])          \n"
        "add     %[xa], %[xa],   %[inc]   \n" // move adds before fmadd to hide it beneath the fld
        "add     %[ya], %[ya],   %[inc]   \n" // latency. This reduces the LCP overhead.
        "fmadd.d ft0,   %[a],    ft0,   ft1\n"
        "fsd     ft0,   0(%[za])          \n"
        "add     %[za], %[za],   %[inc]   \n"
        // Outputs
        : [xa]"+r"(x_addr), [ya]"+r"(y_addr), [za]"+r"(z_addr)
        // Inputs
        : [n_frep]"r"(frac-1), [a]"f"(a), [inc]"r"(increment * num_cores)
        // Clobbers
        : "t0", "ft0", "ft1", "memory"
    );
    snrt_mcycle();
}

// The matrixes are placed contiguously in memory.
static inline void axpy_frep(uint32_t n, double a, double *x, double *y,
                             double *z) {
    axpy_frep_increment(n, a, x, y, z, sizeof(double));
}

static inline void axpy_vec_naive(uint32_t n, double a, double *x, double *y,
                double *z) {
    
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    unsigned int vl;
    unsigned int avl = n / num_cores;
    int offset = core_idx * avl;
    int start, end;


    double *x_addr = &x[offset];
    double *y_addr = &y[offset];
    double *z_addr = &z[offset];

    snrt_mcycle();

    // Stripmine and accumulate a partial vector
    do {
    // Set the vl
        asm volatile("vsetvli %0, %1, e64, m1, ta, ma" : "=r"(vl) : "r"(avl));

        // Load vectors
        asm volatile("vle64.v v0, (%0)" ::"r"(x_addr));
        asm volatile("vle64.v v8, (%0)" ::"r"(y_addr));

        // Multiply-accumulate
        asm volatile("vfmacc.vf v8, %0, v0" ::"f"(a));

        // Store results
        asm volatile("vse64.v v8, (%0)" ::"r"(z_addr));

        // Bump pointers
        x_addr += vl;
        y_addr += vl;
        z_addr += vl;
        avl -= vl;

    } while (avl > 0);

    asm volatile("fence");
    snrt_mcycle();
}



// The matrixes are placed contiguously in memory.
static inline void axpy_vec_frep(uint32_t n, double a, double *x, double *y,
                             double *z) {
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac = n / num_cores;
    int offset = core_idx * frac;
    int start, end;


    double *x_addr = &x[offset];
    double *y_addr = &y[offset];
    double *z_addr = &z[offset];


    unsigned int max_vl;
    asm volatile("vsetvli  %[rvl],  %[rdvl], e64, m2, ta, ma       \n"
                  : [rvl]"+r"(max_vl)
                  : [rdvl]"r"(-1)
    );

    int increment = sizeof(double)*max_vl;

    unsigned int n_vec_whole_iter = frac / max_vl;
    unsigned int n_remaining_elems = frac % max_vl;

    snrt_mcycle();

    if (n_vec_whole_iter) {
        asm volatile (
        // Code
        "frep.o  %[n_frep], 7, 0, 0\n"
        "vle64.v  v0,    (%[xa])          \n"
        "vle64.v  v8,    (%[ya])          \n"
        "add     %[xa], %[xa],   %[inc]   \n" // move adds before fmadd to hide it beneath the fld
        "add     %[ya], %[ya],   %[inc]   \n" // latency. This reduces the LCP overhead.
        "vfmacc.vf v8,    %[a],    v0     \n"
        "vse64.v  v8,    (%[za])          \n"
        "add     %[za], %[za],   %[inc]   \n"
        // Outputs
        : [xa]"+r"(x_addr), [ya]"+r"(y_addr), [za]"+r"(z_addr)
        // Inputs
        : [n_frep]"r"(n_vec_whole_iter - 1), [a]"f"(a), [inc]"r"(increment)
        // Clobbers
        : "memory"
        );
    } 

    if (n_remaining_elems) {

        asm volatile("vsetvli  %[rvl],  %[rdvl], e64, m2, ta, ma       \n"
                    : [rvl]"+r"(max_vl)
                    : [rdvl]"r"(n_remaining_elems)
        );

        asm volatile (
        // Code
        "vle64.v  v0,    (%[xa])          \n"
        "vle64.v  v8,    (%[ya])          \n"
        "vfmacc.vf v8,    %[a],    v0     \n"
        "vse64.v  v8,    (%[za])          \n"
        // Outputs
        : [xa]"+r"(x_addr), [ya]"+r"(y_addr), [za]"+r"(z_addr)
        // Inputs
        : [a]"f"(a)
        // Clobbers
        : "memory"
        );

        
    }
    
    asm volatile("fence");

    snrt_mcycle();
}


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

static inline void axpy_naive_unrolled(uint32_t n, double a, double *x, double *y,
    double *z) {
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac = n / num_cores;
    int offset = core_idx;

    snrt_mcycle();
    for (int i = offset; i < n; i += 4 * num_cores) {
        // The unrolling must be explicit as otherwise the compiler cannot resolve the "fake"
        // address dependencies.
        // This wont work:
        // z[i] = a * x[i] + y[i];
        // z[i + 1*num_cores] = a * x[i + 1*num_cores] + y[i + 1*num_cores];

        double x0, x1, x2, x3;
        double y0, y1, y2, y3;
        double z0, z1, z2, z3;
        x0 = x[i];
        y0 = y[i];
        x1 = x[i + num_cores];
        y1 = y[i + num_cores];
        x2 = x[i + 2 * num_cores];
        y2 = y[i + 2 * num_cores];
        x3 = x[i + 3 * num_cores];
        y3 = y[i + 3 * num_cores];

        z0 = a * x0 + y0;
        z1 = a * x1 + y1;
        z2 = a * x2 + y2;
        z3 = a * x3 + y3;
        z[i] = z0;
        z[i + num_cores] = z1;
        z[i + 2 * num_cores] = z2;
        z[i + 3 * num_cores] = z3;
    }
    snrt_fpu_fence();
    snrt_mcycle();
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

    // Allocate space for job operands in TCDM
    // Align X with the 1st bank in TCDM, Y with the 8th and Z with the 16th.
    local_x0_addr = ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t));
    local_y0_addr = ALIGN_UP_TCDM(local_x0_addr + size) + 8 * BANK_ALIGNMENT;
    local_z0_addr = ALIGN_UP_TCDM(local_y0_addr + size) + 16 * BANK_ALIGNMENT;
    local_x[0] = (double *)local_x0_addr;
    local_y[0] = (double *)local_y0_addr;
    local_z[0] = (double *)local_z0_addr;
    if (DOUBLE_BUFFER) {
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
    if (DOUBLE_BUFFER) iterations += 2;

    // Iterate over all tiles
    for (i = 0; i < iterations; i++) {
        if (snrt_is_dm_core()) {
            // DMA in
            if (!DOUBLE_BUFFER || (i < args->n_tiles)) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_dma_in = i;
                buff_idx = DOUBLE_BUFFER ? i_dma_in % 2 : 0;

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
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();

            // DMA out
            if (!DOUBLE_BUFFER || (i > 1)) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_dma_out = DOUBLE_BUFFER ? i - 2 : i;
                buff_idx = DOUBLE_BUFFER ? i_dma_out % 2 : 0;

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
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();

            if (!DOUBLE_BUFFER || (i > 0 && i < (args->n_tiles + 1))) {
                // moved mcycle call directly to loop

                // Compute tile and buffer indices
                i_compute = DOUBLE_BUFFER ? i - 1 : i;
                buff_idx = DOUBLE_BUFFER ? i_compute % 2 : 0;

                // Perform tile computation
                axpy_fp_t fp = args->funcptr;
                fp(frac, args->a, local_x[buff_idx], local_y[buff_idx],
                   local_z[buff_idx]);

                // moved mcycle call directly to loop
            }

            // Additional barrier required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
        }

        // Synchronize cores after every iteration
        snrt_cluster_hw_barrier();
    }
    snrt_mcycle();
}


// instead of consecutive bank access, we align the arrays such that each array
// is on a separate bank. This requires 48 banks for double buffering but we only
// have 32 -> double buffering is disabled.
static inline void axpy_job_distributed(axpy_args_t *args) {
    snrt_mcycle();
    uint32_t frac, offset, size;
    uint64_t local_x0_addr, local_y0_addr, local_z0_addr, local_x1_addr,
        local_y1_addr, local_z1_addr;
    double *local_x[2];
    double *local_y[2];
    double *local_z[2];
    double *remote_x, *remote_y, *remote_z;
    uint32_t iterations, i, i_dma_in, i_compute, i_dma_out, buff_idx;


    int double_buffer = 0; // double buffering is only possible with 48 banks

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
    size = frac;

    // Allocate space for job operands in TCDM
    // Place X only in the bank 0:ncores-1
    // Place Y only in the bank ncores:2*ncores-1
    // Place Z only in the bank 2*num_cores:3*num_cores-1
    int num_cores = snrt_cluster_compute_core_num();
    local_x0_addr = ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t));
    local_y0_addr = local_x0_addr + num_cores * BANK_ALIGNMENT;
    local_z0_addr = local_x0_addr + 2*num_cores * BANK_ALIGNMENT;
    local_x[0] = (double *)local_x0_addr;
    local_y[0] = (double *)local_y0_addr;
    local_z[0] = (double *)local_z0_addr;

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
                snrt_dma_start_2d(local_x[buff_idx], remote_x, num_cores * sizeof(double),
                                  TCDM_ALIGNMENT, num_cores * sizeof(double), size / num_cores);
                snrt_dma_start_2d(local_y[buff_idx], remote_y, num_cores * sizeof(double),
                                  TCDM_ALIGNMENT, num_cores * sizeof(double), size / num_cores);
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
                snrt_dma_start_2d(remote_z, local_z[buff_idx], num_cores * sizeof(double),
                                  num_cores * sizeof(double), TCDM_ALIGNMENT, size / num_cores);
                snrt_dma_wait_all();

                snrt_mcycle();
            }
        }

        // Compute
        if (snrt_is_compute_core()) {
            // Additional barrier required when not double buffering
            if (!double_buffer) snrt_cluster_hw_barrier();

            if (!double_buffer || (i > 0 && i < (args->n_tiles + 1))) {
                snrt_mcycle();

                // Compute tile and buffer indices
                i_compute = double_buffer ? i - 1 : i;
                buff_idx = double_buffer ? i_compute % 2 : 0;

                // Perform tile computation
                axpy_fp_t fp = args->funcptr;
                axpy_frep_increment(frac, args->a, local_x[buff_idx], local_y[buff_idx],
                                    local_z[buff_idx], TCDM_ALIGNMENT);

                snrt_mcycle();
            }

            // Additional barrier required when not double buffering
            if (!double_buffer) snrt_cluster_hw_barrier();
        }

        // Synchronize cores after every iteration
        snrt_cluster_hw_barrier();
    }
    snrt_mcycle();
}