// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test that if two RS want to writeback into the register file at the same time, the retirements
// are serialized correctly.
// This test requires at least two ALUs to be meaningful.

int main() {
  if (!snrt_is_compute_core()) {
    return 0;
}

  int n_reps = 5;

  uint32_t x_start = 22;
  uint32_t x = 22;
  uint32_t y_start = 44;
  uint32_t y = 44;
  uint32_t inc = 2;

  asm volatile (
      // Wait until all FPU & LSU instructions have retired to have a clean register and
      // pipeline state. Note, the cache is not yet synchronized.
      // We must place the fence in the same asm block as otherwise FPU instructions are placed
      // in between.
      "fmv.x.w t0, fa0   \n"
      "mv      t0, t0\n"
      "fence\n"
      // Code
      "frep.o  %[n_frep], 2, 0, 0\n"
      "addi    %[x], %[x], %[inc]\n"
      "addi    %[y], %[y], %[inc]"
      // Outputs
      : [x]"+r"(x), [y]"+r"(y)
      // Inputs
      : [n_frep]"r"(n_reps-1), [inc]"i"(inc)
      // Clobbers
      : "t0", "memory"
  );

  int err = 0;
  // check the results
  if (x != (x_start + inc*n_reps)) {
    err += 1;
  }
  if (y != (y_start + inc*n_reps)) {
    err += 1;
  }

  if (err != 0) {
    return 1;
  }
  return 0;
}
