#!/usr/bin/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stefan Odermatt <soderma@student.ethz.ch>

import sys
import numpy as np 

from snitch.util.sim.verif_utils import Verifier


class MontecarloVerifier(Verifier):

    OUTPUT_UIDS = ['actual_result', 'golden_result']

    def get_actual_results(self):
        return self.get_output_from_symbol(self.OUTPUT_UIDS[0], 'double')

    def get_expected_results(self):
        return self.get_output_from_symbol(self.OUTPUT_UIDS[1], 'double')

    def check_results(self, *args):
        n_samples = self.get_input_from_symbol('nof_samples', 'uint32_t')

        dynamic_atol = 3.0 / np.sqrt(n_samples)
        return super().check_results(*args, atol=dynamic_atol)

if __name__ == "__main__":
    sys.exit(MontecarloVerifier().main())