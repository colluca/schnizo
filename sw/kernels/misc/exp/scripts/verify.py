#!/usr/bin/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
from datagen import ExpDataGen

from snitch.util.sim.verif_utils import Verifier


class ExpVerifier(Verifier):

    OUTPUT_UIDS = ['b']

    def get_actual_results(self):
        return self.get_output_from_symbol(self.OUTPUT_UIDS[0], 'double')

    def get_expected_results(self):
        a = self.get_input_from_symbol('a', 'double')
        return ExpDataGen().golden_model(a).flatten()

    def check_results(self, *args):
        return super().check_results(*args, rtol=1e-8)


if __name__ == "__main__":
    sys.exit(ExpVerifier().main())
