import { z } from 'zod'

export const DAY_MS = 86_400_000
export const MAX_RANGE_MS = 92 * DAY_MS

const intString = z.string().regex(/^-?\d+$/).transform(Number).pipe(z.number().int().safe())

/** `?from=&to=`（毫秒，左闭右开）：整数、to > from、区间 ≤ 92 天 */
export const rangeQuery = z
  .object({ from: intString, to: intString })
  .refine((q) => q.to > q.from && q.to - q.from <= MAX_RANGE_MS)
