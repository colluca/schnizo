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

BURST_ALIGNMENT = 4096


class BatchnormDataGen(du.DataGen):

    def golden_model(self, ifmap, gamma, beta):
        # ifmap: [CI, n_pixels], gamma/beta: [CI]
        # Kernel computes y = gamma * x + beta (affine-only, pre-normalized input).
        # Equivalent to batch_norm with running_mean=0, running_var=1, eps=0.
        CI = ifmap.shape[0]
        return torch.nn.functional.batch_norm(
            ifmap.unsqueeze(0),
            running_mean=torch.zeros(CI, dtype=ifmap.dtype),
            running_var=torch.ones(CI, dtype=ifmap.dtype),
            weight=gamma,
            bias=beta,
            training=False,
            eps=0
        ).squeeze(0)

    def infer_prec(self, funcptr):
        bits = re.search(r'fp(\d+)', funcptr).group(1)
        return f'FP{bits}'

    def validate(self, **kwargs):
        CI = kwargs['CI']
        IH = kwargs['IH']
        IW = kwargs['IW']
        prec_bytes = du.size_from_precision_t(self.infer_prec(kwargs['funcptr']))
        n_pixels = IH * IW
        du.validate_tcdm_footprint(2 * CI * n_pixels * prec_bytes + 2 * CI * prec_bytes)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        self.validate(**kwargs)

        CI = kwargs['CI']
        IH = kwargs['IH']
        IW = kwargs['IW']
        funcptr = kwargs['funcptr']
        prec = self.infer_prec(funcptr)
        n_pixels = IH * IW

        ctype = du.ctype_from_precision_t(prec)
        torch_type = du.torch_type_from_precision_t(prec)

        ifmap = torch.randn(CI, n_pixels, dtype=torch_type)
        gamma = torch.randn(CI, dtype=torch_type)
        beta = torch.randn(CI, dtype=torch_type)
        ofmap = self.golden_model(ifmap, gamma, beta).detach()

        ifmap_uid = 'ifmap'
        ofmap_uid = 'ofmap'
        gamma_uid = 'gamma_'
        beta_uid = 'beta'

        layer_cfg = {
            'CI':      CI,
            'IH':      IH,
            'IW':      IW,
            'funcptr': funcptr,
            'ifmap':   ifmap_uid,
            'gamma':   gamma_uid,
            'beta':    beta_uid,
            'ofmap':   ofmap_uid,
            'dtype':   prec,
        }

        header += [du.format_array_declaration(f'extern {ctype}', ifmap_uid,
                   ifmap.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_array_declaration(ctype, ofmap_uid,
                   ofmap.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_array_declaration(f'extern {ctype}', gamma_uid,
                   gamma.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_array_declaration(f'extern {ctype}', beta_uid,
                   beta.shape, alignment=BURST_ALIGNMENT)]
        header += [du.format_struct_definition('extern const batchnorm_layer_t',
                   'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, ifmap_uid,
                   ifmap, alignment=BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        header += [du.format_array_definition(ctype, gamma_uid,
                   gamma, alignment=BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        header += [du.format_array_definition(ctype, beta_uid,
                   beta, alignment=BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        result_def = du.format_array_definition(ctype, 'golden',
                                                du.flatten(ofmap), alignment=BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(BatchnormDataGen().main())
