#!/usr/bin/env python3
# Copyright 2020 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import torch
from datagen import BatchnormDataGen

from snitch.util.sim.verif_utils import Verifier
from snitch.util.sim.data_utils import ctype_from_precision_t


class BatchnormVerifier(Verifier):

    OUTPUT_UIDS = ['ofmap']

    def __init__(self):
        super().__init__()
        self.layer_struct = {
            'CI':       'I',
            'IH':       'I',
            'IW':       'I',
            'funcptr':  'I',
            'ifmap_ptr': 'I',
            'gamma_ptr': 'I',
            'beta_ptr':  'I',
            'ofmap_ptr': 'I',
            'dtype':    'I'
        }
        self.layer    = self.get_input_from_symbol('layer', self.layer_struct)
        self.CI       = self.layer['CI']
        self.IH       = self.layer['IH']
        self.IW       = self.layer['IW']
        self.prec     = self.layer['dtype']

    def get_actual_results(self):
        return self.get_output_from_symbol('ofmap', ctype_from_precision_t(self.prec))

    def get_expected_results(self):
        ctype    = ctype_from_precision_t(self.prec)
        n_pixels = self.IH * self.IW
        ifmap = torch.tensor(self.get_input_from_symbol('ifmap',  ctype).reshape(self.CI, n_pixels))
        gamma = torch.tensor(self.get_input_from_symbol('gamma_', ctype))
        beta  = torch.tensor(self.get_input_from_symbol('beta',   ctype))
        return BatchnormDataGen().golden_model(ifmap, gamma, beta).flatten()

    def check_results(self, *args):
        return super().check_results(*args, atol=1e-4)


if __name__ == "__main__":
    sys.exit(BatchnormVerifier().main())
