// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "snrt.h"

#ifndef FREP
#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif
#endif

#ifndef SPLIT_ELTWISE_FNS
#define SPLIT_ELTWISE_FNS 0
#endif

typedef enum {
    ELTWISE_ADD = 0,
    ELTWISE_MUL = 1,
    ELTWISE_DIV = 2,
    ELTWISE_NEG = 3
} eltwise_op_t;

typedef void (*eltwise_fp_t)(float *a, float *b, float *out, uint32_t size,
                             eltwise_op_t op);

typedef struct {
    uint32_t size;
    uint32_t n_tiles;
    eltwise_op_t op;
    void *ifmap0;
    void *ifmap1;
    void *ofmap;
    precision_t dtype;
    eltwise_fp_t funcptr;
} eltwise_layer_t;

static inline void eltwise_fp32_naive(float *a, float *b, float *out,
                                      uint32_t size, eltwise_op_t op) {
    switch (op) {
        case ELTWISE_ADD:
            for (uint32_t i = 0; i < size; i++) out[i] = a[i] + b[i];
            break;
        case ELTWISE_MUL:
            for (uint32_t i = 0; i < size; i++) out[i] = a[i] * b[i];
            break;
        case ELTWISE_DIV:
            for (uint32_t i = 0; i < size; i++) out[i] = a[i] / b[i];
            break;
        case ELTWISE_NEG:
            for (uint32_t i = 0; i < size; i++) out[i] = -a[i];
            break;
    }
}

static inline void eltwise_fp32_baseline(float *a, float *b, float *out,
                                         uint32_t size, eltwise_op_t op) {
    switch (op) {
        case ELTWISE_ADD:
#pragma clang loop unroll_count(4)
            for (uint32_t i = 0; i < size; i++) out[i] = a[i] + b[i];
            break;
        case ELTWISE_MUL:
#pragma clang loop unroll_count(4)
            for (uint32_t i = 0; i < size; i++) out[i] = a[i] * b[i];
            break;
        case ELTWISE_DIV:
#pragma clang loop unroll_count(4)
            for (uint32_t i = 0; i < size; i++) out[i] = a[i] / b[i];
            break;
        case ELTWISE_NEG:
#pragma clang loop unroll_count(4)
            for (uint32_t i = 0; i < size; i++) out[i] = -a[i];
            break;
    }
}

