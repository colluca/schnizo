// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Luca Colagrande <colluca@iis.ee.ethz.ch>

#pragma once

#include "snrt.h"
#include "vexpf_const.h"

#ifndef FREP
#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif
#endif

// 4x-unrolled FP32 exponential compute kernel, adapted from vexpf_schnizo.
// Float I/O with internal double-precision computation. No DMA/buffering —
// callable by any compute core independently.
static inline void vexpf_fp32_schnizo(float *a, float *b, uint32_t len) {
    int n_frep = len / 4 - 2;
    uint64_t t[4];

    szrt_set_frep_mem_consistency(FREP_MEM_SERIALIZED);

    asm volatile(
        // clang-format off
        // Prologue: load first group of 4 floats (conversion at FREP body start).
        "flw     fa3,  0(%[in_addr])              \n"
        "flw     ft3,  4(%[in_addr])              \n"
        "flw     ft4,  8(%[in_addr])              \n"
        "flw     ft5, 12(%[in_addr])              \n"
        FREP   " %[n_frep], 98, 0, 0              \n"
        "fcvt.d.s fa3, fa3                        \n" // convert to double
        "fcvt.d.s ft3, ft3                        \n" // convert to double
        "fcvt.d.s ft4, ft4                        \n" // convert to double
        "fcvt.d.s ft5, ft5                        \n" // convert to double
        "fmul.d  fa3, %[InvLn2N], fa3             \n" // z = InvLn2N * xd
        "fmul.d  ft3, %[InvLn2N], ft3             \n" // z = InvLn2N * xd
        "fmul.d  ft4, %[InvLn2N], ft4             \n" // z = InvLn2N * xd
        "fmul.d  ft5, %[InvLn2N], ft5             \n" // z = InvLn2N * xd
        "addi    %[in_addr], %[in_addr], %[inc]   \n" // advance in ptr
        "fadd.d  fa1, fa3, %[SHIFT]               \n" // kd = z + SHIFT
        "fadd.d  fa5, ft3, %[SHIFT]               \n" // kd = z + SHIFT
        "fadd.d  fa6, ft4, %[SHIFT]               \n" // kd = z + SHIFT
        "fadd.d  fa7, ft5, %[SHIFT]               \n" // kd = z + SHIFT
        "fmv.x.w a0, fa1                          \n" // ki = asuint64(kd)
        "fmv.x.w a3, fa5                          \n" // ki = asuint64(kd)
        "fmv.x.w a4, fa6                          \n" // ki = asuint64(kd)
        "fmv.x.w a5, fa7                          \n" // ki = asuint64(kd)
        "andi    a1, a0, 0x1f                     \n" // ki % N
        "andi    a6, a3, 0x1f                     \n" // ki % N
        "andi    a7, a4, 0x1f                     \n" // ki % N
        "andi    t0, a5, 0x1f                     \n" // ki % N
        "slli    a1, a1, 0x3                      \n" // T[ki % N]
        "slli    a6, a6, 0x3                      \n" // T[ki % N]
        "slli    a7, a7, 0x3                      \n" // T[ki % N]
        "slli    t0, t0, 0x3                      \n" // T[ki % N]
        "add     a1, %[T], a1                     \n" // &T[ki % N]
        "add     a6, %[T], a6                     \n" // &T[ki % N]
        "add     a7, %[T], a7                     \n" // &T[ki % N]
        "add     t0, %[T], t0                     \n" // &T[ki % N]
        "lw      a2, 0(a1)                        \n" // t_lo = T[ki % N]
        "lw      t1, 0(a6)                        \n" // t_lo = T[ki % N]
        "lw      t2, 0(a7)                        \n" // t_lo = T[ki % N]
        "lw      t3, 0(t0)                        \n" // t_lo = T[ki % N]
        "lw      a1, 4(a1)                        \n" // t_hi = T[ki % N]
        "lw      a6, 4(a6)                        \n" // t_hi = T[ki % N]
        "lw      a7, 4(a7)                        \n" // t_hi = T[ki % N]
        "lw      t0, 4(t0)                        \n" // t_hi = T[ki % N]
        "slli    a0, a0, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
        "slli    a3, a3, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
        "slli    a4, a4, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
        "slli    a5, a5, 0xf                      \n" // ki << (52 - EXP2F_TABLE_BITS)
        "sw      a2,  0(%[t])                     \n" // store t_lo
        "sw      t1,  8(%[t])                     \n" // store t_lo
        "sw      t2, 16(%[t])                     \n" // store t_lo
        "sw      t3, 24(%[t])                     \n" // store t_lo
        "add     a0, a0, a1                       \n" // t += ki_shifted
        "add     a3, a3, a6                       \n" // t += ki_shifted
        "add     a4, a4, a7                       \n" // t += ki_shifted
        "add     a5, a5, t0                       \n" // t += ki_shifted
        "sw      a0,  4(%[t])                     \n" // store t_hi
        "sw      a3, 12(%[t])                     \n" // store t_hi
        "sw      a4, 20(%[t])                     \n" // store t_hi
        "sw      a5, 28(%[t])                     \n" // store t_hi
        "fsub.d  fa2, fa1, %[SHIFT]               \n" // kd -= SHIFT
        "fsub.d  ft6, fa5, %[SHIFT]               \n" // kd -= SHIFT
        "fsub.d  ft7, fa6, %[SHIFT]               \n" // kd -= SHIFT
        "fsub.d  ft8, fa7, %[SHIFT]               \n" // kd -= SHIFT
        "fsub.d  fa3, fa3, fa2                    \n" // r = z - kd
        "fsub.d  ft3, ft3, ft6                    \n" // r = z - kd
        "fsub.d  ft4, ft4, ft7                    \n" // r = z - kd
        "fsub.d  ft5, ft5, ft8                    \n" // r = z - kd
        "fmadd.d fa2, %[C0], fa3, %[C1]           \n" // z = C[0]*r + C[1]
        "fmadd.d ft6, %[C0], ft3, %[C1]           \n" // z = C[0]*r + C[1]
        "fmadd.d ft7, %[C0], ft4, %[C1]           \n" // z = C[0]*r + C[1]
        "fmadd.d ft8, %[C0], ft5, %[C1]           \n" // z = C[0]*r + C[1]
        "fld     fa0,  0(%[t])                    \n" // s = asdouble(t)
        "fld     ft9,  8(%[t])                    \n" // s = asdouble(t)
        "fld     ft10, 16(%[t])                   \n" // s = asdouble(t)
        "fld     ft11, 24(%[t])                   \n" // s = asdouble(t)
        "fmadd.d fa4, %[C2], fa3, %[C3]           \n" // y = C[2]*r + C[3]
        "fmadd.d fs0, %[C2], ft3, %[C3]           \n" // y = C[2]*r + C[3]
        "fmadd.d fs1, %[C2], ft4, %[C3]           \n" // y = C[2]*r + C[3]
        "fmadd.d fs2, %[C2], ft5, %[C3]           \n" // y = C[2]*r + C[3]
        "fmul.d  fa1, fa3, fa3                    \n" // r2 = r*r
        "fmul.d  fa5, ft3, ft3                    \n" // r2 = r*r
        "fmul.d  fa6, ft4, ft4                    \n" // r2 = r*r
        "fmul.d  fa7, ft5, ft5                    \n" // r2 = r*r
        "fmadd.d fa4, fa2, fa1, fa4               \n" // w = z*r2 + y
        "fmadd.d fs0, ft6, fa5, fs0               \n" // w = z*r2 + y
        "fmadd.d fs1, ft7, fa6, fs1               \n" // w = z*r2 + y
        "fmadd.d fs2, ft8, fa7, fs2               \n" // w = z*r2 + y
        "fmul.d  fa4, fa4, fa0                    \n" // y = w * s
        "fmul.d  fs0, fs0, ft9                    \n" // y = w * s
        "fmul.d  fs1, fs1, ft10                   \n" // y = w * s
        "fmul.d  fs2, fs2, ft11                   \n" // y = w * s
        "fcvt.s.d fa4, fa4                        \n" // convert to float
        "fcvt.s.d fs0, fs0                        \n" // convert to float
        "fcvt.s.d fs1, fs1                        \n" // convert to float
        "fcvt.s.d fs2, fs2                        \n" // convert to float
        // Load next group of 4 floats (conversion at start of next iteration).
        "flw     fa3,  0(%[in_addr])              \n"
        "flw     ft3,  4(%[in_addr])              \n"
        "flw     ft4,  8(%[in_addr])              \n"
        "flw     ft5, 12(%[in_addr])              \n"
        "fsw     fa4,  0(%[out_addr])             \n"
        "fsw     fs0,  4(%[out_addr])             \n"
        "fsw     fs1,  8(%[out_addr])             \n"
        "fsw     fs2, 12(%[out_addr])             \n"
        "addi    %[out_addr], %[out_addr], %[inc] \n"
        // Epilogue: process last group (floats loaded at end of final FREP iter).
        "fcvt.d.s fa3, fa3                        \n"
        "fcvt.d.s ft3, ft3                        \n"
        "fcvt.d.s ft4, ft4                        \n"
        "fcvt.d.s ft5, ft5                        \n"
        "fmul.d  fa3, %[InvLn2N], fa3             \n"
        "fmul.d  ft3, %[InvLn2N], ft3             \n"
        "fmul.d  ft4, %[InvLn2N], ft4             \n"
        "fmul.d  ft5, %[InvLn2N], ft5             \n"
        "fadd.d  fa1, fa3, %[SHIFT]               \n"
        "fadd.d  fa5, ft3, %[SHIFT]               \n"
        "fadd.d  fa6, ft4, %[SHIFT]               \n"
        "fadd.d  fa7, ft5, %[SHIFT]               \n"
        "fmv.x.w a0, fa1                          \n"
        "fmv.x.w a3, fa5                          \n"
        "fmv.x.w a4, fa6                          \n"
        "fmv.x.w a5, fa7                          \n"
        "andi    a1, a0, 0x1f                     \n"
        "andi    a6, a3, 0x1f                     \n"
        "andi    a7, a4, 0x1f                     \n"
        "andi    t0, a5, 0x1f                     \n"
        "slli    a1, a1, 0x3                      \n"
        "slli    a6, a6, 0x3                      \n"
        "slli    a7, a7, 0x3                      \n"
        "slli    t0, t0, 0x3                      \n"
        "add     a1, %[T], a1                     \n"
        "add     a6, %[T], a6                     \n"
        "add     a7, %[T], a7                     \n"
        "add     t0, %[T], t0                     \n"
        "lw      a2, 0(a1)                        \n"
        "lw      t1, 0(a6)                        \n"
        "lw      t2, 0(a7)                        \n"
        "lw      t3, 0(t0)                        \n"
        "lw      a1, 4(a1)                        \n"
        "lw      a6, 4(a6)                        \n"
        "lw      a7, 4(a7)                        \n"
        "lw      t0, 4(t0)                        \n"
        "slli    a0, a0, 0xf                      \n"
        "slli    a3, a3, 0xf                      \n"
        "slli    a4, a4, 0xf                      \n"
        "slli    a5, a5, 0xf                      \n"
        "sw      a2,  0(%[t])                     \n"
        "sw      t1,  8(%[t])                     \n"
        "sw      t2, 16(%[t])                     \n"
        "sw      t3, 24(%[t])                     \n"
        "add     a0, a0, a1                       \n"
        "add     a3, a3, a6                       \n"
        "add     a4, a4, a7                       \n"
        "add     a5, a5, t0                       \n"
        "sw      a0,  4(%[t])                     \n"
        "sw      a3, 12(%[t])                     \n"
        "sw      a4, 20(%[t])                     \n"
        "sw      a5, 28(%[t])                     \n"
        "fsub.d  fa2, fa1, %[SHIFT]               \n"
        "fsub.d  ft6, fa5, %[SHIFT]               \n"
        "fsub.d  ft7, fa6, %[SHIFT]               \n"
        "fsub.d  ft8, fa7, %[SHIFT]               \n"
        "fsub.d  fa3, fa3, fa2                    \n"
        "fsub.d  ft3, ft3, ft6                    \n"
        "fsub.d  ft4, ft4, ft7                    \n"
        "fsub.d  ft5, ft5, ft8                    \n"
        "fmadd.d fa2, %[C0], fa3, %[C1]           \n"
        "fmadd.d ft6, %[C0], ft3, %[C1]           \n"
        "fmadd.d ft7, %[C0], ft4, %[C1]           \n"
        "fmadd.d ft8, %[C0], ft5, %[C1]           \n"
        "fld     fa0,  0(%[t])                    \n"
        "fld     ft9,  8(%[t])                    \n"
        "fld     ft10, 16(%[t])                   \n"
        "fld     ft11, 24(%[t])                   \n"
        "fmadd.d fa4, %[C2], fa3, %[C3]           \n"
        "fmadd.d fs0, %[C2], ft3, %[C3]           \n"
        "fmadd.d fs1, %[C2], ft4, %[C3]           \n"
        "fmadd.d fs2, %[C2], ft5, %[C3]           \n"
        "fmul.d  fa1, fa3, fa3                    \n"
        "fmul.d  fa5, ft3, ft3                    \n"
        "fmul.d  fa6, ft4, ft4                    \n"
        "fmul.d  fa7, ft5, ft5                    \n"
        "fmadd.d fa4, fa2, fa1, fa4               \n"
        "fmadd.d fs0, ft6, fa5, fs0               \n"
        "fmadd.d fs1, ft7, fa6, fs1               \n"
        "fmadd.d fs2, ft8, fa7, fs2               \n"
        "fmul.d  fa4, fa4, fa0                    \n"
        "fmul.d  fs0, fs0, ft9                    \n"
        "fmul.d  fs1, fs1, ft10                   \n"
        "fmul.d  fs2, fs2, ft11                   \n"
        "fcvt.s.d fa4, fa4                        \n"
        "fcvt.s.d fs0, fs0                        \n"
        "fcvt.s.d fs1, fs1                        \n"
        "fcvt.s.d fs2, fs2                        \n"
        "fsw     fa4,  0(%[out_addr])             \n"
        "fsw     fs0,  4(%[out_addr])             \n"
        "fsw     fs1,  8(%[out_addr])             \n"
        "fsw     fs2, 12(%[out_addr])             \n"
        // clang-format on
        : [ in_addr ] "+r"(a), [ out_addr ] "+r"(b)
        : [ InvLn2N ] "f"(InvLn2N), [ SHIFT ] "f"(SHIFT),
          [ inc ] "i"(4 * sizeof(float)), [ n_frep ] "r"(n_frep), 
          [ C0 ] "f"(C[0]), [ C1 ] "f"(C[1]), [ C2 ] "f"(C[2]), 
          [ C3 ] "f"(C[3]), [ t ] "r"(t), [ T ] "r"(T)
        : "memory", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "t0", "t1",
          "t2", "t3", "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
          "ft3", "ft4", "ft5", "ft6", "ft7", "ft8", "ft9", "ft10", "ft11",
          "fs0", "fs1", "fs2");

    szrt_set_frep_mem_consistency(FREP_MEM_NO_CONSISTENCY);
}