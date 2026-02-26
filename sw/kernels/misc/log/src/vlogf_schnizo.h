// Copyright 2024 ETH Zurich and University of Bologna.
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

static inline void vlogf_schnizo(float *a, double *b) {
    int n_batches = len / batch_size;
    int n_iterations = n_batches + 2;
    int n_frep_m2 = batch_size / 4 - 2;

    float *a_buffers[N_BUFFERS];
    double *b_buffers[N_BUFFERS];

    a_buffers[0] = ALLOCATE_BUFFER(float, batch_size);
    b_buffers[0] = ALLOCATE_BUFFER(double, batch_size);

    // Only allocate double buffers if there is more than one batch.
    // Allows to allocate larger tiles in this corner case.
    if (n_batches > 1) {
        a_buffers[1] = ALLOCATE_BUFFER(float, batch_size);
        b_buffers[1] = ALLOCATE_BUFFER(double, batch_size);
    }

    unsigned int dma_a_idx = 0;
    unsigned int dma_b_idx = 0;
    unsigned int comp_idx = 0;
    float *dma_a_ptr;
    double *dma_b_ptr;
    float *comp_a_ptr;
    double *comp_b_ptr;

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
                                      sizeof(float));

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

        // Compute cores
        if (snrt_cluster_core_idx() == 0) {
            // Compute phase
            if (iteration > 0 && iteration < n_iterations - 1) {
                // Index buffers
                comp_a_ptr = a_buffers[comp_idx];
                comp_b_ptr = b_buffers[comp_idx];

                // This loop requires:
                // - 22 ALU slots
                // - 28 LSU slots
                // - 40 FPU slots
                // We don't need to map all load/stores to a single LSU
                // since memory accesses are guaranteed not to alias.
                asm volatile(
                    // clang-format off
                    "lw       a0,  0(%[input])              \n" // ix = asuint (x)
                    "lw       a4,  4(%[input])              \n" // ix = asuint (x)
                    "lw       a5,  8(%[input])              \n" // ix = asuint (x)
                    "lw       a6, 12(%[input])              \n" // ix = asuint (x)
                    "addi    %[input], %[input], %[incf]    \n" // address update
                    "sub      a1, a0, %[OFF]                \n" // tmp = ix - OFF
                    "sub      a7, a4, %[OFF]                \n" // tmp = ix - OFF
                    "sub      t0, a5, %[OFF]                \n" // tmp = ix - OFF
                    "sub      t1, a6, %[OFF]                \n" // tmp = ix - OFF
                    "srai     a2, a1, 23                    \n" // k = (int32_t) tmp >> 23
                    "srai     t2, a7, 23                    \n" // k = (int32_t) tmp >> 23
                    "srai     t3, t0, 23                    \n" // k = (int32_t) tmp >> 23
                    "srai     t4, t1, 23                    \n" // k = (int32_t) tmp >> 23
                    "lui      a3, 1046528                   \n" // 0x1ff << 23
                    "lui      t5, 1046528                   \n" // 0x1ff << 23
                    "lui      t6, 1046528                   \n" // 0x1ff << 23
                    "lui      s0, 1046528                   \n" // 0x1ff << 23
                    "and      a3, a1, a3                    \n" // tmp & 0x1ff << 23
                    "and      t5, a7, t5                    \n" // tmp & 0x1ff << 23
                    "and      t6, t0, t6                    \n" // tmp & 0x1ff << 23
                    "and      s0, t1, s0                    \n" // tmp & 0x1ff << 23
                    "sub      a3, a0, a3                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "sub      t5, a4, t5                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "sub      t6, a5, t6                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "sub      s0, a6, s0                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "srli     a1, a1, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "srli     a7, a7, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "srli     t0, t0, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "srli     t1, t1, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "andi     a1, a1, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "andi     a7, a7, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "andi     t0, t0, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "andi     t1, t1, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "add      a1, %[T], a1                  \n" // T[i]
                    "add      a7, %[T], a7                  \n" // T[i]
                    "add      t0, %[T], t0                  \n" // T[i]
                    "add      t1, %[T], t1                  \n" // T[i]
                    FREP   " %[n_frep], 90, 0, 0            \n"
                    "fld      fa0, 0(a1)                    \n" // invc = T[i].invc
                    "fld      fa4, 0(a7)                    \n" // invc = T[i].invc
                    "fld      fa5, 0(t0)                    \n" // invc = T[i].invc
                    "fld      fa6, 0(t1)                    \n" // invc = T[i].invc
                    "fld      fa1, 8(a1)                    \n" // logc = T[i].logc
                    "fld      fa7, 8(a7)                    \n" // logc = T[i].logc
                    "fld      ft3, 8(t0)                    \n" // logc = T[i].logc
                    "fld      ft4, 8(t1)                    \n" // logc = T[i].logc
                    "fmv.w.x  fa2, a3                       \n" // asfloat (iz)
                    "fmv.w.x  ft5, t5                       \n" // asfloat (iz)
                    "fmv.w.x  ft6, t6                       \n" // asfloat (iz)
                    "fmv.w.x  ft7, s0                       \n" // asfloat (iz)
                    "fcvt.d.s fa2, fa2                      \n" // z = (double_t) asfloat (iz)
                    "fcvt.d.s ft5, ft5                      \n" // z = (double_t) asfloat (iz)
                    "fcvt.d.s ft6, ft6                      \n" // z = (double_t) asfloat (iz)
                    "fcvt.d.s ft7, ft7                      \n" // z = (double_t) asfloat (iz)
                    "fmadd.d  fa2, fa2, fa0, %[A3]          \n" // r = z * invc - 1
                    "fmadd.d  ft5, ft5, fa4, %[A3]          \n" // r = z * invc - 1
                    "fmadd.d  ft6, ft6, fa5, %[A3]          \n" // r = z * invc - 1
                    "fmadd.d  ft7, ft7, fa6, %[A3]          \n" // r = z * invc - 1
                    "fcvt.d.w fa0, a2                       \n" // (double_t) k
                    "fcvt.d.w fa4, t2                       \n" // (double_t) k
                    "fcvt.d.w fa5, t3                       \n" // (double_t) k
                    "fcvt.d.w fa6, t4                       \n" // (double_t) k
                    "fmadd.d  fa1, fa0, %[Ln2], fa1         \n" // y0 = logc + (double_t) k * Ln2
                    "fmadd.d  fa7, fa4, %[Ln2], fa7         \n" // y0 = logc + (double_t) k * Ln2
                    "fmadd.d  ft3, fa5, %[Ln2], ft3         \n" // y0 = logc + (double_t) k * Ln2
                    "fmadd.d  ft4, fa6, %[Ln2], ft4         \n" // y0 = logc + (double_t) k * Ln2
                    "fmul.d   fa0, fa2, fa2                 \n" // r2 = r * r
                    "fmul.d   fa4, ft5, ft5                 \n" // r2 = r * r
                    "fmul.d   fa5, ft6, ft6                 \n" // r2 = r * r
                    "fmul.d   fa6, ft7, ft7                 \n" // r2 = r * r
                    "fmadd.d  fa3, fa2, %[A1], %[A2]        \n" // y = A[1] * r + A[2]
                    "fmadd.d  ft8, ft5, %[A1], %[A2]        \n" // y = A[1] * r + A[2]
                    "fmadd.d  ft9, ft6, %[A1], %[A2]        \n" // y = A[1] * r + A[2]
                    "fmadd.d  ft10, ft7, %[A1], %[A2]       \n" // y = A[1] * r + A[2]
                    "fmadd.d  fa3, fa0, %[A0], fa3          \n" // y = A[0] * r2 + y
                    "fmadd.d  ft8, fa4, %[A0], ft8          \n" // y = A[0] * r2 + y
                    "fmadd.d  ft9, fa5, %[A0], ft9          \n" // y = A[0] * r2 + y
                    "fmadd.d  ft10, fa6, %[A0], ft10        \n" // y = A[0] * r2 + y
                    "fadd.d   fa1, fa1, fa2                 \n" // y = y * r2 + (y0 + r)
                    "fadd.d   fa7, fa7, ft5                 \n" // y = y * r2 + (y0 + r)
                    "fadd.d   ft3, ft3, ft6                 \n" // y = y * r2 + (y0 + r)
                    "fadd.d   ft4, ft4, ft7                 \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  fa1, fa3, fa0, fa1            \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  fa7, ft8, fa4, fa7            \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  ft3, ft9, fa5, ft3            \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  ft4, ft10, fa6, ft4           \n" // y = y * r2 + (y0 + r)
                    "lw       a0,  0(%[input])              \n" // ix = asuint (x)
                    "lw       a4,  4(%[input])              \n" // ix = asuint (x)
                    "lw       a5,  8(%[input])              \n" // ix = asuint (x)
                    "lw       a6, 12(%[input])              \n" // ix = asuint (x)
                    "fsd      fa1, 0(%[output])             \n"
                    "fsd      fa7, 8(%[output])             \n"
                    "fsd      ft3, 16(%[output])            \n"
                    "fsd      ft4, 24(%[output])            \n"
                    "sub      a1, a0, %[OFF]                \n" // tmp = ix - OFF
                    "sub      a7, a4, %[OFF]                \n" // tmp = ix - OFF
                    "sub      t0, a5, %[OFF]                \n" // tmp = ix - OFF
                    "sub      t1, a6, %[OFF]                \n" // tmp = ix - OFF
                    "srai     a2, a1, 23                    \n" // k = (int32_t) tmp >> 23
                    "srai     t2, a7, 23                    \n" // k = (int32_t) tmp >> 23
                    "srai     t3, t0, 23                    \n" // k = (int32_t) tmp >> 23
                    "srai     t4, t1, 23                    \n" // k = (int32_t) tmp >> 23
                    "lui      a3, 1046528                   \n" // 0x1ff << 23
                    "lui      t5, 1046528                   \n" // 0x1ff << 23
                    "lui      t6, 1046528                   \n" // 0x1ff << 23
                    "lui      s0, 1046528                   \n" // 0x1ff << 23
                    "and      a3, a1, a3                    \n" // tmp & 0x1ff << 23
                    "and      t5, a7, t5                    \n" // tmp & 0x1ff << 23
                    "and      t6, t0, t6                    \n" // tmp & 0x1ff << 23
                    "and      s0, t1, s0                    \n" // tmp & 0x1ff << 23
                    "sub      a3, a0, a3                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "sub      t5, a4, t5                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "sub      t6, a5, t6                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "sub      s0, a6, s0                    \n" // iz = ix - (tmp & 0x1ff << 23)
                    "srli     a1, a1, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "srli     a7, a7, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "srli     t0, t0, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "srli     t1, t1, 15                    \n" // tmp >> (23 - LOGF_TABLE_BITS)
                    "andi     a1, a1, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "andi     a7, a7, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "andi     t0, t0, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "andi     t1, t1, 240                   \n" // i = (tmp >> (23 - LOGF_TABLE_BITS)) % N
                    "add      a1, %[T], a1                  \n" // T[i]
                    "add      a7, %[T], a7                  \n" // T[i]
                    "add      t0, %[T], t0                  \n" // T[i]
                    "add      t1, %[T], t1                  \n" // T[i]
                    "addi     %[input], %[input], %[incf]   \n" // address update
                    "addi     %[output], %[output], %[incd] \n" // address update
                    // Terminate final iteration                    
                    "fld      fa0, 0(a1)                    \n" // invc = T[i].invc
                    "fld      fa4, 0(a7)                    \n" // invc = T[i].invc
                    "fld      fa5, 0(t0)                    \n" // invc = T[i].invc
                    "fld      fa6, 0(t1)                    \n" // invc = T[i].invc
                    "fld      fa1, 8(a1)                    \n" // logc = T[i].logc
                    "fld      fa7, 8(a7)                    \n" // logc = T[i].logc
                    "fld      ft3, 8(t0)                    \n" // logc = T[i].logc
                    "fld      ft4, 8(t1)                    \n" // logc = T[i].logc
                    "fmv.w.x  fa2, a3                       \n" // asfloat (iz)
                    "fmv.w.x  ft5, t5                       \n" // asfloat (iz)
                    "fmv.w.x  ft6, t6                       \n" // asfloat (iz)
                    "fmv.w.x  ft7, s0                       \n" // asfloat (iz)
                    "fcvt.d.s fa2, fa2                      \n" // z = (double_t) asfloat (iz)
                    "fcvt.d.s ft5, ft5                      \n" // z = (double_t) asfloat (iz)
                    "fcvt.d.s ft6, ft6                      \n" // z = (double_t) asfloat (iz)
                    "fcvt.d.s ft7, ft7                      \n" // z = (double_t) asfloat (iz)
                    "fmadd.d  fa2, fa2, fa0, %[A3]          \n" // r = z * invc - 1
                    "fmadd.d  ft5, ft5, fa4, %[A3]          \n" // r = z * invc - 1
                    "fmadd.d  ft6, ft6, fa5, %[A3]          \n" // r = z * invc - 1
                    "fmadd.d  ft7, ft7, fa6, %[A3]          \n" // r = z * invc - 1
                    "fcvt.d.w fa0, a2                       \n" // (double_t) k
                    "fcvt.d.w fa4, t2                       \n" // (double_t) k
                    "fcvt.d.w fa5, t3                       \n" // (double_t) k
                    "fcvt.d.w fa6, t4                       \n" // (double_t) k
                    "fmadd.d  fa1, fa0, %[Ln2], fa1         \n" // y0 = logc + (double_t) k * Ln2
                    "fmadd.d  fa7, fa4, %[Ln2], fa7         \n" // y0 = logc + (double_t) k * Ln2
                    "fmadd.d  ft3, fa5, %[Ln2], ft3         \n" // y0 = logc + (double_t) k * Ln2
                    "fmadd.d  ft4, fa6, %[Ln2], ft4         \n" // y0 = logc + (double_t) k * Ln2
                    "fmul.d   fa0, fa2, fa2                 \n" // r2 = r * r
                    "fmul.d   fa4, ft5, ft5                 \n" // r2 = r * r
                    "fmul.d   fa5, ft6, ft6                 \n" // r2 = r * r
                    "fmul.d   fa6, ft7, ft7                 \n" // r2 = r * r
                    "fmadd.d  fa3, fa2, %[A1], %[A2]        \n" // y = A[1] * r + A[2]
                    "fmadd.d  ft8, ft5, %[A1], %[A2]        \n" // y = A[1] * r + A[2]
                    "fmadd.d  ft9, ft6, %[A1], %[A2]        \n" // y = A[1] * r + A[2]
                    "fmadd.d  ft10, ft7, %[A1], %[A2]       \n" // y = A[1] * r + A[2]
                    "fmadd.d  fa3, fa0, %[A0], fa3          \n" // y = A[0] * r2 + y
                    "fmadd.d  ft8, fa4, %[A0], ft8          \n" // y = A[0] * r2 + y
                    "fmadd.d  ft9, fa5, %[A0], ft9          \n" // y = A[0] * r2 + y
                    "fmadd.d  ft10, fa6, %[A0], ft10        \n" // y = A[0] * r2 + y
                    "fadd.d   fa1, fa1, fa2                 \n" // y = y * r2 + (y0 + r)
                    "fadd.d   fa7, fa7, ft5                 \n" // y = y * r2 + (y0 + r)
                    "fadd.d   ft3, ft3, ft6                 \n" // y = y * r2 + (y0 + r)
                    "fadd.d   ft4, ft4, ft7                 \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  fa1, fa3, fa0, fa1            \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  fa7, ft8, fa4, fa7            \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  ft3, ft9, fa5, ft3            \n" // y = y * r2 + (y0 + r)
                    "fmadd.d  ft4, ft10, fa6, ft4           \n" // y = y * r2 + (y0 + r)
                    "lw       a0,  0(%[input])              \n" // ix = asuint (x)
                    "lw       a4,  4(%[input])              \n" // ix = asuint (x)
                    "lw       a5,  8(%[input])              \n" // ix = asuint (x)
                    "lw       a6, 12(%[input])              \n" // ix = asuint (x)
                    "fsd      fa1, 0(%[output])             \n"
                    "fsd      fa7, 8(%[output])             \n"
                    "fsd      ft3, 16(%[output])            \n"
                    "fsd      ft4, 24(%[output])            \n"
                    // clang-format on
                    : [ input ] "+r"(comp_a_ptr), [ output ] "+r"(comp_b_ptr)
                    : [ n_frep ] "r"(n_frep_m2), [ Ln2 ] "f"(Ln2),
                      [ incf ] "i"(4 * sizeof(float)),
                      [ incd ] "i"(4 * sizeof(double)), [ OFF ] "r"(OFF),
                      [ T ] "r"(T), [ A0 ] "f"(A[0]), [ A1 ] "f"(A[1]),
                      [ A2 ] "f"(A[2]), [ A3 ] "f"(A[3])
                    : "memory", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
                      "t0", "t1", "t2", "t3", "t4", "t5", "t6", "s0", "fa0",
                      "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7", "ft3",
                      "ft4", "ft5", "ft6", "ft7", "ft8", "ft9", "ft10");

                // Increment buffer indices for next iteration
                comp_idx += 1;
                comp_idx %= N_BUFFERS;

                snrt_fpu_fence();
            }
        }

        // Synchronize cores
        snrt_cluster_hw_barrier();
    }
}
