import { expect, it } from 'vitest'
import { decrypt, encrypt, hashToken } from './crypto.js'

it('encrypt/decrypt round-trips', () => {
  const enc = encrypt('todoist-secret', 'app-secret')
  expect(enc).not.toContain('todoist-secret')
  expect(decrypt(enc, 'app-secret')).toBe('todoist-secret')
})

it('decrypt fails with the wrong secret', () => {
  const enc = encrypt('x', 'right')
  expect(() => decrypt(enc, 'wrong')).toThrow()
})

it('decrypt fails on tampered ciphertext', () => {
  const buf = Buffer.from(encrypt('some-token', 's'), 'base64')
  buf[buf.length - 1] = (buf.at(-1) ?? 0) ^ 0x01
  expect(() => decrypt(buf.toString('base64'), 's')).toThrow()
})

it('hashToken is deterministic', () => {
  expect(hashToken('a')).toBe(hashToken('a'))
  expect(hashToken('a')).not.toBe(hashToken('b'))
})
