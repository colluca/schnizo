#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import re
import sys
import torch

import snitch.util.sim.data_utils as du

torch.manual_seed(42)


class RmsNormDataGen(du.DataGen):

    # AXI splits bursts crossing 4KB address boundaries. To minimize
    # the occurrence of these splits the data should be aligned to 4KB
    BURST_ALIGNMENT = 4096

    def golden_model(self, ifmap, weight, eps):
        return torch.nn.functional.rms_norm(ifmap, ifmap.shape[-1:], weight, eps)

    def infer_prec(self, funcptr):
        bits = re.search(r'fp(\d+)', funcptr).group(1)
        return f'FP{bits}'

    def validate(self, **kwargs):
        batch_size = kwargs['input_dim']['batch_size']
        seq_len = kwargs['input_dim']['seq_len']
        hidden_dim = kwargs['input_dim']['hidden_dim']
        n_tiles = kwargs['n_tiles']
        prec_bytes = du.size_from_precision_t(self.infer_prec(kwargs['funcptr']))

        assert seq_len % n_tiles == 0, 'seq_len must be an integer multiple of n_tiles'
        tile_seq_len = seq_len // n_tiles
        tile_size = batch_size * tile_seq_len * hidden_dim * prec_bytes
        weight_size = hidden_dim * prec_bytes
        du.validate_tcdm_footprint(2 * tile_size + weight_size)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        self.validate(**kwargs)

        batch_size = kwargs['input_dim']['batch_size']
        seq_len = kwargs['input_dim']['seq_len']
        hidden_dim = kwargs['input_dim']['hidden_dim']
        eps = kwargs['eps']
        n_tiles = kwargs['n_tiles']
        prec = self.infer_prec(kwargs['funcptr'])

        torch_type = du.torch_type_from_precision_t(prec)
        ctype = du.ctype_from_precision_t(prec)

        ifmap = torch.randn(batch_size, seq_len, hidden_dim, dtype=torch_type)
        weight = torch.ones(hidden_dim, dtype=torch_type)
        ofmap = self.golden_model(ifmap, weight, eps).detach()

        ifmap_uid = 'ifmap'
        ofmap_uid = 'ofmap'
        weight_uid = 'weight'

        layer_cfg = {
            **kwargs['input_dim'],
            'n_tiles': n_tiles,
            'eps': eps,
            'ifmap': ifmap_uid,
            'ofmap': ofmap_uid,
            'weight': weight_uid,
            'dtype': prec,
            'funcptr': kwargs['funcptr']
        }

        header += [du.format_array_declaration(f'extern {ctype}', ifmap_uid,
                   ifmap.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_array_declaration(ctype, ofmap_uid,
                   ofmap.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_array_declaration(f'extern {ctype}', weight_uid,
                   weight.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_struct_definition('extern const rms_norm_layer_t', 'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, ifmap_uid,
                   ifmap, alignment=self.BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        header += [du.format_array_definition(ctype, weight_uid,
                   weight, alignment=self.BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        result_def = du.format_array_definition(ctype, 'golden',
                                                du.flatten(ofmap), alignment=self.BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(RmsNormDataGen().main())
