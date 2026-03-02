#!/usr/bin/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import numpy as np
import sys

import snitch.util.sim.data_utils as du


np.random.seed(42)


class ExpDataGen(du.DataGen):

    def golden_model(self, a):
        return np.exp(a)

    def validate(self, **kwargs):
        # Calculate total TCDM occupation
        a_size = kwargs['batch_size'] * 8
        b_size = kwargs['batch_size'] * 8
        total_size = a_size
        total_size += b_size
        # Double buffering is used if there is more than one tile
        if kwargs['batch_size'] != kwargs['len']:
            total_size *= 2
        du.validate_tcdm_footprint(total_size)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        # Validate parameters
        self.validate(**kwargs)

        vlen, batch_size = kwargs['len'], kwargs['batch_size']
        ctype = 'double'

        a = du.generate_random_array((vlen), seed=42)
        b = self.golden_model(a)

        a_uid = 'a'
        b_uid = 'b'
        len_uid = 'len'
        batch_size_uid = 'batch_size'

        cfg = {
            **kwargs,
            'a': a_uid,
            'b': b_uid,
        }
        cfg['len'] = len_uid
        cfg['batch_size'] = batch_size_uid

        # "extern" specifier is required on declarations preceding a definition
        header += [du.format_array_declaration(f'extern {ctype}', a_uid, a.shape)]
        # "extern" specifier ensures that the variable is emitted and not mangled
        header += [du.format_scalar_definition('extern const uint32_t', len_uid, vlen)]
        header += [du.format_scalar_definition('extern const uint32_t', batch_size_uid, batch_size)]
        header += [du.format_array_definition(ctype, a_uid, a)]
        header += [du.format_array_declaration(f'{ctype}', b_uid, b.shape)]
        header = '\n\n'.join(header)

        return header


if __name__ == "__main__":
    sys.exit(ExpDataGen().main())
