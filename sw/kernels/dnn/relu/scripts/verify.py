#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import torch
from datagen import ReluDataGen

from snitch.util.sim.verif_utils import Verifier
from snitch.util.sim.data_utils import ctype_from_precision_t


class ReluVerifier(Verifier):

    OUTPUT_UIDS = ['ofmap']

    def __init__(self):
        super().__init__()
        self.layer_struct = {
            'size': 'I',
            'n_tiles': 'I',
            'ifmap_ptr': 'I',
            'ofmap_ptr': 'I',
            'dtype': 'I',
            'funcptr': 'I'
        }
        self.layer = self.get_input_from_symbol('layer', self.layer_struct)
        self.prec = self.layer['dtype']

    def get_actual_results(self):
        return self.get_output_from_symbol('ofmap', ctype_from_precision_t(self.prec))

    def get_expected_results(self):
        ctype = ctype_from_precision_t(self.prec)
        ifmap = torch.from_numpy(self.get_input_from_symbol('ifmap', ctype))
        return ReluDataGen().golden_model(ifmap).detach().numpy().flatten()

    def check_results(self, *args):
        return super().check_results(*args, atol=1e-6)


if __name__ == "__main__":
    sys.exit(ReluVerifier().main())
