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

# AXI splits bursts crossing 4KB address boundaries. To minimize
# the occurrence of these splits the data should be aligned to 4KB
BURST_ALIGNMENT = 4096


class LayernormDataGen(du.DataGen):

    def golden_model(self, ifmap, eps):
        return torch.nn.functional.layer_norm(ifmap, ifmap.shape[-1:], eps=eps)

    def infer_prec(self, funcptr):
        bits = re.search(r'fp(\d+)', funcptr).group(1)
        return f'FP{bits}'

    def validate(self, **kwargs):
        batch_size = kwargs['input_dim']['batch_size']
        seq_len    = kwargs['input_dim']['seq_len']
        embeddings = kwargs['input_dim']['embeddings']
        n_tiles    = kwargs['n_tiles']
        prec_bytes = du.size_from_precision_t(self.infer_prec(kwargs['funcptr']))

        assert seq_len % n_tiles == 0, 'seq_len must be an integer multiple of n_tiles'
        tiled_seq_len = seq_len // n_tiles
        total_size = batch_size * tiled_seq_len * embeddings * prec_bytes
        du.validate_tcdm_footprint(2 * total_size)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        self.validate(**kwargs)

        batch_size = kwargs['input_dim']['batch_size']
        seq_len    = kwargs['input_dim']['seq_len']
        embeddings = kwargs['input_dim']['embeddings']
        eps        = kwargs['eps']
        n_tiles    = kwargs['n_tiles']
        funcptr    = kwargs['funcptr']
        prec       = self.infer_prec(funcptr)

        ctype      = du.ctype_from_precision_t(prec)
        torch_type = du.torch_type_from_precision_t(prec)

        ifmap = torch.randn(batch_size, seq_len, embeddings, dtype=torch_type)
        ofmap = self.golden_model(ifmap, eps).detach()

        ifmap_uid = 'ifmap'
        ofmap_uid = 'ofmap'

        layer_cfg = {
            **kwargs['input_dim'],
            'n_tiles':  n_tiles,
            'funcptr':  funcptr,
            'eps':      eps,
            'ifmap':    ifmap_uid,
            'ofmap':    ofmap_uid,
            'dtype':    prec,
        }

        header += [du.format_array_declaration(f'extern {ctype}', ifmap_uid,
                   ifmap.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_array_declaration(ctype, ofmap_uid,
                   ofmap.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_struct_definition('extern const layernorm_layer_t',
                   'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, ifmap_uid,
                   ifmap, alignment=BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        result_def = du.format_array_definition(ctype, 'golden',
                     du.flatten(ofmap), alignment=BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(LayernormDataGen().main())
