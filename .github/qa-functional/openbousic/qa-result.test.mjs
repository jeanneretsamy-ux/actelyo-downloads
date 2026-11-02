import test from 'node:test'
import assert from 'node:assert/strict'
import { functionalQaPassed } from './qa-result.mjs'

test('a completed successful functional run passes', () => {
  assert.equal(functionalQaPassed({ steps: [{ ok: true }, { ok: true }] }), true)
})
test('a failed step, including a file-writing step, fails the run', () => {
  assert.equal(functionalQaPassed({ steps: [{ ok: true }, { name: '(bonus) file write', ok: false }] }), false)
})
test('an aborted run never passes on the preceding successful steps', () => {
  assert.equal(functionalQaPassed({ aborted: 'renderer unavailable', steps: [{ ok: true }] }), false)
  assert.equal(functionalQaPassed({ fatal: 'unexpected error', steps: [{ ok: true }] }), false)
})
test('an empty or incomplete report cannot pass', () => {
  assert.equal(functionalQaPassed({ steps: [] }), false)
  assert.equal(functionalQaPassed({ steps: [{}] }), false)
  assert.equal(functionalQaPassed({}), false)
})
