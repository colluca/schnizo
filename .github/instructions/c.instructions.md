---
applyTo: "**/*.c,**/*.h,**/*.cpp,**/*.cc,**/*.cxx,**/*.hpp,**/*.hh"
---

# C/C++ Development Guidelines

## License Header

Always include this header (update year as needed):

```c
// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
```

## Code Formatting

- **All code must be formatted with clang-format version 10**
- Format before committing

## Validation

```bash
# Format code
clang-format -i <file.c>

# Check formatting
clang-format --dry-run -Werror <file.c>
```
