#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import torch
from datagen import RmsNormDataGen

from snitch.util.sim.verif_utils import Verifier
from snitch.util.sim.data_utils import ctype_from_precision_t


class RmsNormVerifier(Verifier):

    OUTPUT_UIDS = ['ofmap']

    def __init__(self):
        super().__init__()
        self.layer_struct = {
            'batch_size': 'I',
            'seq_len': 'I',
            'hidden_dim': 'I',
            'n_tiles': 'I',
            'eps': 'f',
            'ifmap_ptr': 'I',
            'ofmap_ptr': 'I',
            'weight_ptr': 'I',
            'dtype': 'I',
            'funcptr': 'I'
        }
        self.layer = self.get_input_from_symbol('layer', self.layer_struct)
        self.batch_size = self.layer['batch_size']
        self.seq_len = self.layer['seq_len']
        self.hidden_dim = self.layer['hidden_dim']
        self.eps = self.layer['eps']
        self.prec = self.layer['dtype']

    def get_actual_results(self):
        return self.get_output_from_symbol('ofmap', ctype_from_precision_t(self.prec))

    def get_expected_results(self):
        ctype = ctype_from_precision_t(self.prec)
        ifmap = self.get_input_from_symbol('ifmap', ctype)
        weight = self.get_input_from_symbol('weight', ctype)
        ifmap = torch.from_numpy(
            ifmap.reshape(self.batch_size, self.seq_len, self.hidden_dim))
        weight = torch.from_numpy(weight)
        return RmsNormDataGen().golden_model(ifmap, weight, self.eps).detach().numpy().flatten()

    def check_results(self, *args):
        return super().check_results(*args, atol=0.001)


if __name__ == "__main__":
    sys.exit(RmsNormVerifier().main())
