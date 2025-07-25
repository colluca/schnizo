// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

// This reads from DRAM for simplicity. The DRAM is fast in simulation :)

static inline void vexpf_frep_unrolled(double *a, double *b) {
    uint64_t ki[4], t[4];

    // This loop requires:
    // ALU slots: 22
    // LSU slots: 8+8+8+4=28 (one LSU due to missing memory consistency)
    // FPU slots: 40
    if (snrt_cluster_core_idx() == 0) {
        // Loop over samples (unrolled by 4)
        asm volatile(
            // clang-format off
            "frep.o  %[n_reps], 90, 0, 0             \n"
            // Reuse the fmul destination register to load the input
            "fld     fa3, 0(%[in_addr])              \n"
            "fld     ft3, 8(%[in_addr])              \n"
            "fld     ft4, 16(%[in_addr])             \n"
            "fld     ft5, 24(%[in_addr])             \n"
            "fmul.d  fa3, %[InvLn2N], fa3            \n" // z = InvLn2N * xd
            "fmul.d  ft3, %[InvLn2N], ft3            \n" // z = InvLn2N * xd
            "fmul.d  ft4, %[InvLn2N], ft4            \n" // z = InvLn2N * xd
            "fmul.d  ft5, %[InvLn2N], ft5            \n" // z = InvLn2N * xd
            "addi    %[in_addr], %[in_addr], %[inc]  \n" // increment address after FPU to hide latency
            "fadd.d  fa1, fa3, %[SHIFT]              \n" // kd = (double) (z + SHIFT)
            "fadd.d  fa5, ft3, %[SHIFT]              \n" // kd = (double) (z + SHIFT)
            "fadd.d  fa6, ft4, %[SHIFT]              \n" // kd = (double) (z + SHIFT)
            "fadd.d  fa7, ft5, %[SHIFT]              \n" // kd = (double) (z + SHIFT)
            // Originally: store double to memory to load as bitstream
            // We can also use a move instruction
            "fmv.x.w a0, fa1                         \n" // ki = asuint64 (kd)
            "fmv.x.w a3, fa5                         \n" // ki = asuint64 (kd)
            "fmv.x.w a4, fa6                         \n" // ki = asuint64 (kd)
            "fmv.x.w a5, fa7                         \n" // ki = asuint64 (kd)
            // "fsd     fa1, 0(%[ki])                \n" // ki = asuint64 (kd)
            // "fsd     fa5, 8(%[ki])                \n" // ki = asuint64 (kd)
            // "fsd     fa6, 16(%[ki])               \n" // ki = asuint64 (kd)
            // "fsd     fa7, 24(%[ki])               \n" // ki = asuint64 (kd)
            // "lw      a0, 0(%[ki])                 \n" // ki = asuint64 (kd)
            // "lw      a3, 8(%[ki])                 \n" // ki = asuint64 (kd)
            // "lw      a4, 16(%[ki])                \n" // ki = asuint64 (kd)
            // "lw      a5, 24(%[ki])                \n" // ki = asuint64 (kd)
            "andi    a1, a0, 0x1f                    \n" // ki % N
            "andi    a6, a3, 0x1f                    \n" // ki % N
            "andi    a7, a4, 0x1f                    \n" // ki % N
            "andi    t0, a5, 0x1f                    \n" // ki % N
            "slli    a1, a1, 0x3                     \n" // T[ki % N]
            "slli    a6, a6, 0x3                     \n" // T[ki % N]
            "slli    a7, a7, 0x3                     \n" // T[ki % N]
            "slli    t0, t0, 0x3                     \n" // T[ki % N]
            "add     a1, %[T], a1                    \n" // T[ki % N]
            "add     a6, %[T], a6                    \n" // T[ki % N]
            "add     a7, %[T], a7                    \n" // T[ki % N]
            "add     t0, %[T], t0                    \n" // T[ki % N]
            "lw      a2, 0(a1)                       \n" // t = T[ki % N]
            "lw      t1, 0(a6)                       \n" // t = T[ki % N]
            "lw      t2, 0(a7)                       \n" // t = T[ki % N]
            "lw      t3, 0(t0)                       \n" // t = T[ki % N]
            "lw      a1, 4(a1)                       \n" // t = T[ki % N]
            "lw      a6, 4(a6)                       \n" // t = T[ki % N]
            "lw      a7, 4(a7)                       \n" // t = T[ki % N]
            "lw      t0, 4(t0)                       \n" // t = T[ki % N]
            "slli    a0, a0, 0xf                     \n" // ki << (52 - EXP2F_TABLE_BITS)
            "slli    a3, a3, 0xf                     \n" // ki << (52 - EXP2F_TABLE_BITS)
            "slli    a4, a4, 0xf                     \n" // ki << (52 - EXP2F_TABLE_BITS)
            "slli    a5, a5, 0xf                     \n" // ki << (52 - EXP2F_TABLE_BITS)
            "sw      a2, 0(%[t])                     \n" // store lower 32b of t (unaffected)
            "sw      t1, 8(%[t])                     \n" // store lower 32b of t (unaffected)
            "sw      t2, 16(%[t])                    \n" // store lower 32b of t (unaffected)
            "sw      t3, 24(%[t])                    \n" // store lower 32b of t (unaffected)
            "add     a0, a0, a1                      \n" // t += ki << (52 - EXP2F_TABLE_BITS)
            "add     a3, a3, a6                      \n" // t += ki << (52 - EXP2F_TABLE_BITS)
            "add     a4, a4, a7                      \n" // t += ki << (52 - EXP2F_TABLE_BITS)
            "add     a5, a5, t0                      \n" // t += ki << (52 - EXP2F_TABLE_BITS)
            "sw      a0, 4(%[t])                     \n" // store upper 32b of t
            "sw      a3, 12(%[t])                    \n" // store upper 32b of t
            "sw      a4, 20(%[t])                    \n" // store upper 32b of t
            "sw      a5, 28(%[t])                    \n" // store upper 32b of t
            "fsub.d  fa2, fa1, %[SHIFT]              \n" // kd -= SHIFT
            "fsub.d  ft6, fa5, %[SHIFT]              \n" // kd -= SHIFT
            "fsub.d  ft7, fa6, %[SHIFT]              \n" // kd -= SHIFT
            "fsub.d  ft8, fa7, %[SHIFT]              \n" // kd -= SHIFT
            "fsub.d  fa3, fa3, fa2                   \n" // r = z - kd
            "fsub.d  ft3, ft3, ft6                   \n" // r = z - kd
            "fsub.d  ft4, ft4, ft7                   \n" // r = z - kd
            "fsub.d  ft5, ft5, ft8                   \n" // r = z - kd
            "fmadd.d fa2, %[C0], fa3, %[C1]          \n" // z = C[0] * r + C[1]
            "fmadd.d ft6, %[C0], ft3, %[C1]          \n" // z = C[0] * r + C[1]
            "fmadd.d ft7, %[C0], ft4, %[C1]          \n" // z = C[0] * r + C[1]
            "fmadd.d ft8, %[C0], ft5, %[C1]          \n" // z = C[0] * r + C[1]
            // These loads we cannot convert to move instructions due to ISA limitations (would need RV64)
            "fld     fa0, 0(%[t])                    \n" // s = asdouble (t)
            "fld     ft9, 8(%[t])                    \n" // s = asdouble (t)
            "fld     ft10, 16(%[t])                  \n" // s = asdouble (t)
            "fld     ft11, 24(%[t])                  \n" // s = asdouble (t)
            "fmadd.d fa4, %[C2], fa3, %[C3]          \n" // y = C[2] * r + C[3]
            "fmadd.d fs0, %[C2], ft3, %[C3]          \n" // y = C[2] * r + C[3]
            "fmadd.d fs1, %[C2], ft4, %[C3]          \n" // y = C[2] * r + C[3]
            "fmadd.d fs2, %[C2], ft5, %[C3]          \n" // y = C[2] * r + C[3]
            "fmul.d  fa1, fa3, fa3                   \n" // r2 = r * r
            "fmul.d  fa5, ft3, ft3                   \n" // r2 = r * r
            "fmul.d  fa6, ft4, ft4                   \n" // r2 = r * r
            "fmul.d  fa7, ft5, ft5                   \n" // r2 = r * r
            "fmadd.d fa4, fa2, fa1, fa4              \n" // w = z * r2 + y
            "fmadd.d fs0, ft6, fa5, fs0              \n" // w = z * r2 + y
            "fmadd.d fs1, ft7, fa6, fs1              \n" // w = z * r2 + y
            "fmadd.d fs2, ft8, fa7, fs2              \n" // w = z * r2 + y
            // reuse operand register as destination to then store the values.
            "fmul.d  fa4, fa4, fa0                   \n" // y = w * s
            "fmul.d  fs0, fs0, ft9                   \n" // y = w * s
            "fmul.d  fs1, fs1, ft10                  \n" // y = w * s
            "fmul.d  fs2, fs2, ft11                  \n" // y = w * s
            // store the values
            "fsd     fa4, 0(%[out_addr])             \n"
            "fsd     fs0, 8(%[out_addr])             \n"
            "fsd     fs1, 16(%[out_addr])            \n"
            "fsd     fs2, 24(%[out_addr])            \n"
            "addi    %[out_addr], %[out_addr], %[inc]\n" // address update
            // clang-format on
        : [ in_addr ] "+r"(a), [ out_addr ] "+r"(b)
        : [ InvLn2N ] "f"(InvLn2N), [ SHIFT ] "f"(SHIFT),
          [ inc ] "i"(sizeof(double)), [ n_reps ] "r"(LEN-1),
          [ C0 ] "f"(C[0]), [ C1 ] "f"(C[1]), [ C2 ] "f"(C[2]),
          [ C3 ] "f"(C[3]), [ ki ] "r"(ki), [ t ] "r"(t),
          [ T ] "r"(T)
        : "memory", "a0", "a1", "a2", "a3", "a4", "a5", "a6",
            "a7", "t0", "t1", "t2", "t3", "fa0", "fa1", "fa2",
            "fa3", "fa4", "fa5", "fa6", "fa7", "ft3", "ft4",
            "ft5", "ft6", "ft7", "ft8", "ft9", "ft10", "ft11",
            "fs0", "fs1", "fs2"
        );
    }
}
