// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Schnova core-wide constants and types.
package schnova_pkg;

  //---------------------------
  // Core global constants
  //---------------------------
  // We use double the amount of physical registers as the amount of
  // of architectural registers.
  localparam int unsigned PhysRegAddrSize = 6;

  localparam int unsigned NofRobEntries = 32;

endpackage
