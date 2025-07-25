// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test that we can generate a load & store address stream.
// We copy the array x to the array z.

#define NofElements 16

double x[NofElements] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
double y[NofElements] = {16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1};
double z[NofElements] = {0};

int main() {
  if (!snrt_is_compute_core()) {
    return 0;
  }

  int inc = sizeof(double);
  int summedElements = 10;

  double *x_addr = &x[0];
  double *y_addr = &y[0];
  double *z_addr = &z[0];

  asm volatile (
    // Code
    "frep.o  %[n_frep], 7, 0, 0\n"
    "fld     ft0,   0(%[xa])       \n"
    "fld     ft1,   0(%[ya])       \n"
    "fadd.d  ft2,   ft0,     ft1   \n"
    "fsd     ft2,   0(%[za])       \n"
    "addi    %[xa], %[xa],   %[inc]\n"
    "addi    %[ya], %[ya],   %[inc]\n"
    "addi    %[za], %[za],   %[inc]"
    // Outputs
    : [xa]"+r"(x_addr), [ya]"+r"(y_addr), [za]"+r"(z_addr)
    // Inputs
    : [n_frep]"r"(summedElements-1), [inc]"i"(inc)
    // Clobbers
    : "ft0", "ft1", "ft2", "memory"
  );

  // check the sum
  int err = 0;
  for (int i = 0; i < summedElements; i++) {
    if (z[i] - (x[i] + y[i]) > 0.0001 ) {
      err += 1;
    }
  }

    return err;
}