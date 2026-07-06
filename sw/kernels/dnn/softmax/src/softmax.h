// Copyright 2020 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "math.h"
#include "snrt.h"
#include "blas.h"
#include "../../misc/exp/src/vexpf.h"

#ifndef SOFTMAX_FUNC_PTR
#define SOFTMAX_FUNC_PTR softmax_fp32_schnizo
#endif

/**
 * @struct softmax_layer_struct
 * @brief This structure contains all parameters necessary
 *       for computing the Softmax activation function
 * @var softmax_layer_struct::batch_size
 * Size of each input sample
 * @var softmax_layer_struct::seq_len
 * Size of each output sample
 * @var softmax_layer_struct::input_samples
 * Number of input samples
 * @var softmax_layer_struct::reduce_dim
 * Along which dimension to reduce
 * @var softmax_layer_struct::ifmap
 * Pointer to input feature map
 * @var softmax_layer_struct::ofmap
 * Pointer to output feature map
 */
typedef struct softmax_layer_struct {
    uint32_t batch_size;
    uint32_t seq_len;
    uint32_t input_samples;
    int32_t reduce_dim;
    float *ifmap;
    float *ofmap;
    precision_t dtype;
} softmax_layer_t;


/**
 * Implementation of the SoftMax layer.
 */
static inline void softmax_fp32(float *input, float *output, int32_t ldI,
                                int32_t batch_offset, int32_t batch_size,
                                int32_t seq_len, int32_t input_samples) {
    float max_core = 0.0;  // max value of the current core
    float sum = 0.0;       // sum of the exp values of the current core

    for (int32_t b = 0; b < batch_size; b++) {
        for (int32_t s = 0; s < seq_len; s++) {
            max_core = -INFINITY;
            sum = 0.0;

            for (int32_t i = 0; i < input_samples; i++) {
                if (input[b * batch_offset + s * ldI + i] > max_core) {
                    max_core = input[b * batch_offset + s * ldI + i];
                }
            }

            // compute the shifted value of the current row
            for (int32_t i = 0; i < input_samples; i++) {
                output[b * batch_offset + s * ldI + i] =
                    expf(input[b * batch_offset + s * ldI + i] - max_core);
                sum += output[b * batch_offset + s * ldI + i];
            }

            // compute the softmax value of the current row
            for (int32_t i = 0; i < input_samples; i++) {
                output[b * batch_offset + s * ldI + i] /= sum;
            }
        }
    }

    snrt_cluster_hw_barrier();
}


