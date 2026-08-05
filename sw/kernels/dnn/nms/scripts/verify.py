#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import torch
from datagen import NmsDataGen

from snitch.util.sim.verif_utils import Verifier
from snitch.util.sim.data_utils import ctype_from_precision_t


class NmsVerifier(Verifier):

    OUTPUT_UIDS = ['keep']

    def __init__(self):
        super().__init__()
        self.layer_struct = {
            'num_boxes':     'I',
            'iou_threshold': 'f',
            'boxes_ptr':     'I',
            'scores_ptr':    'I',
            'keep_ptr':      'I',
            'dtype':         'I'
        }
        self.layer = self.get_input_from_symbol('layer', self.layer_struct)
        self.num_boxes = self.layer['num_boxes']
        self.iou_threshold = self.layer['iou_threshold']
        self.prec = self.layer['dtype']

    def get_actual_results(self):
        return self.get_output_from_symbol('keep', 'uint32_t')

    def get_expected_results(self):
        ctype = ctype_from_precision_t(self.prec)
        boxes = torch.from_numpy(
            self.get_input_from_symbol('boxes', ctype).reshape(self.num_boxes, 4))
        scores = torch.from_numpy(
            self.get_input_from_symbol('scores', ctype))
        return NmsDataGen().golden_model(
            boxes, scores, self.iou_threshold).numpy().flatten()

    def check_results(self, *args):
        return super().check_results(*args, atol=0)


if __name__ == "__main__":
    sys.exit(NmsVerifier().main())
