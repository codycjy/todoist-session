export const MIN_SECRET_LENGTH = 32

export function assertSecret(secret: string | undefined): string {
  if (!secret) throw new Error('APP_SECRET is required')
  if (secret.length < MIN_SECRET_LENGTH) {
    throw new Error(`APP_SECRET must be at least ${MIN_SECRET_LENGTH} characters long`)
  }
  return secret
}