static inline void softmax_fp32_schnizo(float *input, float *output,
                                        int32_t batch_size, int32_t seq_len,
                                        int32_t input_samples, 
                                        uint32_t core_id, uint32_t core_num) {
    float max_core;
    float sum;
    int32_t batch_offset = seq_len * input_samples;

    for (int32_t b = 0; b < batch_size; b++) {
        // Grid-stride loop: naturally handles non-multiples and seq_len < core_num
        for (int32_t s = core_id; s < seq_len; s += core_num) {
            float *row_in  = &input [b * batch_offset + s * input_samples];
            float *row_out = &output[b * batch_offset + s * input_samples];

            // find max (compute-bound, fmax.s: 4 accumulators for both frep.i/o)
            {
                float m0 = -INFINITY, m1 = -INFINITY;
                float m2 = -INFINITY, m3 = -INFINITY;
                float *ptr = row_in;
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP " %[n], 9, 0, 0              \n"
                    "flw    fa0,  0(%[ptr])            \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fmax.s %[m0], %[m0], fa0          \n"
                    "fmax.s %[m1], %[m1], fa1          \n"
                    "fmax.s %[m2], %[m2], fa2          \n"
                    "fmax.s %[m3], %[m3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
                    // clang-format on
                    : [ m0 ] "+f"(m0), [ m1 ] "+f"(m1),
                      [ m2 ] "+f"(m2), [ m3 ] "+f"(m3), [ ptr ] "+r"(ptr)
                    : [ n ] "r"(n_frep)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
                m0 = fmaxf(m0, m1);
                m2 = fmaxf(m2, m3);
                max_core = fmaxf(m0, m2);
            }

            // shift: row_out[i] = row_in[i] - max_core  (load-use-store)
            {
                float *in_ptr = row_in, *out_ptr = row_out;
#ifdef FORCE_HW_LOOP
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    "frep.i %[n], 14, 0, 0           \n"
                    "flw    fa0,  0(%[in])            \n"
                    "flw    fa1,  4(%[in])            \n"
                    "flw    fa2,  8(%[in])            \n"
                    "flw    fa3, 12(%[in])            \n"
                    "fsub.s fa0, fa0, %[max]          \n"
                    "fsub.s fa1, fa1, %[max]          \n"
                    "fsub.s fa2, fa2, %[max]          \n"
                    "fsub.s fa3, fa3, %[max]          \n"
                    "fsw    fa0,  0(%[out])           \n"
                    "fsw    fa1,  4(%[out])           \n"
                    "fsw    fa2,  8(%[out])           \n"
                    "fsw    fa3, 12(%[out])           \n"
                    "addi   %[in],  %[in],  16        \n"
                    "addi   %[out], %[out], 16        \n"
                    // clang-format on
                    : [ in ] "+r"(in_ptr), [ out ] "+r"(out_ptr)
                    : [ n ] "r"(n_frep), [ max ] "f"(max_core)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
#else
                int n_frep = input_samples - 1;
                asm volatile(
                    // clang-format off
                    "frep.o %[n], 5, 0, 0              \n"
                    "flw    fa0,  0(%[in])             \n"
                    "fsub.s fa0, fa0, %[max]           \n"
                    "fsw    fa0,  0(%[out])            \n"
                    "addi   %[in],  %[in],  4          \n"
                    "addi   %[out], %[out], 4          \n"
                    // clang-format on
                    : [ in ] "+r"(in_ptr), [ out ] "+r"(out_ptr)
                    : [ n ] "r"(n_frep), [ max ] "f"(max_core)
                    : "fa0", "memory"
                );
#endif
            }

            // in-place vectorized exp
            vexpf_fp32_schnizo(row_out, row_out, input_samples);

            // sum accumulation (compute-bound: 4 accumulators for both frep.i/o)
            {
                float sum1 = 0.0f, sum2 = 0.0f, sum3 = 0.0f, sum4 = 0.0f;
                float *ptr = row_out;
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP " %[n], 9, 0, 0              \n"
                    "flw    fa0,  0(%[ptr])            \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fadd.s %[s0], %[s0], fa0          \n"
                    "fadd.s %[s1], %[s1], fa1          \n"
                    "fadd.s %[s2], %[s2], fa2          \n"
                    "fadd.s %[s3], %[s3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
                    // clang-format on
                    : [ s0 ] "+f"(sum1), [ s1 ] "+f"(sum2),
                      [ s2 ] "+f"(sum3), [ s3 ] "+f"(sum4), [ ptr ] "+r"(ptr)
                    : [ n ] "r"(n_frep)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
                sum1 += sum2;
                sum3 += sum4;
                sum = sum1 + sum3;
            }

            // in-place normalization
            scal_fp32_schnizo(1.0f / sum, row_out, input_samples);
        }
    }

    snrt_cluster_hw_barrier();
}

