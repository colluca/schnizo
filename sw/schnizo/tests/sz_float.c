// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

// Very simple test to verify latency of FPU operation

#include "snrt.h"

int main() {
    register double a asm("ft0") = 3.14;
    register double b asm("ft1") = 2.7;

    asm volatile (
        "fmv.x.w t0, fa0\n"
        "mv      t0, t0 \n"
        "fadd.d  ft0, ft0, ft1\n"
        :
        :
        : "t0", "ft0", "ft1", "memory"
    );
}