---
applyTo: "**/*.py"
---

# Python Development Guidelines

## License Header

Always include this header (update year as needed):

```python
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
```

## Code Style

- **Maximum line length: 100 characters** (strictly enforced by flake8)
- Python version: 3.11+
- flake8 version: 6.0.0
- Follow PEP 8 guidelines
- All flake8 errors must be resolved

## Validation

```bash
flake8 --max-line-length=100 <file.py>
```
