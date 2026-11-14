// SPDX-License-Identifier: MPL-2.0
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { describe } = require('../src/demo.js');

test('describe zero', () => {
  assert.strictEqual(describe(0), 'zero');
});
