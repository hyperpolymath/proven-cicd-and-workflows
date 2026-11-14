// SPDX-License-Identifier: MPL-2.0
'use strict';

function clampAdd(a, b) {
  return Math.min(a + b, 255);
}

function describe(n) {
  if (n < 0) return 'negative';
  if (n === 0) return 'zero';
  return 'positive';
}

module.exports = { clampAdd, describe };
