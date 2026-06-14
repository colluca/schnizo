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


class SiluDataGen(du.DataGen):

    BURST_ALIGNMENT = 4096

    def golden_model(self, ifmap):
        return torch.nn.functional.silu(ifmap)

    def infer_prec(self, funcptr):
        bits = re.search(r'fp(\d+)', funcptr).group(1)
        return f'FP{bits}'

    def validate(self, **kwargs):
        size = kwargs['size']
        n_tiles = kwargs['n_tiles']
        prec = du.size_from_precision_t(self.infer_prec(kwargs['funcptr']))
        assert size % n_tiles == 0, 'size must be an integer multiple of n_tiles'
        tile_bytes = (size // n_tiles) * prec
        du.validate_tcdm_footprint(2 * tile_bytes)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        self.validate(**kwargs)

        size = kwargs['size']
        n_tiles = kwargs['n_tiles']
        funcptr = kwargs['funcptr']
        prec = self.infer_prec(funcptr)

        torch_type = du.torch_type_from_precision_t(prec)
        ctype = du.ctype_from_precision_t(prec)

        ifmap = torch.randn(size, dtype=torch_type)
        ofmap = self.golden_model(ifmap).detach()

        ifmap_uid = 'ifmap'
        ofmap_uid = 'ofmap'

        layer_cfg = {
            'size': size,
            'n_tiles': n_tiles,
            'ifmap': ifmap_uid,
            'ofmap': ofmap_uid,
            'dtype': prec,
            'funcptr': funcptr
        }

        header += [du.format_array_declaration(f'extern {ctype}', ifmap_uid,
                   ifmap.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_array_declaration(ctype, ofmap_uid,
                   ofmap.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_struct_definition('extern const silu_layer_t', 'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, ifmap_uid,
                   du.flatten(ifmap), alignment=self.BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        result_def = du.format_array_definition(ctype, 'golden',
                     du.flatten(ofmap), alignment=self.BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(SiluDataGen().main())