// Load-use-store kernel: frep.i → 4x unroll (hides load latency under ZOL),
// frep.o → scalar (unrolling hurts superscalar performance).
// Binary 4x: 8 flw + 4 FP + 4 fsw + 3 addi = 19 insns, n_frep = size/4 - 1.
// Binary scalar: flw + flw + FP + fsw + 3 addi = 7 insns, n_frep = size - 1.
// NEG 4x (unary): 4 flw + 4 fneg + 4 fsw + 2 addi = 14 insns, n_frep = size/4 - 1.
// NEG scalar: flw + fneg + fsw + 2 addi = 5 insns, n_frep = size - 1.
// DIV: scalar only (iterative divider stalls; no benefit in unrolling).
static inline void eltwise_fp32_schnizo(float *a, float *b, float *out,
                                        uint32_t size, eltwise_op_t op) {
    switch (op) {
        case ELTWISE_ADD:
#ifdef FORCE_HW_LOOP
        {
            int n_frep = size / 4 - 1;
            asm volatile(
                "frep.i %[n], 19, 0, 0              \n"
                "flw    fa0,  0(%[a])               \n"
                "flw    fa4,  0(%[b])               \n"
                "flw    fa1,  4(%[a])               \n"
                "flw    fa5,  4(%[b])               \n"
                "flw    fa2,  8(%[a])               \n"
                "flw    fa6,  8(%[b])               \n"
                "flw    fa3, 12(%[a])               \n"
                "flw    fa7, 12(%[b])               \n"
                "fadd.s fa0, fa0, fa4               \n"
                "fadd.s fa1, fa1, fa5               \n"
                "fadd.s fa2, fa2, fa6               \n"
                "fadd.s fa3, fa3, fa7               \n"
                "fsw    fa0,  0(%[out])             \n"
                "fsw    fa1,  4(%[out])             \n"
                "fsw    fa2,  8(%[out])             \n"
                "fsw    fa3, 12(%[out])             \n"
                "addi   %[a],   %[a],   16         \n"
                "addi   %[b],   %[b],   16         \n"
                "addi   %[out], %[out], 16         \n"
                : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                : [ n ] "r"(n_frep)
                : "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
                  "memory");
        }
#else
        {
            int n_frep = size - 1;
            asm volatile(
                "frep.o %[n], 7, 0, 0               \n"
                "flw    fa0,  0(%[a])               \n"
                "flw    fa1,  0(%[b])               \n"
                "fadd.s fa0, fa0, fa1               \n"
                "fsw    fa0,  0(%[out])             \n"
                "addi   %[a],   %[a],    4          \n"
                "addi   %[b],   %[b],    4          \n"
                "addi   %[out], %[out],  4          \n"
                : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                : [ n ] "r"(n_frep)
                : "fa0", "fa1", "memory");
        }
#endif
        break;
        case ELTWISE_MUL:
#ifdef FORCE_HW_LOOP
        {
            int n_frep = size / 4 - 1;
            asm volatile(
                "frep.i %[n], 19, 0, 0              \n"
                "flw    fa0,  0(%[a])               \n"
                "flw    fa4,  0(%[b])               \n"
                "flw    fa1,  4(%[a])               \n"
                "flw    fa5,  4(%[b])               \n"
                "flw    fa2,  8(%[a])               \n"
                "flw    fa6,  8(%[b])               \n"
                "flw    fa3, 12(%[a])               \n"
                "flw    fa7, 12(%[b])               \n"
                "fmul.s fa0, fa0, fa4               \n"
                "fmul.s fa1, fa1, fa5               \n"
                "fmul.s fa2, fa2, fa6               \n"
                "fmul.s fa3, fa3, fa7               \n"
                "fsw    fa0,  0(%[out])             \n"
                "fsw    fa1,  4(%[out])             \n"
                "fsw    fa2,  8(%[out])             \n"
                "fsw    fa3, 12(%[out])             \n"
                "addi   %[a],   %[a],   16         \n"
                "addi   %[b],   %[b],   16         \n"
                "addi   %[out], %[out], 16         \n"
                : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                : [ n ] "r"(n_frep)
                : "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
                  "memory");
        }
#else
        {
            int n_frep = size - 1;
            asm volatile(
                "frep.o %[n], 7, 0, 0               \n"
                "flw    fa0,  0(%[a])               \n"
                "flw    fa1,  0(%[b])               \n"
                "fmul.s fa0, fa0, fa1               \n"
                "fsw    fa0,  0(%[out])             \n"
                "addi   %[a],   %[a],    4          \n"
                "addi   %[b],   %[b],    4          \n"
                "addi   %[out], %[out],  4          \n"
                : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                : [ n ] "r"(n_frep)
                : "fa0", "fa1", "memory");
        }
#endif
        break;
        case ELTWISE_DIV: {
            int n_frep_div = size - 1;
            asm volatile(FREP
                         " %[n], 7, 0, 0               \n"
                         "flw    fa0,  0(%[a])               \n"
                         "flw    fa1,  0(%[b])               \n"
                         "fdiv.s fa0, fa0, fa1               \n"
                         "fsw    fa0,  0(%[out])             \n"
                         "addi   %[a],   %[a],    4          \n"
                         "addi   %[b],   %[b],    4          \n"
                         "addi   %[out], %[out],  4          \n"
                         : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                         : [ n ] "r"(n_frep_div)
                         : "fa0", "fa1", "memory");
            break;
        }
        case ELTWISE_NEG:
#ifdef FORCE_HW_LOOP
        {
            int n_frep = size / 4 - 1;
            asm volatile(
                "frep.i %[n], 14, 0, 0              \n"
                "flw    fa0,  0(%[a])               \n"
                "flw    fa1,  4(%[a])               \n"
                "flw    fa2,  8(%[a])               \n"
                "flw    fa3, 12(%[a])               \n"
                "fneg.s fa0, fa0                    \n"
                "fneg.s fa1, fa1                    \n"
                "fneg.s fa2, fa2                    \n"
                "fneg.s fa3, fa3                    \n"
                "fsw    fa0,  0(%[out])             \n"
                "fsw    fa1,  4(%[out])             \n"
                "fsw    fa2,  8(%[out])             \n"
                "fsw    fa3, 12(%[out])             \n"
                "addi   %[a],   %[a],   16         \n"
                "addi   %[out], %[out], 16         \n"
                : [ a ] "+r"(a), [ out ] "+r"(out)
                : [ n ] "r"(n_frep)
                : "fa0", "fa1", "fa2", "fa3", "memory");
        }
#else
        {
            int n_frep = size - 1;
            asm volatile(
                "frep.o %[n], 5, 0, 0               \n"
                "flw    fa0,  0(%[a])               \n"
                "fneg.s fa0, fa0                    \n"
                "fsw    fa0,  0(%[out])             \n"
                "addi   %[a],   %[a],    4          \n"
                "addi   %[out], %[out],  4          \n"
                : [ a ] "+r"(a), [ out ] "+r"(out)
                : [ n ] "r"(n_frep)
                : "fa0", "memory");
        }
#endif
        break;
    }
}

