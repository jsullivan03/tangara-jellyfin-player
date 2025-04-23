/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "sample.hpp"
#include <stdint.h>

#include <cstdint>

#include "komihash.h"

namespace sample {

auto shiftWithDither(int64_t src, uint_fast8_t bits) -> Sample {
  // FIXME: Use a better dither.
  static uint64_t sSeed1{0};
  static uint64_t sSeed2{0};
  static uint64_t noise;
  static uint_fast8_t pos = 0;
  if (pos++ % 64 == 0)
    noise = komirand(&sSeed1, &sSeed2);
  else
    noise >>= 1;
  return (src >> bits) ^ (noise & 1);
}

}  // namespace sample
