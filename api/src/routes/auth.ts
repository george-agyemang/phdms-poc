import { Hono }       from 'hono'
import type { Env }   from '../types/env'
import { auditEvent } from '../middleware/audit'

const auth = new Hono<{ Bindings: Env }>()

/**
 * POST /auth/login
 *
 * Mounted at the root level (outside /v1/*) so it is NOT gated by
 * authMiddleware. In production this is where the Auth0 callback or
 * token-exchange logic will live. For now it records a LOGIN audit
 * event and returns 200; real credential validation is TODO.
 *
 * Pass user context in the override once JWT parsing is wired up:
 *   auditEvent(c, { action: 'LOGIN', resource_type: 'user', user_id: sub })
 */
auth.post('/login', async (c) => {
  await auditEvent(c, {
    action: 'login',
    entity: 'user',
  })
  return c.json({ ok: true })
})

export default auth