// Load-use-store kernel: frep.i → 4x unroll (hides load latency under ZOL),
// frep.o → scalar (unrolling hurts superscalar performance).
// Binary 4x: 8 flw + 4 FP + 4 fsw + 3 addi = 19 insns, n_frep = size/4 - 1.
// Binary scalar: flw + flw + FP + fsw + 3 addi = 7 insns, n_frep = size - 1.
// NEG 4x (unary): 4 flw + 4 fneg + 4 fsw + 2 addi = 14 insns, n_frep = size/4 - 1.
// NEG scalar: flw + fneg + fsw + 2 addi = 5 insns, n_frep = size - 1.
// DIV: scalar only (iterative divider stalls; no benefit in unrolling).
static inline void eltwise_add_fp32_schnova(float *a, float *b, float *out,
                                            uint32_t size) {
    // LSU0 and LSU1, are dedicated for loads
    uint32_t load_mask = (1 << 0) | (1 << 1);
    // LSU2 is dedicated for stores
    uint32_t store_mask = (1 << 2);
    if (szrt_nof_lsus() >= 3) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
#ifdef UNROLL
    int n_frep = size / 4 - 1;
    asm volatile(FREP
                 " %[n], 19, 0, 0              \n"
                 "flw    fa0,  0(%[a])               \n"
                 "flw    fa4,  0(%[b])               \n"
                 "flw    fa1,  4(%[a])               \n"
                 "flw    fa5,  4(%[b])               \n"
                 "flw    fa2,  8(%[a])               \n"
                 "flw    fa6,  8(%[b])               \n"
                 "flw    fa3, 12(%[a])               \n"
                 "flw    fa7, 12(%[b])               \n"
                 "fadd.s fa0, fa0, fa4               \n"
                 "fadd.s fa1, fa1, fa5               \n"
                 "fadd.s fa2, fa2, fa6               \n"
                 "fadd.s fa3, fa3, fa7               \n"
                 "fsw    fa0,  0(%[out])             \n"
                 "fsw    fa1,  4(%[out])             \n"
                 "fsw    fa2,  8(%[out])             \n"
                 "fsw    fa3, 12(%[out])             \n"
                 "addi   %[a],   %[a],   16         \n"
                 "addi   %[b],   %[b],   16         \n"
                 "addi   %[out], %[out], 16         \n"
                 : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                 : [ n ] "r"(n_frep)
                 : "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
                   "memory");
#elif defined(BALANCE_INSTRUCTION_MIX) && defined(UNROLL)
    int n_frep = size / 4 - 1;
    asm volatile(FREP
                 " %[n], 19, 0, 0              \n"
                 "flw    fa0,  0(%[a])               \n"
                 "flw    fa4,  0(%[b])               \n"
                 "fadd.s fa0, fa0, fa4               \n"
                 "fsw    fa0,  0(%[out])             \n"
                 "flw    fa1,  4(%[a])               \n"
                 "flw    fa5,  4(%[b])               \n"
                 "fadd.s fa1, fa1, fa5               \n"
                 "fsw    fa1,  4(%[out])             \n"
                 "flw    fa2,  8(%[a])               \n"
                 "flw    fa6,  8(%[b])               \n"
                 "fadd.s fa2, fa2, fa6               \n"
                 "fsw    fa2,  8(%[out])             \n"
                 "flw    fa3, 12(%[a])               \n"
                 "flw    fa7, 12(%[b])               \n"
                 "fadd.s fa3, fa3, fa7               \n"
                 "fsw    fa3, 12(%[out])             \n"
                 "addi   %[a],   %[a],   16         \n"
                 "addi   %[b],   %[b],   16         \n"
                 "addi   %[out], %[out], 16         \n"
                 : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                 : [ n ] "r"(n_frep)
                 : "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
                   "memory");
#else
    int n_frep = size - 1;
    // Add nops for schnova to align the fetch block address
    asm volatile(
        "nop                                \n"
        "nop                                \n"
        "frep.o %[n], 7, 0, 0               \n"
        "flw    fa0,  0(%[a])               \n"
        "flw    fa1,  0(%[b])               \n"
        "fadd.s fa0, fa0, fa1               \n"
        "fsw    fa0,  0(%[out])             \n"
        "addi   %[a],   %[a],    4          \n"
        "addi   %[b],   %[b],    4          \n"
        "addi   %[out], %[out],  4          \n"
        : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
        : [ n ] "r"(n_frep)
        : "fa0", "fa1", "memory");
#endif
}

