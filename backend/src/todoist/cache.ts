export class TtlCache<T> {
  private entries = new Map<string, { value: T; expiresAt: number }>()

  constructor(
    private ttlMs: number,
    private now: () => number = Date.now,
  ) {}

  async get(key: string, load: () => Promise<T>): Promise<T> {
    const hit = this.entries.get(key)
    if (hit && this.now() < hit.expiresAt) return hit.value
    const value = await load()
    this.entries.set(key, { value, expiresAt: this.now() + this.ttlMs })
    return value
  }
}
