import { expect, it } from 'vitest'
import { assertSecret } from './config.js'

it('rejects a missing or short secret without echoing it', () => {
  expect(() => assertSecret(undefined)).toThrow(/APP_SECRET/)
  expect(() => assertSecret('short-secret')).toThrow(/32/)
  expect(() => assertSecret('short-secret')).not.toThrow(/short-secret/)
})

it('accepts a secret of at least 32 characters', () => {
  const s = 'x'.repeat(32)
  expect(assertSecret(s)).toBe(s)
})
