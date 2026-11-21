export type Project = {
  id: string
  name: string
  permission: 'read' | 'capture'
}

export class ApiError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message)
  }
}

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, { ...init, credentials: 'same-origin' })
  if (response.status === 204) return undefined as T
  const body = await response.json().catch(() => null)
  if (!response.ok) throw new ApiError(response.status, body?.message ?? 'The request failed. Try again.')
  return body as T
}

export function requestJson(body: unknown): RequestInit {
  return { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
}

export function reportError(error: unknown, onSessionExpired: () => void) {
  if (error instanceof ApiError && error.status === 401) {
    onSessionExpired()
    return ''
  }
  return error instanceof ApiError ? error.message : 'Could not reach DuctDelta. Try again.'
}
