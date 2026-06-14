import { Context, Next }      from 'hono'
import { createMiddleware }   from 'hono/factory'
import type { Env }           from '../types/env'
import type { AuthContext }   from '../types'
import { getCockroachClient } from '../db/cockroach'

// ─── Types ───────────────────────────────────────────────────────────────────

// Matches the existing audit_action enum in CockroachDB (lowercase values).
export type AuditAction =
  | 'create'
  | 'read'
  | 'update'
  | 'delete'
  | 'login'
  | 'logout'
  | 'export'
  | 'print'
  | 'sync_push'
  | 'sync_pull'
  | 'permission_change'

interface AuditPayload {
  actor_user_id?:   string | null
  actor_auth0_sub?: string | null
  // INET column — must be a valid IP string or null; x-forwarded-for is pre-parsed
  actor_ip?:        string | null
  actor_user_agent?: string | null
  clinic_id?:       string | null
  action:           AuditAction
  // entity STRING NOT NULL — use the resource name ('patient', 'encounter', …)
  entity:           string
  entity_id?:       string | null
  // Populate when entity === 'patient', or pass via override for child records
  patient_id?:      string | null
  before_state?:    Record<string, unknown> | null
  after_state?:     Record<string, unknown> | null
  // NOT NULL DEFAULT '{}' — always an object; http context goes here
  metadata?:        Record<string, unknown>
}

// ─── Route → entity mapping ───────────────────────────────────────────────────

const ROUTE_PATTERNS: Array<{
  pattern:  RegExp
  entity:   string
  idGroup?: number
}> = [
  { pattern: /^\/v1\/patients(?:\/([^/?]+))?/,    entity: 'patient',    idGroup: 1 },
  { pattern: /^\/v1\/encounters(?:\/([^/?]+))?/,  entity: 'encounter',  idGroup: 1 },
  { pattern: /^\/v1\/vitals(?:\/([^/?]+))?/,      entity: 'vital',      idGroup: 1 },
  { pattern: /^\/v1\/diagnoses(?:\/([^/?]+))?/,   entity: 'diagnosis',  idGroup: 1 },
  { pattern: /^\/v1\/medications(?:\/([^/?]+))?/, entity: 'medication', idGroup: 1 },
  { pattern: /^\/v1\/users(?:\/([^/?]+))?/,       entity: 'user',       idGroup: 1 },
  { pattern: /^\/v1\/clinics(?:\/([^/?]+))?/,     entity: 'clinic',     idGroup: 1 },
  { pattern: /^\/v1\/sync/,                       entity: 'sync_queue'             },
  { pattern: /^\/v1\/reports/,                    entity: 'report'                 },
]

function inferRoute(path: string): { entity: string; id: string | null } | null {
  for (const { pattern, entity, idGroup } of ROUTE_PATTERNS) {
    const m = path.match(pattern)
    if (m) return { entity, id: (idGroup && m[idGroup]) ? m[idGroup] : null }
  }
  return null
}

function inferAction(method: string): AuditAction {
  switch (method.toUpperCase()) {
    case 'GET':    return 'read'
    case 'POST':   return 'create'
    case 'PUT':
    case 'PATCH':  return 'update'
    case 'DELETE': return 'delete'
    default:       return 'read'
  }
}

// x-forwarded-for can be "clientIP, proxy1, proxy2" — take only the first
function parseIp(raw: string | undefined): string | null {
  if (!raw) return null
  return raw.split(',')[0].trim() || null
}

// ─── DB write ─────────────────────────────────────────────────────────────────

async function writeAuditRow(env: Env, payload: AuditPayload): Promise<void> {
  const db = getCockroachClient(env)
  try {
    await db`
      INSERT INTO audit_log (
        clinic_id, actor_user_id, actor_auth0_sub, actor_ip, actor_user_agent,
        action, entity, entity_id, patient_id,
        before_state, after_state, metadata
      ) VALUES (
        ${payload.clinic_id        ?? null},
        ${payload.actor_user_id    ?? null},
        ${payload.actor_auth0_sub  ?? null},
        ${payload.actor_ip         ?? null}::INET,
        ${payload.actor_user_agent ?? null},
        ${payload.action}::audit_action,
        ${payload.entity},
        ${payload.entity_id        ?? null},
        ${payload.patient_id       ?? null},
        ${payload.before_state     ?? null}::JSONB,
        ${payload.after_state      ?? null}::JSONB,
        ${payload.metadata ?? {}}::JSONB
      )
    `
  } catch (e) {
    // Never let a failed audit write break the response.
    // Note: in dev the FK constraints on clinic_id/actor_user_id will fire
    // if the bypass UUIDs don't exist in clinics/users — expected and harmless.
    console.error('[audit] DB write failed', e)
  } finally {
    await db.end()
  }
}

// ─── Shared payload builder ───────────────────────────────────────────────────

function buildPayload(
  auth:     AuthContext | undefined,
  c:        Context<{ Bindings: Env }>,
  override: Partial<AuditPayload> & Pick<AuditPayload, 'action' | 'entity'>,
): AuditPayload {
  const ip = c.req.header('CF-Connecting-IP') ?? parseIp(c.req.header('x-forwarded-for'))

  return {
    actor_user_id:    auth?.userId   ?? null,
    actor_auth0_sub:  auth?.auth0Sub ?? null,
    actor_ip:         ip             ?? null,
    actor_user_agent: c.req.header('user-agent')?.slice(0, 512) ?? null,
    clinic_id:        auth?.clinicId ?? null,
    ...override,
  }
}

// ─── Public helper: manual audit event ───────────────────────────────────────

export async function auditEvent(
  c:        Context<{ Bindings: Env }>,
  override: Partial<AuditPayload> & Pick<AuditPayload, 'action' | 'entity'>,
): Promise<void> {
  // auth may be absent for pre-auth events (e.g. login)
  const auth    = c.get('auth') as AuthContext | undefined
  const payload = buildPayload(auth, c, override)

  c.executionCtx.waitUntil(writeAuditRow(c.env, payload))
}

// ─── Automatic middleware ─────────────────────────────────────────────────────

export const auditMiddleware = createMiddleware<{ Bindings: Env }>(
  async (c: Context<{ Bindings: Env }>, next: Next) => {
    const startMs   = Date.now()
    const pathname  = new URL(c.req.url).pathname
    const routeInfo = inferRoute(pathname)

    if (!routeInfo) return next()

    await next()

    const status     = c.res.status
    const durationMs = Date.now() - startMs

    c.executionCtx.waitUntil(
      (async () => {
        const auth    = c.get('auth') as AuthContext | undefined
        const entityId   = routeInfo.id
        // Populate patient_id directly when the touched entity IS a patient;
        // for child records (encounter, vital, …) callers use auditEvent() + override.
        const patientId  = routeInfo.entity === 'patient' ? entityId : null

        const payload = buildPayload(auth, c, {
          action:     inferAction(c.req.method),
          entity:     routeInfo.entity,
          entity_id:  entityId,
          patient_id: patientId,
          metadata: {
            http_method: c.req.method,
            http_path:   pathname,
            http_status: status,
            duration_ms: durationMs,
          },
        })

        await writeAuditRow(c.env, payload)
      })()
    )
  }
)
