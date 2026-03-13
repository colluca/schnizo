# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0


class ReservationStationSlot:
    """State of a single Reservation Station Slot during a FREP loop."""

    SNAPSHOT_KEYS = frozenset({'instr_data', 'pc_q', 'rs1', 'rs2', 'rd', 'rs1_is_fp', 'rs2_is_fp'})

    def __init__(self):
        self.snapshot = {}
        self.dispatch_iter = 0
        self.rescap_iter = -1

    def lcp2_dispatch(self, extras: dict):
        """Save instruction snapshot and advance dispatch iteration (called at LCP2)."""
        self.snapshot = {k: extras[k] for k in self.SNAPSHOT_KEYS}
        self.dispatch_iter += 1
        extras['iteration'] = self.dispatch_iter

    def lep_dispatch(self, extras: dict):
        """Advance dispatch iteration and restore instruction state (called at LEP)."""
        self.dispatch_iter += 1
        extras.update(self.snapshot)
        extras['iteration'] = self.dispatch_iter

    def capture_result(self, extras: dict):
        """Advance rescap iteration and inject it into extras (called at RESCAP)."""
        self.rescap_iter += 1
        extras['iteration'] = self.rescap_iter
        if self.rescap_iter > self.dispatch_iter:
            raise Exception("RESCAP: rescap_iter overtook dispatch_iter")


class ProcessorState:
    """Tracks processor state (active RSS slots) during a FREP loop."""

    def __init__(self):
        self._slots = {}

    def lcp1_dispatch(self, slot_id: str):
        """Create a fresh RSS slot (called at LCP1)."""
        self._slots[slot_id] = ReservationStationSlot()

    def lcp2_dispatch(self, slot_id: str, extras: dict):
        """Save instruction snapshot for slot_id (called at LCP2)."""
        self._slots[slot_id].lcp2_dispatch(extras)

    def lep_dispatch(self, slot_id: str, extras: dict):
        """Advance iteration and restore instruction state (called at LEP)."""
        self._slots[slot_id].lep_dispatch(extras)

    def capture_result(self, slot_id: str, extras: dict):
        """Advance rescap iteration for slot_id (called at RESCAP)."""
        self._slots[slot_id].capture_result(extras)
