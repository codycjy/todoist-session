import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto'

const keyOf = (secret: string) => createHash('sha256').update(secret).digest()

export const hashToken = (token: string) => createHash('sha256').update(token).digest('hex')

/** AES-256-GCM；输出 base64(iv | tag | ciphertext)。 */
export function encrypt(plain: string, secret: string): string {
  const iv = randomBytes(12)
  const cipher = createCipheriv('aes-256-gcm', keyOf(secret), iv)
  const ct = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()])
  return Buffer.concat([iv, cipher.getAuthTag(), ct]).toString('base64')
}

export function decrypt(enc: string, secret: string): string {
  const buf = Buffer.from(enc, 'base64')
  const decipher = createDecipheriv('aes-256-gcm', keyOf(secret), buf.subarray(0, 12))
  decipher.setAuthTag(buf.subarray(12, 28))
  return Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString('utf8')
}
