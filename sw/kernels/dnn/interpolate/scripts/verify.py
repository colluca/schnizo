#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import torch
from datagen import InterpolateDataGen

from snitch.util.sim.verif_utils import Verifier
from snitch.util.sim.data_utils import ctype_from_precision_t


class InterpolateVerifier(Verifier):

    OUTPUT_UIDS = ['ofmap']

    def __init__(self):
        super().__init__()
        self.layer_struct = {
            'batch_size': 'I',
            'channels':   'I',
            'in_height':  'I',
            'in_width':   'I',
            'out_height': 'I',
            'out_width':  'I',
            'ifmap_ptr':  'I',
            'ofmap_ptr':  'I',
            'dtype':      'I'
        }
        self.layer      = self.get_input_from_symbol('layer', self.layer_struct)
        self.batch_size = self.layer['batch_size']
        self.channels   = self.layer['channels']
        self.in_height  = self.layer['in_height']
        self.in_width   = self.layer['in_width']
        self.out_height = self.layer['out_height']
        self.out_width  = self.layer['out_width']
        self.prec       = self.layer['dtype']

    def get_actual_results(self):
        return self.get_output_from_symbol('ofmap', ctype_from_precision_t(self.prec))

    def get_expected_results(self):
        ctype = ctype_from_precision_t(self.prec)
        ifmap = self.get_input_from_symbol('ifmap', ctype)
        ifmap = torch.from_numpy(
            ifmap.reshape(self.batch_size, self.channels, self.in_height, self.in_width))
        return InterpolateDataGen().golden_model(
            ifmap, self.out_height, self.out_width).detach().numpy().flatten()

    def check_results(self, *args):
        return super().check_results(*args, atol=1e-5)


if __name__ == "__main__":
    sys.exit(InterpolateVerifier().main())