static inline void softmax_fp32_schnova(float *input, float *output,
                                        int32_t batch_size, int32_t seq_len,
                                        int32_t input_samples, 
                                        uint32_t core_id, uint32_t core_num) {
    float max_core;
    float sum;
    int32_t batch_offset = seq_len * input_samples;
    if (szrt_nof_lsus() >= 3) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en((1 << 0) | (1 << 1));
        szrt_set_frep_lsu_store_en((1 << 2));
    } else if (szrt_nof_lsus() == 2) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en((1 << 0));
        szrt_set_frep_lsu_store_en((1 << 1)); 
    }
    for (int32_t b = 0; b < batch_size; b++) {
        // Grid-stride loop: naturally handles non-multiples and seq_len < core_num
        for (int32_t s = core_id; s < seq_len; s += core_num) {
            float *row_in  = &input [b * batch_offset + s * input_samples];
            float *row_out = &output[b * batch_offset + s * input_samples];

            // find max (compute-bound, fmax.s: 4 accumulators for both frep.i/o)
            {
                float m0 = -INFINITY, m1 = -INFINITY;
                float m2 = -INFINITY, m3 = -INFINITY;
                float *ptr = row_in;
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP " %[n], 9, 0, 0              \n"
#ifdef BALANCE_INSTRUCTION_MIX
                    "flw    fa0,  0(%[ptr])            \n"
                    "fmax.s %[m0], %[m0], fa0          \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "fmax.s %[m1], %[m1], fa1          \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "fmax.s %[m2], %[m2], fa2          \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fmax.s %[m3], %[m3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
#else
                    "flw    fa0,  0(%[ptr])            \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fmax.s %[m0], %[m0], fa0          \n"
                    "fmax.s %[m1], %[m1], fa1          \n"
                    "fmax.s %[m2], %[m2], fa2          \n"
                    "fmax.s %[m3], %[m3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
#endif
                    // clang-format on
                    : [ m0 ] "+f"(m0), [ m1 ] "+f"(m1),
                      [ m2 ] "+f"(m2), [ m3 ] "+f"(m3), [ ptr ] "+r"(ptr)
                    : [ n ] "r"(n_frep)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
                m0 = fmaxf(m0, m1);
                m2 = fmaxf(m2, m3);
                max_core = fmaxf(m0, m2);
            }

            // shift: row_out[i] = row_in[i] - max_core  (load-use-store)
            {
                float *in_ptr = row_in, *out_ptr = row_out;
#ifdef UNROLL
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP  " %[n], 14, 0, 0           \n"
                    "flw    fa0,  0(%[in])            \n"
                    "flw    fa1,  4(%[in])            \n"
                    "flw    fa2,  8(%[in])            \n"
                    "flw    fa3, 12(%[in])            \n"
                    "fsub.s fa0, fa0, %[max]          \n"
                    "fsub.s fa1, fa1, %[max]          \n"
                    "fsub.s fa2, fa2, %[max]          \n"
                    "fsub.s fa3, fa3, %[max]          \n"
                    "fsw    fa0,  0(%[out])           \n"
                    "fsw    fa1,  4(%[out])           \n"
                    "fsw    fa2,  8(%[out])           \n"
                    "fsw    fa3, 12(%[out])           \n"
                    "addi   %[in],  %[in],  16        \n"
                    "addi   %[out], %[out], 16        \n"
                    // clang-format on
                    : [ in ] "+r"(in_ptr), [ out ] "+r"(out_ptr)
                    : [ n ] "r"(n_frep), [ max ] "f"(max_core)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
#elif defined(BALANCE_INSTRUCTION_MIX) && defined(UNROLL)
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP  " %[n], 14, 0, 0           \n"
                    "flw    fa0,  0(%[in])            \n"
                    "fsub.s fa0, fa0, %[max]          \n"
                    "fsw    fa0,  0(%[out])           \n"
                    "flw    fa1,  4(%[in])            \n"
                    "fsub.s fa1, fa1, %[max]          \n"
                    "fsw    fa1,  4(%[out])           \n"
                    "flw    fa2,  8(%[in])            \n"
                    "fsub.s fa2, fa2, %[max]          \n"
                    "fsw    fa2,  8(%[out])           \n"
                    "flw    fa3, 12(%[in])            \n"
                    "fsub.s fa3, fa3, %[max]          \n"
                    "fsw    fa3, 12(%[out])           \n"
                    "addi   %[in],  %[in],  16        \n"
                    "addi   %[out], %[out], 16        \n"
                    // clang-format on
                    : [ in ] "+r"(in_ptr), [ out ] "+r"(out_ptr)
                    : [ n ] "r"(n_frep), [ max ] "f"(max_core)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
#else
                int n_frep = input_samples - 1;
                asm volatile(
                    // clang-format off
                    "frep.o %[n], 5, 0, 0              \n"
                    "flw    fa0,  0(%[in])             \n"
                    "fsub.s fa0, fa0, %[max]           \n"
                    "fsw    fa0,  0(%[out])            \n"
                    "addi   %[in],  %[in],  4          \n"
                    "addi   %[out], %[out], 4          \n"
                    // clang-format on
                    : [ in ] "+r"(in_ptr), [ out ] "+r"(out_ptr)
                    : [ n ] "r"(n_frep), [ max ] "f"(max_core)
                    : "fa0", "memory"
                );
#endif
            }

            // in-place vectorized exp
            vexpf_fp32_schnova(row_out, row_out, input_samples);

            // sum accumulation (compute-bound: 4 accumulators for both frep.i/o)
            {
                float sum1 = 0.0f, sum2 = 0.0f, sum3 = 0.0f, sum4 = 0.0f;
                float *ptr = row_out;
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP " %[n], 9, 0, 0              \n"
#ifdef BALANCE_INSTRUCTION_MIX
                    "flw    fa0,  0(%[ptr])            \n"
                    "fadd.s %[s0], %[s0], fa0          \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "fadd.s %[s1], %[s1], fa1          \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "fadd.s %[s2], %[s2], fa2          \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fadd.s %[s3], %[s3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
#else
                    "flw    fa0,  0(%[ptr])            \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fadd.s %[s0], %[s0], fa0          \n"
                    "fadd.s %[s1], %[s1], fa1          \n"
                    "fadd.s %[s2], %[s2], fa2          \n"
                    "fadd.s %[s3], %[s3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
#endif
                    // clang-format on
                    : [ s0 ] "+f"(sum1), [ s1 ] "+f"(sum2),
                      [ s2 ] "+f"(sum3), [ s3 ] "+f"(sum4), [ ptr ] "+r"(ptr)
                    : [ n ] "r"(n_frep)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
                sum1 += sum2;
                sum3 += sum4;
                sum = sum1 + sum3;
            }
            asm volatile( 
                "nop            \n"
                "nop            \n"
                "nop            \n"
                :::          
            );
            // in-place normalization
            scal_fp32_schnizo(1.0f / sum, row_out, input_samples);
        }
    }

    snrt_cluster_hw_barrier();
}