static inline void eltwise_mul_fp32_schnova(float *a, float *b, float *out,
                                            uint32_t size) {
    // LSU0 and LSU1, are dedicated for loads
    uint32_t load_mask = (1 << 0) | (1 << 1);
    // LSU2 is dedicated for stores
    uint32_t store_mask = (1 << 2);
    if (szrt_nof_lsus() >= 3) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
#ifdef UNROLL
    int n_frep = size / 4 - 1;
    asm volatile(FREP
                 " %[n], 19, 0, 0              \n"
                 "flw    fa0,  0(%[a])               \n"
                 "flw    fa4,  0(%[b])               \n"
                 "flw    fa1,  4(%[a])               \n"
                 "flw    fa5,  4(%[b])               \n"
                 "flw    fa2,  8(%[a])               \n"
                 "flw    fa6,  8(%[b])               \n"
                 "flw    fa3, 12(%[a])               \n"
                 "flw    fa7, 12(%[b])               \n"
                 "fmul.s fa0, fa0, fa4               \n"
                 "fmul.s fa1, fa1, fa5               \n"
                 "fmul.s fa2, fa2, fa6               \n"
                 "fmul.s fa3, fa3, fa7               \n"
                 "fsw    fa0,  0(%[out])             \n"
                 "fsw    fa1,  4(%[out])             \n"
                 "fsw    fa2,  8(%[out])             \n"
                 "fsw    fa3, 12(%[out])             \n"
                 "addi   %[a],   %[a],   16         \n"
                 "addi   %[b],   %[b],   16         \n"
                 "addi   %[out], %[out], 16         \n"
                 : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                 : [ n ] "r"(n_frep)
                 : "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
                   "memory");
#elif defined(BALANCE_INSTRUCTION_MIX) && defined(UNROLL)
    int n_frep = size / 4 - 1;
    asm volatile(FREP
                 " %[n], 19, 0, 0              \n"
                 "flw    fa0,  0(%[a])               \n"
                 "flw    fa4,  0(%[b])               \n"
                 "fmul.s fa0, fa0, fa4               \n"
                 "fsw    fa0,  0(%[out])             \n"
                 "flw    fa1,  4(%[a])               \n"
                 "flw    fa5,  4(%[b])               \n"
                 "fmul.s fa1, fa1, fa5               \n"
                 "fsw    fa1,  4(%[out])             \n"
                 "flw    fa2,  8(%[a])               \n"
                 "flw    fa6,  8(%[b])               \n"
                 "fmul.s fa2, fa2, fa6               \n"
                 "fsw    fa2,  8(%[out])             \n"
                 "flw    fa3, 12(%[a])               \n"
                 "flw    fa7, 12(%[b])               \n"
                 "fmul.s fa3, fa3, fa7               \n"
                 "fsw    fa3, 12(%[out])             \n"
                 "addi   %[a],   %[a],   16         \n"
                 "addi   %[b],   %[b],   16         \n"
                 "addi   %[out], %[out], 16         \n"
                 : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
                 : [ n ] "r"(n_frep)
                 : "fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
                   "memory");
#else
    int n_frep = size - 1;
    asm volatile(
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "frep.o %[n], 7, 0, 0               \n"
        "flw    fa0,  0(%[a])               \n"
        "flw    fa1,  0(%[b])               \n"
        "fmul.s fa0, fa0, fa1               \n"
        "fsw    fa0,  0(%[out])             \n"
        "addi   %[a],   %[a],    4          \n"
        "addi   %[b],   %[b],    4          \n"
        "addi   %[out], %[out],  4          \n"
        : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
        : [ n ] "r"(n_frep)
        : "fa0", "fa1", "memory");
#endif
}
static inline void eltwise_div_fp32_schnova(float *a, float *b, float *out,
                                            uint32_t size) {
    if (szrt_nof_lsus() >= 3) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en((1 << 0) | (1 << 1));
        szrt_set_frep_lsu_store_en((1 << 2));
    } else if (szrt_nof_lsus() == 2) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en((1 << 0));
        szrt_set_frep_lsu_store_en((1 << 1));
    }
    int n_frep_div = size - 1;
    asm volatile(
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "nop                                \n" FREP
        " %[n], 7, 0, 0               \n"
        "flw    fa0,  0(%[a])               \n"
        "flw    fa1,  0(%[b])               \n"
        "fdiv.s fa0, fa0, fa1               \n"
        "fsw    fa0,  0(%[out])             \n"
        "addi   %[a],   %[a],    4          \n"
        "addi   %[b],   %[b],    4          \n"
        "addi   %[out], %[out],  4          \n"
        : [ a ] "+r"(a), [ b ] "+r"(b), [ out ] "+r"(out)
        : [ n ] "r"(n_frep_div)
        : "fa0", "fa1", "memory");
}

