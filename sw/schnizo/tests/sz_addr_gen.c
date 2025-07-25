// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test that we can generate a load & store address stream.
// We copy the array x to the array z.

#define NofElements 16

uint32_t x[NofElements] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
uint32_t z[NofElements] = {0};

int main() {
  if (!snrt_is_compute_core()) {
    return 0;
  }

  int inc = sizeof(uint32_t);
  int copiedElements = 5;

  uint32_t *x_addr = &x[0];
  uint32_t *z_addr = &z[0];

  asm volatile (
    // Code
    "frep.o  %[n_frep], 4, 0, 0\n"
    "lw      t0,    0(%[xa])       \n"
    "sw      t0,    0(%[za])       \n"
    "addi    %[xa], %[xa],   %[inc]\n"
    "addi    %[za], %[za],   %[inc]"
    // Outputs
    : [xa]"+r"(x_addr), [za]"+r"(z_addr)
    // Inputs
    : [n_frep]"r"(copiedElements-1), [inc]"i"(inc)
    // Clobbers
    : "t0", "memory"
  );

  // check the copy
  uint32_t err = 0;
  for (int i = 0; i < copiedElements; i++) {
    err += (x[i] - z[i]);
  }

  if (err != 0) {
    return 1;
  }
  return 0;
}