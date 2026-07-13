#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import torch

import snitch.util.sim.data_utils as du

torch.manual_seed(42)


class InterpolateDataGen(du.DataGen):

    BURST_ALIGNMENT = 4096

    def golden_model(self, ifmap, out_height, out_width):
        return torch.nn.functional.interpolate(
            ifmap, size=(out_height, out_width),
            mode='bilinear', align_corners=False)

    def validate(self, **kwargs):
        batch_size = kwargs['batch_size']
        channels = kwargs['channels']
        in_h = kwargs['in_height']
        in_w = kwargs['in_width']
        out_h = kwargs['out_height']
        out_w = kwargs['out_width']
        prec = du.size_from_precision_t(kwargs['prec'])
        # Each cluster holds its slice of planes; check worst case (1 cluster)
        in_bytes = batch_size * channels * in_h * in_w * prec
        out_bytes = batch_size * channels * out_h * out_w * prec
        du.validate_tcdm_footprint(in_bytes + out_bytes)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        self.validate(**kwargs)

        batch_size = kwargs['batch_size']
        channels = kwargs['channels']
        in_h = kwargs['in_height']
        in_w = kwargs['in_width']
        out_h = kwargs['out_height']
        out_w = kwargs['out_width']
        prec = kwargs['prec']

        torch_type = du.torch_type_from_precision_t(prec)
        ctype = du.ctype_from_precision_t(prec)

        ifmap = torch.randn(batch_size, channels, in_h, in_w, dtype=torch_type)
        ofmap = self.golden_model(ifmap, out_h, out_w).detach()

        ifmap_uid = 'ifmap'
        ofmap_uid = 'ofmap'

        layer_cfg = {
            'batch_size': batch_size,
            'channels':   channels,
            'in_height':  in_h,
            'in_width':   in_w,
            'out_height': out_h,
            'out_width':  out_w,
            'ifmap':      ifmap_uid,
            'ofmap':      ofmap_uid,
            'dtype':      prec
        }

        header += [du.format_array_declaration(f'extern {ctype}', ifmap_uid,
                   ifmap.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_array_declaration(ctype, ofmap_uid,
                   ofmap.shape, alignment=self.BURST_ALIGNMENT)]
        header += [du.format_struct_definition('interpolate_layer_t', 'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, ifmap_uid,
                   ifmap, alignment=self.BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        result_def = du.format_array_definition(
            ctype, 'golden', du.flatten(ofmap), alignment=self.BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(InterpolateDataGen().main())
