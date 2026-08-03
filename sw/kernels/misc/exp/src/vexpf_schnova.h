// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Luca Colagrande <colluca@iis.ee.ethz.ch>

#define N_BUFFERS 2

#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif

static inline void vexpf_schnova(double *a, double *b, uint32_t len,
                                 uint32_t batch_size) {
    int n_batches = len / batch_size;
    int n_iterations = n_batches + 2;
    int n_frep_m2 = batch_size / 4 - 2;

    double *a_buffers[N_BUFFERS];
    double *b_buffers[N_BUFFERS];

    a_buffers[0] = ALLOCATE_BUFFER(double, batch_size);
    b_buffers[0] = ALLOCATE_BUFFER(double, batch_size);

    // Only allocate double buffers if there is more than one batch.
    // Allows to allocate larger tiles in this corner case.
    if (n_batches > 1) {
        a_buffers[1] = ALLOCATE_BUFFER(double, batch_size);
        b_buffers[1] = ALLOCATE_BUFFER(double, batch_size);
    }

    unsigned int dma_a_idx = 0;
    unsigned int dma_b_idx = 0;
    unsigned int comp_idx = 0;
    double *dma_a_ptr;
    double *dma_b_ptr;
    double *comp_a_ptr;
    double *comp_b_ptr;

    uint64_t t[4];

    // Map all load/stores to a single LSU, to ensure memory consistency
    szrt_set_frep_mem_consistency(FREP_MEM_SERIALIZED);

    // Iterate over batches
    for (int iteration = 0; iteration < n_iterations; iteration++) {
        snrt_mcycle();

        // DMA cores
        if (snrt_is_dm_core()) {
            // DMA in phase
            if (iteration < n_iterations - 2) {
                // Index buffers
                dma_a_ptr = a_buffers[dma_a_idx];

                // DMA transfer
                snrt_dma_load_1d_tile(dma_a_ptr, a, iteration, batch_size,
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
                snrt_dma_store_1d_tile(b, dma_b_ptr, iteration - 2, batch_size,
                                       sizeof(double));

                // Increment buffer index for next iteration
                dma_b_idx += 1;
                dma_b_idx %= N_BUFFERS;
            }
            snrt_dma_wait_all();
        }

        if (snrt_cluster_core_idx() == 0) {
            // Compute phase
            if (iteration > 0 && iteration < n_iterations - 1) {
                // Index buffers
                comp_a_ptr = a_buffers[comp_idx];
                comp_b_ptr = b_buffers[comp_idx];

                // Naive unrolling does not work well for schnova, for example if you pack all floating point instructions
                // after each other then schnova can only dispatch one per cycle if it has 1 FPU. Because it has to
                // dispatch these instructions in order. For performance
                // it is better to group different types of instructions (ALU, LSU and FPU) together in order to
                // maximize the amount of instructions that can be dispatched per cycle
                // Note: This optimized for a config with 3 ALUs, 3 LSUs (only one active), 1 FPU
                asm volatile(
                    // clang-format off
                    // We pull an additional iteration outside the loop
                    // so that we can better overlap instructions within
                    // the loop.
                    "fld     fa3, 0(%[in_addr])               \n"
                    "fld     ft3, 8(%[in_addr])               \n"
                    "fld     ft4, 16(%[in_addr])              \n"
                    "fld     ft5, 24(%[in_addr])              \n"
                    FREP   " %[n_frep], 90, 0, 0              \n"
#ifdef BALANCE_INSTRUCTION_MIX
                    "fmul.d  fa3, %[InvLn2N], fa3                     \n" // [FPU] z0 = InvLn2N * xd
                    "addi    %[in_addr], %[in_addr], %[inc]           \n" // [ALU] update input ptr early
                    "fmul.d  ft3, %[InvLn2N], ft3                     \n" // [FPU] z1
                    "fmul.d  ft4, %[InvLn2N], ft4                     \n" // [FPU] z2
                    "fmul.d  ft5, %[InvLn2N], ft5                     \n" // [FPU] z3
                    "fadd.d  fa1, fa3, %[SHIFT]                       \n" // [FPU] kd0 = z0 + SHIFT
                    "fadd.d  fa5, ft3, %[SHIFT]                       \n" // [FPU] kd1
                    "fadd.d  fa6, ft4, %[SHIFT]                       \n" // [FPU] kd2
                    "fadd.d  fa7, ft5, %[SHIFT]                       \n" // [FPU] kd3
                    "fmv.x.w a0, fa1                                  \n" // [FPU/ALU] ki0
                    "fmv.x.w a3, fa5                                  \n" // [FPU/ALU] ki1
                    "fmv.x.w a4, fa6                                  \n" // [FPU/ALU] ki2
                    "fmv.x.w a5, fa7                                  \n" // [FPU/ALU] ki3
                    "fsub.d  fa2, fa1, %[SHIFT]                       \n" // [FPU] kd_unb0
                    "andi    a1, a0, 0x1f                             \n" // [ALU] ki0 % N
                    "andi    a6, a3, 0x1f                             \n" // [ALU] ki1 % N
                    "andi    a7, a4, 0x1f                             \n" // [ALU] ki2 % N
                    "fsub.d  ft6, fa5, %[SHIFT]                       \n" // [FPU] kd_unb1
                    "andi    t0, a5, 0x1f                             \n" // [ALU] ki3 % N
                    "slli    a1, a1, 0x3                              \n" // [ALU] offset0
                    "slli    a6, a6, 0x3                              \n" // [ALU] offset1
                    "fsub.d  ft7, fa6, %[SHIFT]                       \n" // [FPU] kd_unb2
                    "slli    a7, a7, 0x3                              \n" // [ALU] offset2
                    "slli    t0, t0, 0x3                              \n" // [ALU] offset3
                    "add     a1, %[T], a1                             \n" // [ALU] addr0
                    "fsub.d  ft8, fa7, %[SHIFT]                       \n" // [FPU] kd_unb3
                    "add     a6, %[T], a6                             \n" // [ALU] addr1
                    "add     a7, %[T], a7                             \n" // [ALU] addr2
                    "add     t0, %[T], t0                             \n" // [ALU] addr3
                    "fsub.d  fa3, fa3, fa2                            \n" // [FPU] r0 = z0 - kd0
                    "lw      a2, 0(a1)                                \n" // [LSU] t_low0
                    "slli    a0, a0, 0xf                              \n" // [ALU] ki0 << 15
                    "fsub.d  ft3, ft3, ft6                            \n" // [FPU] r1
                    "lw      t1, 0(a6)                                \n" // [LSU] t_low1
                    "slli    a3, a3, 0xf                              \n" // [ALU] ki1 << 15
                    "fsub.d  ft4, ft4, ft7                            \n" // [FPU] r2
                    "lw      t2, 0(a7)                                \n" // [LSU] t_low2
                    "slli    a4, a4, 0xf                              \n" // [ALU] ki2 << 15
                    "fsub.d  ft5, ft5, ft8                            \n" // [FPU] r3
                    "lw      t3, 0(t0)                                \n" // [LSU] t_low3
                    "slli    a5, a5, 0xf                              \n" // [ALU] ki3 << 15
                    "fmadd.d fa2, %[C0], fa3, %[C1]                   \n" // [FPU] z0_poly
                    "lw      a1, 4(a1)                                \n" // [LSU] t_hi0
                    "fmadd.d ft6, %[C0], ft3, %[C1]                   \n" // [FPU] z1_poly
                    "lw      a6, 4(a6)                                \n" // [LSU] t_hi1
                    "fmadd.d ft7, %[C0], ft4, %[C1]                   \n" // [FPU] z2_poly
                    "lw      a7, 4(a7)                                \n" // [LSU] t_hi2
                    "fmadd.d ft8, %[C0], ft5, %[C1]                   \n" // [FPU] z3_poly
                    "lw      t0, 4(t0)                                \n" // [LSU] t_hi3
                    "fmadd.d fa4, %[C2], fa3, %[C3]                   \n" // [FPU] y0_poly
                    "sw      a2, 0(%[t])                              \n" // [LSU] store low0
                    "add     a0, a0, a1                               \n" // [ALU] hi0 + ki
                    "fmadd.d fs0, %[C2], ft3, %[C3]                   \n" // [FPU] y1_poly
                    "sw      t1, 8(%[t])                              \n" // [LSU] store low1
                    "add     a3, a3, a6                               \n" // [ALU] hi1 + ki
                    "fmadd.d fs1, %[C2], ft4, %[C3]                   \n" // [FPU] y2_poly
                    "sw      t2, 16(%[t])                             \n" // [LSU] store low2
                    "add     a4, a4, a7                               \n" // [ALU] hi2 + ki
                    "fmadd.d fs2, %[C2], ft5, %[C3]                   \n" // [FPU] y3_poly
                    "sw      t3, 24(%[t])                             \n" // [LSU] store low3
                    "add     a5, a5, t0                               \n" // [ALU] hi3 + ki
                    "fmul.d  fa1, fa3, fa3                            \n" // [FPU] r2_0 = r0 * r0
                    "sw      a0, 4(%[t])                              \n" // [LSU] store hi0
                    "fmul.d  fa5, ft3, ft3                            \n" // [FPU] r2_1
                    "sw      a3, 12(%[t])                             \n" // [LSU] store hi1
                    "fmul.d  fa6, ft4, ft4                            \n" // [FPU] r2_2
                    "sw      a4, 20(%[t])                             \n" // [LSU] store hi2             
                    "fmul.d  fa7, ft5, ft5                            \n" // [FPU] r2_3
                    "sw      a5, 28(%[t])                             \n" // [LSU] store hi3
                    "fmadd.d fa4, fa2, fa1, fa4                       \n" // [FPU] w0 = z0_poly * r2_0 + y0
                    "fld     fa0, 0(%[t])                             \n" // [LSU] s0 = asdouble(t)
                    "fmadd.d fs0, ft6, fa5, fs0                       \n" // [FPU] w1
                    "fld     ft9, 8(%[t])                             \n" // [LSU] s1
                    "fmadd.d fs1, ft7, fa6, fs1                       \n" // [FPU] w2
                    "fld     ft10, 16(%[t])                           \n" // [LSU] s2
                    "fmadd.d fs2, ft8, fa7, fs2                       \n" // [FPU] w3
                    "fld     ft11, 24(%[t])                           \n" // [LSU] s3
                    "fmul.d  fa4, fa4, fa0                            \n" // [FPU] result0 = w0 * s0
                    "fld     fa3, 0(%[in_addr])                       \n" // [LSU] next in0
                    "fmul.d  fs0, fs0, ft9                            \n" // [FPU] result1
                    "fld     ft3, 8(%[in_addr])                       \n" // [LSU] next in1
                    "fmul.d  fs1, fs1, ft10                           \n" // [FPU] result2
                    "fld     ft4, 16(%[in_addr])                      \n" // [LSU] next in2
                    "fmul.d  fs2, fs2, ft11                           \n" // [FPU] result3
                    "fld     ft5, 24(%[in_addr])                      \n" // [LSU] next in3
                    "fsd     fa4, 0(%[out_addr])                      \n" // [LSU] out0
                    "fsd     fs0, 8(%[out_addr])                      \n" // [LSU] out1
                    "fsd     fs1, 16(%[out_addr])                     \n" // [LSU] out2
                    "fsd     fs2, 24(%[out_addr])                     \n" // [LSU] out3
                    "addi    %[out_addr], %[out_addr], %[inc]         \n" // [ALU] update output ptr
#else
                    "fmul.d  fa3, %[InvLn2N], fa3             \n" // z = InvLn2N * xd
                    "fmul.d  ft3, %[InvLn2N], ft3             \n" // z = InvLn2N * xd
                    "fmul.d  ft4, %[InvLn2N], ft4             \n" // z = InvLn2N * xd
                    "fmul.d  ft5, %[InvLn2N], ft5             \n" // z = InvLn2N * xd
                    "addi    %[in_addr], %[in_addr], %[inc]   \n" // increment address after FPU to hide latency
                    "fadd.d  fa1, fa3, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fadd.d  fa5, ft3, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fadd.d  fa6, ft4, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fadd.d  fa7, ft5, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fmv.x.w a0, fa1                          \n" // ki = asuint64 (kd)
                    "fmv.x.w a3, fa5                          \n" // ki = asuint64 (kd)
                    "fmv.x.w a4, fa6                          \n" // ki = asuint64 (kd)
                    "fmv.x.w a5, fa7                          \n" // ki = asuint64 (kd)
                    "andi    a1, a0, 0x1f                     \n" // ki % N
                    "andi    a6, a3, 0x1f                     \n" // ki % N
                    "andi    a7, a4, 0x1f                     \n" // ki % N
                    "andi    t0, a5, 0x1f                     \n" // ki % N
                    "slli    a1, a1, 0x3                      \n" // T[ki % N]
                    "slli    a6, a6, 0x3                      \n" // T[ki % N]
                    "slli    a7, a7, 0x3                      \n" // T[ki % N]
                    "slli    t0, t0, 0x3                      \n" // T[ki % N]
                    "add     a1, %[T], a1                     \n" // T[ki % N]
                    "add     a6, %[T], a6                     \n" // T[ki % N]
                    "add     a7, %[T], a7                     \n" // T[ki % N]
                    "add     t0, %[T], t0                     \n" // T[ki % N]
                    "lw      a2, 0(a1)                        \n" // t = T[ki % N]
                    "lw      t1, 0(a6)                        \n" // t = T[ki % N]
                    "lw      t2, 0(a7)                        \n" // t = T[ki % N]
                    "lw      t3, 0(t0)                        \n" // t = T[ki % N]
                    "lw      a1, 4(a1)                        \n" // t = T[ki % N]
                    "lw      a6, 4(a6)                        \n" // t = T[ki % N]
                    "lw      a7, 4(a7)                        \n" // t = T[ki % N]
                    "lw      t0, 4(t0)                        \n" // t = T[ki % N]
                    "slli    a0, a0, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "slli    a3, a3, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "slli    a4, a4, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "slli    a5, a5, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "sw      a2, 0(%[t])                      \n" // store lower 32b of t (unaffected)
                    "sw      t1, 8(%[t])                      \n" // store lower 32b of t (unaffected)
                    "sw      t2, 16(%[t])                     \n" // store lower 32b of t (unaffected)
                    "sw      t3, 24(%[t])                     \n" // store lower 32b of t (unaffected)
                    "add     a0, a0, a1                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "add     a3, a3, a6                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "add     a4, a4, a7                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "add     a5, a5, t0                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "sw      a0, 4(%[t])                      \n" // store upper 32b of t
                    "sw      a3, 12(%[t])                     \n" // store upper 32b of t
                    "sw      a4, 20(%[t])                     \n" // store upper 32b of t
                    "sw      a5, 28(%[t])                     \n" // store upper 32b of t
                    "fsub.d  fa2, fa1, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  ft6, fa5, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  ft7, fa6, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  ft8, fa7, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  fa3, fa3, fa2                    \n" // r = z - kd
                    "fsub.d  ft3, ft3, ft6                    \n" // r = z - kd
                    "fsub.d  ft4, ft4, ft7                    \n" // r = z - kd
                    "fsub.d  ft5, ft5, ft8                    \n" // r = z - kd
                    "fmadd.d fa2, %[C0], fa3, %[C1]           \n" // z = C[0] * r + C[1]
                    "fmadd.d ft6, %[C0], ft3, %[C1]           \n" // z = C[0] * r + C[1]
                    "fmadd.d ft7, %[C0], ft4, %[C1]           \n" // z = C[0] * r + C[1]
                    "fmadd.d ft8, %[C0], ft5, %[C1]           \n" // z = C[0] * r + C[1]
                    "fld     fa0, 0(%[t])                     \n" // s = asdouble (t)
                    "fld     ft9, 8(%[t])                     \n" // s = asdouble (t)
                    "fld     ft10, 16(%[t])                   \n" // s = asdouble (t)
                    "fld     ft11, 24(%[t])                   \n" // s = asdouble (t)
                    "fmadd.d fa4, %[C2], fa3, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmadd.d fs0, %[C2], ft3, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmadd.d fs1, %[C2], ft4, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmadd.d fs2, %[C2], ft5, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmul.d  fa1, fa3, fa3                    \n" // r2 = r * r
                    "fmul.d  fa5, ft3, ft3                    \n" // r2 = r * r
                    "fmul.d  fa6, ft4, ft4                    \n" // r2 = r * r
                    "fmul.d  fa7, ft5, ft5                    \n" // r2 = r * r
                    "fmadd.d fa4, fa2, fa1, fa4               \n" // w = z * r2 + y
                    "fmadd.d fs0, ft6, fa5, fs0               \n" // w = z * r2 + y
                    "fmadd.d fs1, ft7, fa6, fs1               \n" // w = z * r2 + y
                    "fmadd.d fs2, ft8, fa7, fs2               \n" // w = z * r2 + y
                    "fmul.d  fa4, fa4, fa0                    \n" // y = w * s
                    "fmul.d  fs0, fs0, ft9                    \n" // y = w * s
                    "fmul.d  fs1, fs1, ft10                   \n" // y = w * s
                    "fmul.d  fs2, fs2, ft11                   \n" // y = w * s
                    "fld     fa3, 0(%[in_addr])               \n"
                    "fld     ft3, 8(%[in_addr])               \n"
                    "fld     ft4, 16(%[in_addr])              \n"
                    "fld     ft5, 24(%[in_addr])              \n"
                    "fsd     fa4, 0(%[out_addr])              \n"
                    "fsd     fs0, 8(%[out_addr])              \n"
                    "fsd     fs1, 16(%[out_addr])             \n"
                    "fsd     fs2, 24(%[out_addr])             \n"
                    "addi    %[out_addr], %[out_addr], %[inc] \n" // address update
#endif
                    // Terminate final iteration
                    "fmul.d  fa3, %[InvLn2N], fa3             \n" // z = InvLn2N * xd
                    "fmul.d  ft3, %[InvLn2N], ft3             \n" // z = InvLn2N * xd
                    "fmul.d  ft4, %[InvLn2N], ft4             \n" // z = InvLn2N * xd
                    "fmul.d  ft5, %[InvLn2N], ft5             \n" // z = InvLn2N * xd
                    "fadd.d  fa1, fa3, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fadd.d  fa5, ft3, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fadd.d  fa6, ft4, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fadd.d  fa7, ft5, %[SHIFT]               \n" // kd = (double) (z + SHIFT)
                    "fmv.x.w a0, fa1                          \n" // ki = asuint64 (kd)
                    "fmv.x.w a3, fa5                          \n" // ki = asuint64 (kd)
                    "fmv.x.w a4, fa6                          \n" // ki = asuint64 (kd)
                    "fmv.x.w a5, fa7                          \n" // ki = asuint64 (kd)
                    "andi    a1, a0, 0x1f                     \n" // ki % N
                    "andi    a6, a3, 0x1f                     \n" // ki % N
                    "andi    a7, a4, 0x1f                     \n" // ki % N
                    "andi    t0, a5, 0x1f                     \n" // ki % N
                    "slli    a1, a1, 0x3                      \n" // T[ki % N]
                    "slli    a6, a6, 0x3                      \n" // T[ki % N]
                    "slli    a7, a7, 0x3                      \n" // T[ki % N]
                    "slli    t0, t0, 0x3                      \n" // T[ki % N]
                    "add     a1, %[T], a1                     \n" // T[ki % N]
                    "add     a6, %[T], a6                     \n" // T[ki % N]
                    "add     a7, %[T], a7                     \n" // T[ki % N]
                    "add     t0, %[T], t0                     \n" // T[ki % N]
                    "lw      a2, 0(a1)                        \n" // t = T[ki % N]
                    "lw      t1, 0(a6)                        \n" // t = T[ki % N]
                    "lw      t2, 0(a7)                        \n" // t = T[ki % N]
                    "lw      t3, 0(t0)                        \n" // t = T[ki % N]
                    "lw      a1, 4(a1)                        \n" // t = T[ki % N]
                    "lw      a6, 4(a6)                        \n" // t = T[ki % N]
                    "lw      a7, 4(a7)                        \n" // t = T[ki % N]
                    "lw      t0, 4(t0)                        \n" // t = T[ki % N]
                    "slli    a0, a0, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "slli    a3, a3, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "slli    a4, a4, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "slli    a5, a5, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
                    "sw      a2, 0(%[t])                      \n" // store lower 32b of t (unaffected)
                    "sw      t1, 8(%[t])                      \n" // store lower 32b of t (unaffected)
                    "sw      t2, 16(%[t])                     \n" // store lower 32b of t (unaffected)
                    "sw      t3, 24(%[t])                     \n" // store lower 32b of t (unaffected)
                    "add     a0, a0, a1                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "add     a3, a3, a6                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "add     a4, a4, a7                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "add     a5, a5, t0                       \n" // t += ki << (52 - EXP2F_TABLE_BITS)
                    "sw      a0, 4(%[t])                      \n" // store upper 32b of t
                    "sw      a3, 12(%[t])                     \n" // store upper 32b of t
                    "sw      a4, 20(%[t])                     \n" // store upper 32b of t
                    "sw      a5, 28(%[t])                     \n" // store upper 32b of t
                    "fsub.d  fa2, fa1, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  ft6, fa5, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  ft7, fa6, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  ft8, fa7, %[SHIFT]               \n" // kd -= SHIFT
                    "fsub.d  fa3, fa3, fa2                    \n" // r = z - kd
                    "fsub.d  ft3, ft3, ft6                    \n" // r = z - kd
                    "fsub.d  ft4, ft4, ft7                    \n" // r = z - kd
                    "fsub.d  ft5, ft5, ft8                    \n" // r = z - kd
                    "fmadd.d fa2, %[C0], fa3, %[C1]           \n" // z = C[0] * r + C[1]
                    "fmadd.d ft6, %[C0], ft3, %[C1]           \n" // z = C[0] * r + C[1]
                    "fmadd.d ft7, %[C0], ft4, %[C1]           \n" // z = C[0] * r + C[1]
                    "fmadd.d ft8, %[C0], ft5, %[C1]           \n" // z = C[0] * r + C[1]
                    "fld     fa0, 0(%[t])                     \n" // s = asdouble (t)
                    "fld     ft9, 8(%[t])                     \n" // s = asdouble (t)
                    "fld     ft10, 16(%[t])                   \n" // s = asdouble (t)
                    "fld     ft11, 24(%[t])                   \n" // s = asdouble (t)
                    "fmadd.d fa4, %[C2], fa3, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmadd.d fs0, %[C2], ft3, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmadd.d fs1, %[C2], ft4, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmadd.d fs2, %[C2], ft5, %[C3]           \n" // y = C[2] * r + C[3]
                    "fmul.d  fa1, fa3, fa3                    \n" // r2 = r * r
                    "fmul.d  fa5, ft3, ft3                    \n" // r2 = r * r
                    "fmul.d  fa6, ft4, ft4                    \n" // r2 = r * r
                    "fmul.d  fa7, ft5, ft5                    \n" // r2 = r * r
                    "fmadd.d fa4, fa2, fa1, fa4               \n" // w = z * r2 + y
                    "fmadd.d fs0, ft6, fa5, fs0               \n" // w = z * r2 + y
                    "fmadd.d fs1, ft7, fa6, fs1               \n" // w = z * r2 + y
                    "fmadd.d fs2, ft8, fa7, fs2               \n" // w = z * r2 + y
                    "fmul.d  fa4, fa4, fa0                    \n" // y = w * s
                    "fmul.d  fs0, fs0, ft9                    \n" // y = w * s
                    "fmul.d  fs1, fs1, ft10                   \n" // y = w * s
                    "fmul.d  fs2, fs2, ft11                   \n" // y = w * s
                    "fsd     fa4, 0(%[out_addr])              \n"
                    "fsd     fs0, 8(%[out_addr])              \n"
                    "fsd     fs1, 16(%[out_addr])             \n"
                    "fsd     fs2, 24(%[out_addr])             \n"
                    // clang-format on
                    : [in_addr] "+r"(comp_a_ptr), [out_addr] "+r"(comp_b_ptr)
                    : [InvLn2N] "f"(InvLn2N), [SHIFT] "f"(SHIFT),
                      [inc] "i"(4 * sizeof(double)), [n_frep] "r"(n_frep_m2),
                      [C0] "f"(C[0]), [C1] "f"(C[1]), [C2] "f"(C[2]),
                      [C3] "f"(C[3]), [t] "r"(t), [T] "r"(T)
                    : "memory", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
                      "t0", "t1", "t2", "t3", "fa0", "fa1", "fa2", "fa3", "fa4",
                      "fa5", "fa6", "fa7", "ft3", "ft4", "ft5", "ft6", "ft7",
                      "ft8", "ft9", "ft10", "ft11", "fs0", "fs1", "fs2");

                // Increment buffer indices for next iteration
                comp_idx += 1;
                comp_idx %= N_BUFFERS;
            }
        }

        // Synchronize cores
        snrt_cluster_hw_barrier();
    }
}
