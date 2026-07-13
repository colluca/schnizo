#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import sys
import numpy as np
import torch

import snitch.util.sim.data_utils as du

torch.manual_seed(42)
np.random.seed(42)


def _iou(box, boxes):
    x1 = torch.maximum(box[0], boxes[:, 0])
    y1 = torch.maximum(box[1], boxes[:, 1])
    x2 = torch.minimum(box[2], boxes[:, 2])
    y2 = torch.minimum(box[3], boxes[:, 3])
    inter = torch.clamp(x2 - x1, min=0) * torch.clamp(y2 - y1, min=0)
    area_box = (box[2] - box[0]) * (box[3] - box[1])
    area_boxes = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    return inter / (area_box + area_boxes - inter + 1e-6)


class NmsDataGen(du.DataGen):

    BURST_ALIGNMENT = 4096

    def golden_model(self, boxes, scores, iou_threshold):
        order = torch.argsort(scores, descending=True)
        keep = torch.zeros(len(scores), dtype=torch.int32)
        kept = []
        for idx in order.tolist():
            if not kept:
                keep[idx] = 1
                kept.append(idx)
                continue
            kept_boxes = boxes[kept]
            iou = _iou(boxes[idx], kept_boxes)
            if iou.max().item() <= iou_threshold:
                keep[idx] = 1
                kept.append(idx)
        return keep

    def validate(self, **kwargs):
        n = kwargs['num_boxes']
        prec = du.size_from_precision_t(kwargs['prec'])
        boxes_bytes = n * 4 * prec
        scores_bytes = n * prec
        keep_bytes = n * 4  # uint32_t
        idx_bytes = n * 4  # sort buffer
        du.validate_tcdm_footprint(boxes_bytes + scores_bytes + keep_bytes + idx_bytes)

    def emit_header(self, **kwargs):
        header = [super().emit_header()]

        self.validate(**kwargs)

        n = kwargs['num_boxes']
        iou_threshold = kwargs['iou_threshold']
        prec = kwargs['prec']

        torch_type = du.torch_type_from_precision_t(prec)
        ctype = du.ctype_from_precision_t(prec)

        # Generate random boxes (x1,y1,x2,y2) with x2>x1, y2>y1
        xy1 = torch.rand(n, 2, dtype=torch_type) * 100.0
        wh = torch.rand(n, 2, dtype=torch_type) * 50.0 + 1.0
        boxes = torch.cat([xy1, xy1 + wh], dim=1)
        scores = torch.rand(n, dtype=torch_type)
        keep = self.golden_model(boxes, scores, iou_threshold)

        boxes_uid = 'boxes'
        scores_uid = 'scores'
        keep_uid = 'keep'

        layer_cfg = {
            'num_boxes':     n,
            'iou_threshold': iou_threshold,
            'boxes':         boxes_uid,
            'scores':        scores_uid,
            'keep':          keep_uid,
            'dtype':         prec
        }

        header += [du.format_array_declaration(f'extern {ctype}', boxes_uid,
                   (n, 4), alignment=self.BURST_ALIGNMENT)]
        header += [du.format_array_declaration(f'extern {ctype}', scores_uid,
                   (n,), alignment=self.BURST_ALIGNMENT)]
        header += [du.format_array_declaration('uint32_t', keep_uid,
                   (n,), alignment=self.BURST_ALIGNMENT)]
        header += [du.format_struct_definition('nms_layer_t', 'layer', layer_cfg)]
        header += [du.format_array_definition(ctype, boxes_uid,
                   boxes, alignment=self.BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        header += [du.format_array_definition(ctype, scores_uid,
                   du.flatten(scores), alignment=self.BURST_ALIGNMENT,
                   section=kwargs.get('section'))]
        result_def = du.format_array_definition(
            'uint32_t', 'golden', du.flatten(keep), alignment=self.BURST_ALIGNMENT)
        header += [du.format_ifdef_wrapper('BIST', result_def)]

        return '\n\n'.join(header)


if __name__ == '__main__':
    sys.exit(NmsDataGen().main())