static inline void softmax_layer(softmax_layer_t const l) {
    uint32_t compute_num = snrt_cluster_compute_core_num();
    uint32_t compute_id  = snrt_cluster_core_idx(); 

    uint32_t ifmap_size = l.batch_size * l.seq_len * l.input_samples;
    uint32_t ofmap_size = ifmap_size;

    float *ptr = (float *)snrt_l1_next();
    float *ifmap = ptr;
    ptr += ifmap_size;
    float *ofmap = ptr;
    ptr += ofmap_size;

    if (snrt_is_dm_core()) {
        snrt_dma_start_2d(
            ifmap,                            // dst
            l.ifmap,                          // src
            l.input_samples * sizeof(float),  // size of 1 contiguous row
            l.input_samples * sizeof(float),  // dst stride to next row
            l.input_samples * sizeof(float),  // src stride to next row
            l.batch_size * l.seq_len          // total rows to transfer
        );

        snrt_dma_wait_all();
    }

    snrt_cluster_hw_barrier();

    // Parallel Compute Loop execution
    if (snrt_is_compute_core()) {
        snrt_mcycle();
        // Pass base pointers and let the inner grid-stride loop balance the work
        SOFTMAX_FUNC_PTR(ifmap, ofmap, l.batch_size, l.seq_len, 
                             l.input_samples, compute_id, compute_num);
        snrt_mcycle();
    } else {
        snrt_cluster_hw_barrier();
    }

    if (snrt_is_dm_core()) {
        snrt_dma_start_2d(
            l.ofmap,                          // dst
            ofmap,                            // src
            l.input_samples * sizeof(float),  // size of 1 contiguous row
            l.input_samples * sizeof(float),  // dst stride to next row
            l.input_samples * sizeof(float),  // src stride to next row
            l.batch_size * l.seq_len          // total rows to transfer
        );

        snrt_dma_wait_all();
    }

    snrt_global_barrier();
}