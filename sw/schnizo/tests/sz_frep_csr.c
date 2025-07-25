// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"
#include "szrt.h"

// Test if we can read and set the FREP config CSR.

int main() {

  frep_mem_consistency_e mode;
  mode = szrt_frep_mem_consistency();

  if (mode != FREP_MEM_NO_CONSISTENCY) {
    return 1;
  }

  szrt_set_frep_mem_consistency(FREP_MEM_SERIALIZED);
  mode = szrt_frep_mem_consistency();
  if (mode != FREP_MEM_SERIALIZED) {
    return 2;
  }

  szrt_set_frep_mem_consistency(FREP_MEM_NO_CONSISTENCY);
  mode = szrt_frep_mem_consistency();
  if (mode != FREP_MEM_NO_CONSISTENCY) {
    return 3;
  }

  return 0;
}
