// SPDX-License-Identifier: MPL-2.0
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { clampAdd } = require('../src/demo.js');

test('clampAdd never exceeds 255', () => {
  for (let a = 0; a <= 255; a++) assert.ok(clampAdd(a, 255) <= 255);
});
