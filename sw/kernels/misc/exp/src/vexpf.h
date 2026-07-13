// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Luca Colagrande <colluca@iis.ee.ethz.ch>

#define IMPL_NAIVE 0
#define IMPL_BASELINE 1
#define IMPL_OPTIMIZED 2
#define IMPL_OPTIMIZED_V2 3
#define IMPL_SCHNIZO 4

#ifndef IMPL
#define IMPL IMPL_SCHNIZO
#endif

#if IMPL == IMPL_NAIVE
#define FUNC_PTR vexpf_naive
#elif IMPL == IMPL_BASELINE
#define FUNC_PTR vexpf_baseline
#elif IMPL == IMPL_OPTIMIZED
#define FUNC_PTR vexpf_optimized
#elif IMPL == IMPL_OPTIMIZED_V2
#define FUNC_PTR vexpf_optimized_v2
#elif IMPL == IMPL_SCHNIZO
#define FUNC_PTR vexpf_schnizo
#endif

#define ALLOCATE_BUFFER(type, size) \
    (type *)snrt_l1_alloc_cluster_local(size * sizeof(type), sizeof(type))

#include "vexpf_const.h"

#include "vexpf_baseline.h"
#include "vexpf_naive.h"
#include "vexpf_optimized.h"
#include "vexpf_optimized_v2.h"
#include "vexpf_schnizo.h"
static inline void vexpf_kernel(double *a, double *b, uint32_t len,
                                uint32_t batch_size) {
    snrt_mcycle();
    FUNC_PTR(a, b, len, batch_size);
    snrt_mcycle();
}