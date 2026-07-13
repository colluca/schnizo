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

OPS = {
    'ELTWISE_ADD': torch.add,
    'ELTWISE_MUL': torch.mul,
    'ELTWISE_DIV': torch.div,
    'ELTWISE_NEG': torch.neg,
}


class EltwiseDataGen(du.DataGen):

    BURST_ALIGNMENT = 4096

    def golden_model(self, a, b, op):
        if op == 'ELTWISE_NEG':
            return OPS[op](a)
        return OPS[op](a, b)

    def infer_prec(self, funcptr):
        bits = re.search(r'fp(\d+)', funcptr).group(1)
        return f'FP{bits}'

    def validate(self, **kwargs):
        size = kwargs['size']
        n_tiles = kwargs['n_tiles']
        prec_bytes = du.size_from_precision_t(self.infer_prec(kwargs['funcptr']))
        assert size % n_tiles == 0, 'size must be an integer multiple of n_tiles'
        tile_bytes = (size // n_tiles) * prec_bytes
        # two inputs + one output per tile (unary uses only one input)
        du.validate_tcdm_footprint(3 * tile_bytes)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        self.validate(**kwargs)

        size = kwargs['size']
        op = kwargs['op']
        n_tiles = kwargs['n_tiles']
        prec = self.infer_prec(kwargs['funcptr'])

        torch_type = du.torch_type_from_precision_t(prec)
        ctype = du.ctype_from_precision_t(prec)

        a = torch.randn(size, dtype=torch_type)
        b = torch.randn(size, dtype=torch_type)
        # Avoid division by zero
        if op == 'ELTWISE_DIV':
            b = b.abs() + 0.1
        out = self.golden_model(a, b, op)

        a_uid = 'ifmap0'
        b_uid = 'ifmap1'
        out_uid = 'ofmap'

        layer_cfg = {
            'size': size,
            'n_tiles': n_tiles,
            'op': op,
            'ifmap0': a_uid,
            'ifmap1': b_uid if op != 'ELTWISE_NEG' else 0,
            'ofmap': out_uid,
            'dtype': prec,
            'funcptr': kwargs['funcptr']
        }

        header += [du.format_array_declaration(f'extern {ctype}', a_uid,
                   a.shape, alignment=self.BURST_ALIGNMENT)]
        if op != 'ELTWISE_NEG':
            header += [du.format_array_declaration(f'extern {ctype}', b_uid,
                       b.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_array_declaration(ctype, out_uid,
                   out.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_struct_definition('eltwise_layer_t', 'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, a_uid,
                   du.flatten(a), alignment=self.BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        if op != 'ELTWISE_NEG':
            header += [du.format_array_definition(ctype, b_uid,
                       du.flatten(b), alignment=self.BURST_ALIGNMENT,
                       section=kwargs.get('section'))]
        result_def = du.format_array_definition(
            ctype, 'golden', du.flatten(out), alignment=self.BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(EltwiseDataGen().main())
