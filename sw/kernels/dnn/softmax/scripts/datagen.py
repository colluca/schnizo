#!/usr/bin/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Tim Fischer <fischeti@iis.ee.ethz.ch>
# Viviane Potocnik <vivianep@iis.ee.ethz.ch>
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import re
import sys
import torch

import snitch.util.sim.data_utils as du

torch.manual_seed(42)

BURST_ALIGNMENT = 4096


class SoftmaxDataGen(du.DataGen):

    def golden_model(self, ifmap, axis):
        return torch.nn.functional.softmax(ifmap, dim=axis)

    def infer_prec(self, funcptr):
        bits = re.search(r'fp(\d+)', funcptr).group(1)
        return f'FP{bits}'

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        batch_size = kwargs['input_dim']['batch_size']
        seq_len = kwargs['input_dim']['seq_len']
        input_samples = kwargs['input_dim']['input_samples']
        reduce_dim = kwargs['reduce_dim']
        prec = self.infer_prec(kwargs['funcptr'])

        torch_type = du.torch_type_from_precision_t(prec)
        ctype = du.ctype_from_precision_t(prec)

        ifmap = torch.randn(batch_size, seq_len, input_samples, dtype=torch_type)
        ofmap = self.golden_model(ifmap, reduce_dim).detach()

        ifmap_flat = du.flatten(ifmap)
        ofmap_flat = du.flatten(ofmap)

        ifmap_uid = 'ifmap'
        ofmap_uid = 'ofmap'

        layer_cfg = {
            **kwargs['input_dim'],
            'reduce_dim': reduce_dim,
            'ifmap': ifmap_uid,
            'ofmap': ofmap_uid,
            'dtype': prec
        }

        header += [du.format_array_declaration(f'extern {ctype}', ifmap_uid,
                   ifmap_flat.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_array_declaration(ctype, ofmap_uid,
                   ofmap_flat.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_struct_definition('extern const softmax_layer_t',
                   'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, ifmap_uid,
                   ifmap_flat, alignment=BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        result_def = du.format_array_definition(ctype, 'golden',
                                                ofmap_flat, alignment=BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(SoftmaxDataGen().main())
