# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0


class RegisterMapTable:
    """State of the Register Mapping Table."""
    def __init__(self):
        # At the beginning the mapping tables are 1:
        self.integer_rmt = {reg: reg for reg in range(32)}
        self.float_rmt = {reg: reg for reg in range(32)}

    def update_entry(self, extras: dict):
        """At dispatch, we update the register mapping table for the destination register."""
        if extras['rd_is_fp']:
            self.float_rmt[extras['rd']] = extras['phy_rd'] 
        else:
            self.integer_rmt[extras['rd']] = extras['phy_rd']

class ProcessorState:
    """Tracks processor state."""

    def __init__(self):
        self._rmt = RegisterMapTable()

    def dispatch(self, extras: dict):
        """Update the register map tables."""
        self._rmt.update_entry(extras)
    
    def rmt_lookup(self, arch_reg: int, is_fp: bool):
        if is_fp:
            return self._rmt.float_rmt[arch_reg]
        else:
            return self._rmt.integer_rmt[arch_reg]

    def rmt_inverse_lookup(self, phys_reg: int, is_fp: bool):
        
        rmt = self.float_rmt if is_fp else self.integer_rmt

        for arch_reg, mapped_phys in rmt.items():
            if mapped_phys == phys_reg:
                return arch_reg

        raise ValueError(f'Physical register not mapped in RMT {phys_reg}')