static inline void eltwise_neg_fp32_schnova(float *a, float *b, float *out,
                                            uint32_t size) {
#ifdef UNROLL
    // LSU0 is dedicated for loads
    uint32_t load_mask = (1 << 0);
    // LSU1 is dedicated for stores
    uint32_t store_mask = (1 << 1);
    if (szrt_nof_lsus() == 2) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
    int n_frep = size / 4 - 1;
    asm volatile(FREP
                 " %[n], 14, 0, 0              \n"
                 "flw    fa0,  0(%[a])               \n"
                 "flw    fa1,  4(%[a])               \n"
                 "flw    fa2,  8(%[a])               \n"
                 "flw    fa3, 12(%[a])               \n"
                 "fneg.s fa0, fa0                    \n"
                 "fneg.s fa1, fa1                    \n"
                 "fneg.s fa2, fa2                    \n"
                 "fneg.s fa3, fa3                    \n"
                 "fsw    fa0,  0(%[out])             \n"
                 "fsw    fa1,  4(%[out])             \n"
                 "fsw    fa2,  8(%[out])             \n"
                 "fsw    fa3, 12(%[out])             \n"
                 "addi   %[a],   %[a],   16         \n"
                 "addi   %[out], %[out], 16         \n"
                 : [ a ] "+r"(a), [ out ] "+r"(out)
                 : [ n ] "r"(n_frep)
                 : "fa0", "fa1", "fa2", "fa3", "memory");
#elif defined(BALANCE_INSTRUCTION_MIX) && defined(UNROLL)
    // LSU0 is dedicated for loads
    uint32_t load_mask = (1 << 0);
    // LSU1 is dedicated for stores
    uint32_t store_mask = (1 << 1);
    if (szrt_nof_lsus() == 2) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
    int n_frep = size / 4 - 1;
    asm volatile(FREP
                 " %[n], 14, 0, 0              \n"
                 "flw    fa0,  0(%[a])               \n"
                 "fneg.s fa0, fa0                    \n"
                 "fsw    fa0,  0(%[out])             \n"
                 "flw    fa1,  4(%[a])               \n"
                 "fneg.s fa1, fa1                    \n"
                 "fsw    fa1,  4(%[out])             \n"
                 "flw    fa2,  8(%[a])               \n"
                 "fneg.s fa2, fa2                    \n"
                 "fsw    fa2,  8(%[out])             \n"
                 "flw    fa3, 12(%[a])               \n"
                 "fneg.s fa3, fa3                    \n"
                 "fsw    fa3, 12(%[out])             \n"
                 "addi   %[a],   %[a],   16         \n"
                 "addi   %[out], %[out], 16         \n"
                 : [ a ] "+r"(a), [ out ] "+r"(out)
                 : [ n ] "r"(n_frep)
                 : "fa0", "fa1", "fa2", "fa3", "memory");
#else
    int n_frep = size - 1;
    // LSU0 and LSU1, are dedicated for loads
    uint32_t load_mask = (1 << 0) | (1 << 1);
    // LSU2 is dedicated for stores
    uint32_t store_mask = (1 << 2);
    if (szrt_nof_lsus() >= 3) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
    asm volatile(
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "nop                                \n"
        "frep.o %[n], 5, 0, 0               \n"
        "flw    fa0,  0(%[a])               \n"
        "fneg.s fa0, fa0                    \n"
        "fsw    fa0,  0(%[out])             \n"
        "addi   %[a],   %[a],    4          \n"
        "addi   %[out], %[out],  4          \n"
        : [ a ] "+r"(a), [ out ] "+r"(out)
        : [ n ] "r"(n_frep)
        : "fa0", "memory");
#endif
}

