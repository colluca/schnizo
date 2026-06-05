#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import torch
from datagen import EltwiseDataGen

from snitch.util.sim.verif_utils import Verifier
from snitch.util.sim.data_utils import ctype_from_precision_t

OP_NAMES = {0: 'ELTWISE_ADD', 1: 'ELTWISE_MUL', 2: 'ELTWISE_DIV', 3: 'ELTWISE_NEG'}


class EltwiseVerifier(Verifier):

    OUTPUT_UIDS = ['ofmap']

    def __init__(self):
        super().__init__()
        self.layer_struct = {
            'size': 'I',
            'n_tiles': 'I',
            'op': 'I',
            'ifmap0_ptr': 'I',
            'ifmap1_ptr': 'I',
            'ofmap_ptr': 'I',
            'dtype': 'I',
            'funcptr': 'I'
        }
        self.layer = self.get_input_from_symbol('layer', self.layer_struct)
        self.prec = self.layer['dtype']
        self.op = OP_NAMES[self.layer['op']]

    def get_actual_results(self):
        return self.get_output_from_symbol('ofmap', ctype_from_precision_t(self.prec))

    def get_expected_results(self):
        ctype = ctype_from_precision_t(self.prec)
        a = torch.from_numpy(self.get_input_from_symbol('ifmap0', ctype))
        b = None if self.op == 'ELTWISE_NEG' else \
            torch.from_numpy(self.get_input_from_symbol('ifmap1', ctype))
        return EltwiseDataGen().golden_model(a, b, self.op).detach().numpy().flatten()

    def check_results(self, *args):
        return super().check_results(*args, rtol=1e-5)


if __name__ == "__main__":
    sys.exit(EltwiseVerifier().main())
