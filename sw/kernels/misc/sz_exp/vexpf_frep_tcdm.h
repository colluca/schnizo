// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

// An implementation of the GCC exp function in optimized assembly loop using the
// superscalar FREP mechanism. The data is double buffered into the TCDM.

#include "snrt.h"

#define N_BUFFERS 2

static inline void vexpf_frep_tcdm(double *a, double *b) {
    int n_batches = LEN / BATCH_SIZE;
    int n_iterations = n_batches + 2;

    double *a_buffers[N_BUFFERS];
    double *b_buffers[N_BUFFERS];

    a_buffers[0] = ALLOCATE_BUFFER(double, BATCH_SIZE);
    a_buffers[1] = ALLOCATE_BUFFER(double, BATCH_SIZE);
    b_buffers[0] = ALLOCATE_BUFFER(double, BATCH_SIZE);
    b_buffers[1] = ALLOCATE_BUFFER(double, BATCH_SIZE);

    unsigned int dma_a_idx = 0;
    unsigned int dma_b_idx = 0;
    unsigned int comp_idx = 0;
    double *dma_a_ptr;
    double *dma_b_ptr;
    double *comp_a_ptr;
    double *comp_b_ptr;

    uint64_t ki, t;

    // Enable memory access serialization in FREP loop.
    // This is required because FREP has no memory consistency and the kernel has
    // RAW memory dependencies.
    if (snrt_cluster_core_idx() == 0) {
        szrt_set_frep_mem_consistency(FREP_MEM_SERIALIZED);
    }

    // Iterate over batches
    for (int iteration = 0; iteration < n_iterations; iteration++) {
        // DMA cores
        if (snrt_is_dm_core()) {
            // DMA in phase
            if (iteration < n_iterations - 2) {
                // Index buffers
                dma_a_ptr = a_buffers[dma_a_idx];

                // DMA transfer
                snrt_dma_load_1d_tile(dma_a_ptr, a, iteration, BATCH_SIZE,
                                      sizeof(double));

                // Increment buffer index for next iteration
                dma_a_idx += 1;
                dma_a_idx %= N_BUFFERS;
            }

            // DMA out phase
            if (iteration > 1) {
                // Index buffers
                dma_b_ptr = b_buffers[dma_b_idx];

                // DMA transfer
                snrt_dma_store_1d_tile(b, dma_b_ptr, iteration - 2, BATCH_SIZE,
                                       sizeof(double));

                // Increment buffer index for next iteration
                dma_b_idx += 1;
                dma_b_idx %= N_BUFFERS;
            }
            snrt_dma_wait_all();
        }

        if (snrt_cluster_core_idx() == 0) {
            if (iteration > 0 && iteration < n_iterations - 1) {
                // Index buffers
                comp_a_ptr = a_buffers[comp_idx];
                comp_b_ptr = b_buffers[comp_idx];
                // Loop over samples
                // This loop requires:
                // ALU slots: 7
                // LSU slots: 7  (one LSU due to missing memory consistency)
                // FPU slots: 10
                asm volatile(
                    // clang-format off
                    // ft0 - input value
                    // ft1 - output value
                    "frep.o  %[n_reps], 24, 0, 0              \n" // for (int i = 0; i < LEN; i++)
                    "fld     ft0, 0(%[in_addr])               \n" // load input
                    "fmul.d  fa3, %[InvLn2N], ft0             \n" // z = InvLn2N * xd
                    "addi    %[in_addr], %[in_addr], %[inc]   \n" // update load address - after fmul.d to hide latency of fpu
                    "fadd.d  fa1, fa3, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    // Next we want to move the lower 32bits of fa1 to a0
                    // A simple solution is to store the double value in memory and then load the lower 32bits.
                    // This is a RAW memory dependency. FREP does not check for this.
                    // "fsd     fa1, 0(%[ki])                    \n" // ki = asuint64 (kd)
                    // "lw      a0, 0(%[ki])                     \n" // ki = asuint64 (kd)
                    // We can achieve the same by using FMV.X.W. This works as it only accesses the lower 32bits.
                    // In case we want the upper 32-bits there is no instruction. The RISC-V standard suggests moving
                    // to a 64bit integer core..
                    "fmv.x.w a0, fa1                          \n" // ki = asuint64 (kd)
                    "andi    a1, a0, 0x1f                     \n" // ki % N
                    "slli    a1, a1, 0x3                      \n" // T[ki % N]
                    "add     a1, %[T], a1                     \n" // T[ki % N]
                    "lw      a2, 0(a1)                        \n" // t = T[ki % N]
                    "lw      a1, 4(a1)                        \n" // t = T[ki % N]
                    "slli    a0, a0, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "sw      a2, 0(%[t])                      \n" // store lower 32b of t (unaffected)
                    "add     a0, a0, a1                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "sw      a0, 4(%[t])                      \n" // store upper 32b of t
                    "fsub.d  fa2, fa1, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  fa3, fa3, fa2                    \n" // r = z - kd
                    "fmadd.d fa2, %[C0], fa3, %[C1]           \n" // z = C[0] * r + C[1]
                    // RAW memory dependency! This fld executes before the two stores above to address %[t]!
                    // We don't have a "move to upper 32bit of fp register" instruction..
                    "fld     fa0, 0(%[t])                     \n" // s = asdouble (t)
                    "fmadd.d fa4, %[C2], fa3, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmul.d  fa1, fa3, fa3                    \n" // r2 = r * r
                    "fmadd.d fa4, fa2, fa1, fa4               \n" // y = z * r2 + y
                    "fmul.d  ft1, fa4, fa0                    \n" // y = y * s
                    "fsd     ft1, 0(%[out_addr])              \n" // store output
                    "addi    %[out_addr], %[out_addr], %[inc] \n" // update store address
                    // clang-format on
                    :
                    [ in_addr ] "+r"(comp_a_ptr), [ out_addr ] "+r"(comp_b_ptr)
                    : [ InvLn2N ] "f"(InvLn2N), [ inc ] "i"(sizeof(double)),
                      [ n_reps ] "r"(LEN - 1), [ SHIFT ] "f"(SHIFT),
                      [ C0 ] "f"(C[0]), [ C1 ] "f"(C[1]), [ C2 ] "f"(C[2]),
                      [ C3 ] "f"(C[3]), [ ki ] "r"(&ki), [ t ] "r"(&t),
                      [ T ] "r"(T)
                    : "memory", "a0", "a1", "a2", "fa0", "fa1", "fa2", "fa3",
                      "fa4", "ft0", "ft1");
            }
        }
        // Synchronize cores
        snrt_cluster_hw_barrier();
    }
}