// Tiles the flat size axis across clusters.
// Requires size % n_tiles == 0 and n_tiles % num_clusters == 0.
static inline void eltwise_layer(eltwise_layer_t l) {
    uint32_t data_type_size = l.dtype;
    int is_unary = (l.op == ELTWISE_NEG);

    uint32_t n_tiles_per_cluster = l.n_tiles / snrt_cluster_num();
    uint32_t tile_size = l.size / l.n_tiles;
    uint32_t tile_bytes = tile_size * data_type_size;

    char *local_a = (char *)snrt_l1_next();
    char *local_b = local_a + tile_bytes + sizeof(double);
    char *local_out = local_b + (is_unary ? 0 : tile_bytes + sizeof(double));
    if (is_unary) local_out = local_b;

    char *remote_a = (char *)l.ifmap0;
    char *remote_b = (char *)l.ifmap1;
    char *remote_out = (char *)l.ofmap;

    for (uint32_t ct = 0; ct < n_tiles_per_cluster; ct++) {
        uint32_t tile_idx = snrt_cluster_idx() * n_tiles_per_cluster + ct;
        uint32_t byte_offset = tile_idx * tile_bytes;

        if (snrt_is_dm_core()) {
            snrt_dma_start_1d(local_a, remote_a + byte_offset, tile_bytes);
            if (!is_unary)
                snrt_dma_start_1d(local_b, remote_b + byte_offset, tile_bytes);
            snrt_dma_wait_all();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_compute_core()) {
            uint32_t num_cores = snrt_cluster_compute_core_num();
            uint32_t core_idx = snrt_cluster_core_idx();
            uint32_t per_core = tile_size / num_cores;
            snrt_mcycle();
#if SPLIT_ELTWISE_FNS == 1
            switch (l.op) {
                case ELTWISE_ADD: {
                    eltwise_add_fp32_schnova(
                        (float *)local_a + core_idx * per_core,
                        (float *)local_b + core_idx * per_core,
                        (float *)local_out + core_idx * per_core, per_core);
                }; break;
                case ELTWISE_MUL: {
                    eltwise_mul_fp32_schnova(
                        (float *)local_a + core_idx * per_core,
                        (float *)local_b + core_idx * per_core,
                        (float *)local_out + core_idx * per_core, per_core);
                }; break;
                case ELTWISE_DIV: {
                    eltwise_div_fp32_schnova(
                        (float *)local_a + core_idx * per_core,
                        (float *)local_b + core_idx * per_core,
                        (float *)local_out + core_idx * per_core, per_core);
                }; break;
                case ELTWISE_NEG: {
                    eltwise_neg_fp32_schnova(
                        (float *)local_a + core_idx * per_core,
                        (float *)local_b + core_idx * per_core,
                        (float *)local_out + core_idx * per_core, per_core);
                }; break;
            }
#else
            l.funcptr((float *)local_a + core_idx * per_core,
                      (float *)local_b + core_idx * per_core,
                      (float *)local_out + core_idx * per_core, per_core, l.op);
#endif
            snrt_mcycle();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_dm_core()) {
            snrt_dma_start_1d(remote_out + byte_offset, local_out, tile_bytes);
            snrt_dma_wait_all();
        }
    }

    snrt_global_barrier();
}
