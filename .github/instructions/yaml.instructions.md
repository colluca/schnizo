---
applyTo: "**/*.yml,**/*.yaml"
---

# YAML Development Guidelines

## License Header

Always include this header (update year as needed):

```yaml
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
```

## Validation

- Must pass yamllint validation
- Config: `util/lint/.yamllint.yml`

```bash
yamllint -c util/lint/.yamllint.yml <file.yml>
```
