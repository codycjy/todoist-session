import { expect, it } from 'vitest'
import { TtlCache } from './cache.js'

it('returns the cached value within the ttl and refetches after', async () => {
  let t = 0
  let calls = 0
  const cache = new TtlCache<number>(60_000, () => t)
  const load = async () => ++calls

  expect(await cache.get('k', load)).toBe(1)
  t = 59_999
  expect(await cache.get('k', load)).toBe(1)
  t = 60_000
  expect(await cache.get('k', load)).toBe(2)
})

it('keeps keys independent', async () => {
  const cache = new TtlCache<string>(1000, () => 0)
  expect(await cache.get('a', async () => 'A')).toBe('A')
  expect(await cache.get('b', async () => 'B')).toBe('B')
})
