#!/usr/bin/env bash
# setup-api.sh
# Run from /workspaces/phdms-poc:
#   bash setup-api.sh
set -e

echo "→ Creating api/ directory structure..."
mkdir -p api/src/{middleware,db,routes,types}

# ── package.json ─────────────────────────────────────────────────────────────
cat > api/package.json << 'PKGJSON'
{
  "name": "api",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev":   "wrangler dev --env dev",
    "deploy":"wrangler deploy --env production",
    "types": "wrangler types"
  },
  "dependencies": {
    "hono":           "^4.4.0",
    "@libsql/client": "^0.14.0",
    "postgres":       "^3.4.4",
    "zod":            "^3.23.8"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.20240725.0",
    "typescript":                "^5.5.3",
    "wrangler":                  "^3.65.0"
  }
}
PKGJSON

# ── wrangler.toml ─────────────────────────────────────────────────────────────
cat > api/wrangler.toml << 'WRANGLER'
name               = "phdms-api"
main               = "src/index.ts"
compatibility_date = "2024-09-23"
compatibility_flags = ["nodejs_compat"]

[env.dev]
name = "phdms-api-dev"
[env.dev.vars]
ENVIRONMENT = "development"

[env.production]
name = "phdms-api"
[env.production.vars]
ENVIRONMENT = "production"
WRANGLER

# ── tsconfig.json ─────────────────────────────────────────────────────────────
cat > api/tsconfig.json << 'TSCONFIG'
{
  "compilerOptions": {
    "target":           "ES2022",
    "module":           "ES2022",
    "moduleResolution": "bundler",
    "lib":              ["ES2022"],
    "types":            ["@cloudflare/workers-types"],
    "strict":           true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck":     true
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

# ── src/types/env.ts ──────────────────────────────────────────────────────────
cat > api/src/types/env.ts << 'ENVTS'
export interface Env {
  COCKROACHDB_URL:  string;
  TURSO_URL:        string;
  TURSO_AUTH_TOKEN: string;
  AUTH0_DOMAIN:     string;
  AUTH0_AUDIENCE:   string;
  ENVIRONMENT:      string;
}
ENVTS

# ── src/types/index.ts ────────────────────────────────────────────────────────
cat > api/src/types/index.ts << 'TYPESTS'
export interface JwtPayload {
  sub:   string;
  email: string;
  iss:   string;
  aud:   string | string[];
  exp:   number;
  iat:   number;
  'https://phdms/clinic_id': string;
  'https://phdms/role':      string;
}

export interface AuthContext {
  userId:   string;
  auth0Sub: string;
  clinicId: string;
  role:     string;
  email:    string;
}

export interface PageMeta {
  page: number; limit: number; total: number; hasMore: boolean;
}
export interface PagedResponse<T> { data: T[]; meta: PageMeta; }
TYPESTS

# ── src/db/cockroach.ts ───────────────────────────────────────────────────────
cat > api/src/db/cockroach.ts << 'COCKROACHTS'
import postgres from 'postgres';
import type { Env } from '../types/env';

let _client: ReturnType<typeof postgres> | null = null;

export function getCockroachClient(env: Env) {
  if (_client) return _client;
  _client = postgres(env.COCKROACHDB_URL, {
    ssl:             'require',
    max:             5,
    idle_timeout:    20,
    connect_timeout: 10,
    prepare:         false,
  });
  return _client;
}

export type DB = ReturnType<typeof getCockroachClient>;
COCKROACHTS

# ── src/db/turso.ts ───────────────────────────────────────────────────────────
cat > api/src/db/turso.ts << 'TURSO'
import { createClient } from '@libsql/client/http';
import type { Env } from '../types/env';

let _client: ReturnType<typeof createClient> | null = null;

export function getTursoClient(env: Env) {
  if (_client) return _client;
  _client = createClient({ url: env.TURSO_URL, authToken: env.TURSO_AUTH_TOKEN });
  return _client;
}

export type TursoDB = ReturnType<typeof getTursoClient>;
TURSO

# ── src/middleware/auth.ts ────────────────────────────────────────────────────
cat > api/src/middleware/auth.ts << 'AUTHTS'
import type { MiddlewareHandler } from 'hono';
import type { Env } from '../types/env';
import type { AuthContext, JwtPayload } from '../types';
import { getCockroachClient } from '../db/cockroach';

const jwksCache = new Map<string, CryptoKey>();
let jwksCachedAt = 0;
const JWKS_TTL_MS = 60 * 60 * 1000;

async function getSigningKey(domain: string, kid: string): Promise<CryptoKey> {
  const cacheKey = `${domain}:${kid}`;
  if (jwksCache.has(cacheKey) && Date.now() - jwksCachedAt < JWKS_TTL_MS)
    return jwksCache.get(cacheKey)!;

  const res  = await fetch(`https://${domain}/.well-known/jwks.json`);
  const jwks = await res.json() as { keys: Array<JsonWebKey & { kid: string }> };
  jwksCachedAt = Date.now();
  jwksCache.clear();

  for (const jwk of jwks.keys) {
    const key = await crypto.subtle.importKey(
      'jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify'],
    );
    jwksCache.set(`${domain}:${jwk.kid}`, key);
  }

  const key = jwksCache.get(cacheKey);
  if (!key) throw new Error(`No JWKS key for kid: ${kid}`);
  return key;
}

function b64urlDecode(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(b64), c => c.charCodeAt(0));
}

async function verifyJwt(token: string, domain: string, audience: string): Promise<JwtPayload> {
  const [headerB64, payloadB64, sigB64] = token.split('.') as [string, string, string];
  const header  = JSON.parse(new TextDecoder().decode(b64urlDecode(headerB64))) as { kid: string; alg: string };
  const payload = JSON.parse(new TextDecoder().decode(b64urlDecode(payloadB64))) as JwtPayload;

  if (header.alg !== 'RS256')                                  throw new Error('Unexpected algorithm');
  if (payload.exp < Math.floor(Date.now() / 1000))             throw new Error('Token expired');
  if (payload.iss !== `https://${domain}/`)                    throw new Error('Invalid issuer');
  const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!aud.includes(audience))                                 throw new Error('Invalid audience');

  const key      = await getSigningKey(domain, header.kid);
  const sigInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const valid    = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64urlDecode(sigB64), sigInput);
  if (!valid) throw new Error('Invalid signature');
  return payload;
}

const userCache = new Map<string, AuthContext>();

declare module 'hono' {
  interface ContextVariableMap { auth: AuthContext; }
}

export const authMiddleware: MiddlewareHandler<{ Bindings: Env }> = async (c, next) => {
  const authHeader = c.req.header('Authorization');
  if (!authHeader?.startsWith('Bearer '))
    return c.json({ error: 'Missing Authorization header' }, 401);

  let payload: JwtPayload;
  try { payload = await verifyJwt(authHeader.slice(7), c.env.AUTH0_DOMAIN, c.env.AUTH0_AUDIENCE); }
  catch (err) { return c.json({ error: `Unauthorized: ${(err as Error).message}` }, 401); }

  if (userCache.has(payload.sub)) { c.set('auth', userCache.get(payload.sub)!); return next(); }

  const db   = getCockroachClient(c.env);
  const rows = await db<{ id: string; clinic_id: string; role: string; email: string }[]>`
    SELECT id, clinic_id, role, email FROM users
    WHERE  auth0_sub = ${payload.sub} AND deleted_at IS NULL LIMIT 1
  `;
  if (rows.length === 0) return c.json({ error: 'User not found' }, 403);

  const [user] = rows;
  const ctx: AuthContext = {
    userId: user!.id, auth0Sub: payload.sub,
    clinicId: user!.clinic_id, role: user!.role, email: user!.email,
  };
  userCache.set(payload.sub, ctx);
  c.set('auth', ctx);
  return next();
};

export function requireRole(...roles: string[]): MiddlewareHandler<{ Bindings: Env }> {
  return async (c, next) => {
    const auth = c.get('auth');
    if (!roles.includes(auth.role))
      return c.json({ error: `Forbidden: requires [${roles.join(', ')}]` }, 403);
    return next();
  };
}
AUTHTS

# ── src/routes/patients.ts ────────────────────────────────────────────────────
cat > api/src/routes/patients.ts << 'PATIENTSTS'
import { Hono } from 'hono';
import { z }    from 'zod';
import type { Env } from '../types/env';
import { getCockroachClient } from '../db/cockroach';
import { requireRole }        from '../middleware/auth';

const patients = new Hono<{ Bindings: Env }>();

const CreatePatientSchema = z.object({
  mrn:             z.string().min(1).max(50),
  national_id:     z.string().max(50).optional(),
  first_name:      z.string().min(1).max(100),
  middle_name:     z.string().max(100).optional(),
  last_name:       z.string().min(1).max(100),
  date_of_birth:   z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  biological_sex:  z.enum(['male','female','intersex','unknown']).default('unknown'),
  blood_group:     z.enum(['A+','A-','B+','B-','AB+','AB-','O+','O-','unknown']).default('unknown'),
  phone_primary:   z.string().max(20).optional(),
  email:           z.string().email().optional(),
  city:            z.string().max(100).optional(),
  region:          z.string().max(100).optional(),
  insurance_provider: z.string().max(100).optional(),
  insurance_number:   z.string().max(50).optional(),
  insurance_expiry:   z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
});

const UpdatePatientSchema = CreatePatientSchema.partial();

patients.get('/', async (c) => {
  const auth   = c.get('auth');
  const db     = getCockroachClient(c.env);
  const params = new URL(c.req.url).searchParams;
  const search = params.get('search');
  const page   = Math.max(1, parseInt(params.get('page')  ?? '1'));
  const limit  = Math.min(100, parseInt(params.get('limit') ?? '20'));
  const offset = (page - 1) * limit;

  const [{ count }] = await db<[{ count: string }]>`
    SELECT COUNT(*)::TEXT AS count FROM patients
    WHERE clinic_id = ${auth.clinicId} AND deleted_at IS NULL
    ${search ? db`AND (first_name ILIKE ${'%'+search+'%'} OR last_name ILIKE ${'%'+search+'%'} OR mrn ILIKE ${'%'+search+'%'})` : db``}
  `;

  const rows = await db`
    SELECT id, mrn, first_name, last_name, date_of_birth, biological_sex,
           blood_group, phone_primary, city, insurance_provider, sync_version, updated_at
    FROM   patients
    WHERE  clinic_id = ${auth.clinicId} AND deleted_at IS NULL
    ${search ? db`AND (first_name ILIKE ${'%'+search+'%'} OR last_name ILIKE ${'%'+search+'%'} OR mrn ILIKE ${'%'+search+'%'})` : db``}
    ORDER  BY last_name ASC LIMIT ${limit} OFFSET ${offset}
  `;

  const total = parseInt(count ?? '0');
  return c.json({ data: rows, meta: { page, limit, total, hasMore: offset + rows.length < total } });
});

patients.get('/:id', async (c) => {
  const auth = c.get('auth');
  const db   = getCockroachClient(c.env);
  const [patient] = await db`
    SELECT * FROM patients
    WHERE id = ${c.req.param('id')} AND clinic_id = ${auth.clinicId} AND deleted_at IS NULL
  `;
  if (!patient) return c.json({ error: 'Patient not found' }, 404);
  return c.json({ data: patient });
});

patients.post('/', requireRole('clinic_admin','doctor','nurse','receptionist','data_entry'), async (c) => {
  const auth   = c.get('auth');
  const db     = getCockroachClient(c.env);
  const parsed = CreatePatientSchema.safeParse(await c.req.json());
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const d = parsed.data;

  const [existing] = await db`
    SELECT id FROM patients WHERE clinic_id = ${auth.clinicId} AND mrn = ${d.mrn} AND deleted_at IS NULL
  `;
  if (existing) return c.json({ error: `MRN "${d.mrn}" already exists` }, 409);

  const [patient] = await db`
    INSERT INTO patients (
      clinic_id, mrn, national_id, first_name, middle_name, last_name,
      date_of_birth, biological_sex, blood_group, phone_primary, email,
      city, region, insurance_provider, insurance_number, insurance_expiry, created_by
    ) VALUES (
      ${auth.clinicId}, ${d.mrn}, ${d.national_id ?? null},
      ${d.first_name}, ${d.middle_name ?? null}, ${d.last_name},
      ${d.date_of_birth}, ${d.biological_sex}, ${d.blood_group},
      ${d.phone_primary ?? null}, ${d.email ?? null}, ${d.city ?? null}, ${d.region ?? null},
      ${d.insurance_provider ?? null}, ${d.insurance_number ?? null}, ${d.insurance_expiry ?? null},
      ${auth.userId}
    ) RETURNING *
  `;
  return c.json({ data: patient }, 201);
});

patients.patch('/:id', requireRole('clinic_admin','doctor','nurse','receptionist','data_entry'), async (c) => {
  const auth   = c.get('auth');
  const db     = getCockroachClient(c.env);
  const parsed = UpdatePatientSchema.safeParse(await c.req.json());
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const d  = parsed.data;
  const id = c.req.param('id');

  const [existing] = await db`SELECT id FROM patients WHERE id=${id} AND clinic_id=${auth.clinicId} AND deleted_at IS NULL`;
  if (!existing) return c.json({ error: 'Patient not found' }, 404);

  const [updated] = await db`
    UPDATE patients SET
      mrn            = COALESCE(${d.mrn ?? null},           mrn),
      first_name     = COALESCE(${d.first_name ?? null},    first_name),
      last_name      = COALESCE(${d.last_name ?? null},     last_name),
      date_of_birth  = COALESCE(${d.date_of_birth ?? null}, date_of_birth),
      biological_sex = COALESCE(${d.biological_sex ?? null},biological_sex),
      blood_group    = COALESCE(${d.blood_group ?? null},   blood_group),
      phone_primary  = COALESCE(${d.phone_primary ?? null}, phone_primary),
      email          = COALESCE(${d.email ?? null},         email),
      city           = COALESCE(${d.city ?? null},          city),
      insurance_number  = COALESCE(${d.insurance_number ?? null}, insurance_number),
      insurance_expiry  = COALESCE(${d.insurance_expiry ?? null}, insurance_expiry)
    WHERE id = ${id} AND clinic_id = ${auth.clinicId}
    RETURNING *
  `;
  return c.json({ data: updated });
});

patients.delete('/:id', requireRole('clinic_admin'), async (c) => {
  const auth = c.get('auth');
  const db   = getCockroachClient(c.env);
  const [deleted] = await db`
    UPDATE patients SET deleted_at = now()
    WHERE id = ${c.req.param('id')} AND clinic_id = ${auth.clinicId} AND deleted_at IS NULL
    RETURNING id, mrn, first_name, last_name
  `;
  if (!deleted) return c.json({ error: 'Patient not found' }, 404);
  return c.json({ data: deleted });
});

export default patients;
PATIENTSTS

# ── src/routes/encounters.ts ──────────────────────────────────────────────────
cat > api/src/routes/encounters.ts << 'ENCOUNTERSTS'
import { Hono } from 'hono';
import { z }    from 'zod';
import type { Env } from '../types/env';
import { getCockroachClient } from '../db/cockroach';
import { requireRole }        from '../middleware/auth';

const encounters = new Hono<{ Bindings: Env }>();

const CreateEncounterSchema = z.object({
  patient_id:      z.string().uuid(),
  encounter_type:  z.enum(['outpatient','inpatient','emergency','teleconsult','lab_only','pharmacy_only','antenatal','follow_up']).default('outpatient'),
  status:          z.enum(['scheduled','checked_in','in_progress','completed','cancelled','no_show']).default('scheduled'),
  scheduled_at:    z.string().datetime().optional(),
  chief_complaint: z.string().max(500).optional(),
  provider_id:     z.string().uuid().optional(),
});

const UpdateEncounterSchema = z.object({
  status:            z.enum(['scheduled','checked_in','in_progress','completed','cancelled','no_show']).optional(),
  chief_complaint:   z.string().max(500).optional(),
  notes:             z.string().optional(),
  discharge_summary: z.string().optional(),
  provider_id:       z.string().uuid().optional(),
  ended_at:          z.string().datetime().optional(),
  bill_total_ghs:    z.number().min(0).optional(),
});

encounters.get('/', async (c) => {
  const auth   = c.get('auth');
  const db     = getCockroachClient(c.env);
  const params = new URL(c.req.url).searchParams;
  const patientId = params.get('patient_id');
  const status    = params.get('status');
  const limit     = Math.min(50, parseInt(params.get('limit') ?? '20'));
  const offset    = (Math.max(1, parseInt(params.get('page') ?? '1')) - 1) * limit;

  const rows = await db`
    SELECT e.*, p.first_name AS patient_first_name, p.last_name AS patient_last_name,
           p.mrn AS patient_mrn, u.full_name AS provider_name
    FROM   encounters e
    JOIN   patients p ON p.id = e.patient_id
    LEFT JOIN users u ON u.id = e.provider_id
    WHERE  e.clinic_id = ${auth.clinicId} AND e.deleted_at IS NULL
    ${patientId ? db`AND e.patient_id = ${patientId}` : db``}
    ${status    ? db`AND e.status     = ${status}`    : db``}
    ORDER  BY e.scheduled_at DESC NULLS LAST
    LIMIT ${limit} OFFSET ${offset}
  `;
  return c.json({ data: rows });
});

encounters.get('/:id', async (c) => {
  const auth = c.get('auth');
  const db   = getCockroachClient(c.env);
  const [encounter] = await db`
    SELECT e.*, p.first_name AS patient_first_name, p.last_name AS patient_last_name,
           p.mrn AS patient_mrn, u.full_name AS provider_name
    FROM encounters e
    JOIN patients p ON p.id = e.patient_id
    LEFT JOIN users u ON u.id = e.provider_id
    WHERE e.id = ${c.req.param('id')} AND e.clinic_id = ${auth.clinicId} AND e.deleted_at IS NULL
  `;
  if (!encounter) return c.json({ error: 'Encounter not found' }, 404);
  const [vitals, diagnoses, medications] = await Promise.all([
    db`SELECT * FROM vitals      WHERE encounter_id = ${encounter.id} ORDER BY recorded_at DESC`,
    db`SELECT * FROM diagnoses   WHERE encounter_id = ${encounter.id}`,
    db`SELECT * FROM medications WHERE encounter_id = ${encounter.id}`,
  ]);
  return c.json({ data: { ...encounter, vitals, diagnoses, medications } });
});

encounters.post('/', requireRole('clinic_admin','doctor','nurse','receptionist'), async (c) => {
  const auth   = c.get('auth');
  const db     = getCockroachClient(c.env);
  const parsed = CreateEncounterSchema.safeParse(await c.req.json());
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const d = parsed.data;

  const [patient] = await db`SELECT id FROM patients WHERE id=${d.patient_id} AND clinic_id=${auth.clinicId} AND deleted_at IS NULL`;
  if (!patient) return c.json({ error: 'Patient not found' }, 404);

  const [encounter] = await db`
    INSERT INTO encounters (clinic_id, patient_id, encounter_type, status, scheduled_at, chief_complaint, provider_id, created_by)
    VALUES (${auth.clinicId}, ${d.patient_id}, ${d.encounter_type}, ${d.status},
            ${d.scheduled_at ?? null}, ${d.chief_complaint ?? null},
            ${d.provider_id ?? auth.userId}, ${auth.userId})
    RETURNING *
  `;
  return c.json({ data: encounter }, 201);
});

encounters.patch('/:id', requireRole('clinic_admin','doctor','nurse'), async (c) => {
  const auth   = c.get('auth');
  const db     = getCockroachClient(c.env);
  const parsed = UpdateEncounterSchema.safeParse(await c.req.json());
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const d  = parsed.data;
  const id = c.req.param('id');

  const [updated] = await db`
    UPDATE encounters SET
      status            = COALESCE(${d.status            ?? null}, status),
      chief_complaint   = COALESCE(${d.chief_complaint   ?? null}, chief_complaint),
      notes             = COALESCE(${d.notes             ?? null}, notes),
      discharge_summary = COALESCE(${d.discharge_summary ?? null}, discharge_summary),
      provider_id       = COALESCE(${d.provider_id       ?? null}, provider_id),
      ended_at          = COALESCE(${d.ended_at          ?? null}, ended_at),
      bill_total_ghs    = COALESCE(${d.bill_total_ghs    ?? null}, bill_total_ghs),
      checked_in_at = CASE WHEN ${d.status ?? null} = 'checked_in'  AND checked_in_at IS NULL THEN now() ELSE checked_in_at END,
      started_at    = CASE WHEN ${d.status ?? null} = 'in_progress' AND started_at    IS NULL THEN now() ELSE started_at    END,
      ended_at      = CASE WHEN ${d.status ?? null} IN ('completed','cancelled') AND ended_at IS NULL THEN now() ELSE ended_at END
    WHERE id = ${id} AND clinic_id = ${auth.clinicId} AND deleted_at IS NULL
    RETURNING *
  `;
  if (!updated) return c.json({ error: 'Encounter not found' }, 404);
  return c.json({ data: updated });
});

export default encounters;
ENCOUNTERSTS

# ── src/routes/sync.ts ────────────────────────────────────────────────────────
cat > api/src/routes/sync.ts << 'SYNCTS'
import { Hono }  from 'hono';
import type { Env } from '../types/env';
import { getCockroachClient } from '../db/cockroach';
import { getTursoClient }     from '../db/turso';
import { requireRole }        from '../middleware/auth';

const sync = new Hono<{ Bindings: Env }>();

const SEX_MAP: Record<string,number>  = { unknown:0, male:1, female:2, intersex:3 };
const BLOOD_MAP: Record<string,number> = { unknown:0,'A+':1,'A-':2,'B+':3,'B-':4,'AB+':5,'AB-':6,'O+':7,'O-':8 };
const ENC_TYPE_MAP: Record<string,number> = { outpatient:0,inpatient:1,emergency:2,teleconsult:3,lab_only:4,pharmacy_only:5,antenatal:6,follow_up:7 };
const ENC_STATUS_MAP: Record<string,number> = { scheduled:0,checked_in:1,in_progress:2,completed:3,cancelled:4,no_show:5 };

function toEpochMs(val: unknown): number | null {
  if (!val) return null;
  const d = new Date(val as string);
  return isNaN(d.getTime()) ? null : d.getTime();
}

export async function runSync(env: Env, clinicId?: string) {
  const crdb  = getCockroachClient(env);
  const turso = getTursoClient(env);
  const results = { processed: 0, errors: 0, skipped: 0 };

  const pending = await crdb<Array<Record<string,unknown>>>`
    SELECT id, entity, entity_id, operation, payload FROM sync_queue
    WHERE status = 'pending'
    ${clinicId ? crdb`AND clinic_id = ${clinicId}` : crdb``}
    ORDER BY enqueued_at ASC LIMIT 50 FOR UPDATE SKIP LOCKED
  `;
  if (pending.length === 0) return results;

  await crdb`UPDATE sync_queue SET status='in_flight', dispatched_at=now(), attempt_count=attempt_count+1 WHERE id=ANY(${pending.map(r=>r['id'] as string)})`;

  for (const row of pending) {
    try {
      const entity    = row['entity']    as string;
      const entityId  = row['entity_id'] as string;
      const operation = row['operation'] as string;
      const payload   = row['payload']   as Record<string,unknown>;

      if (operation === 'delete') {
        await turso.execute({ sql: `DELETE FROM ${entity}s WHERE id = ?`, args: [entityId] });
      } else if (entity === 'patient') {
        await turso.execute({
          sql: `INSERT INTO patients (id,clinic_id,mrn,first_name,last_name,date_of_birth,sex,blood_group,phone,is_deceased,sync_version,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET mrn=excluded.mrn,first_name=excluded.first_name,last_name=excluded.last_name,
                date_of_birth=excluded.date_of_birth,sex=excluded.sex,blood_group=excluded.blood_group,
                phone=excluded.phone,is_deceased=excluded.is_deceased,sync_version=excluded.sync_version,updated_at=excluded.updated_at`,
          args: [
            entityId, payload['clinic_id'], payload['mrn'], payload['first_name'], payload['last_name'],
            toEpochMs(payload['date_of_birth']),
            SEX_MAP[payload['biological_sex'] as string] ?? 0,
            BLOOD_MAP[payload['blood_group'] as string] ?? 0,
            payload['phone_primary'] ?? null,
            payload['is_deceased'] ? 1 : 0,
            payload['sync_version'],
            toEpochMs(payload['updated_at']),
          ],
        });
      } else if (entity === 'encounter') {
        await turso.execute({
          sql: `INSERT INTO encounters (id,patient_id,clinic_id,enc_type,status,scheduled_at,provider_id,sync_version,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET enc_type=excluded.enc_type,status=excluded.status,
                scheduled_at=excluded.scheduled_at,sync_version=excluded.sync_version,updated_at=excluded.updated_at`,
          args: [
            entityId, payload['patient_id'], payload['clinic_id'],
            ENC_TYPE_MAP[payload['encounter_type'] as string] ?? 0,
            ENC_STATUS_MAP[payload['status'] as string] ?? 0,
            toEpochMs(payload['scheduled_at']),
            payload['provider_id'] ?? null,
            payload['sync_version'],
            toEpochMs(payload['updated_at']),
          ],
        });
      } else {
        results.skipped++;
      }

      await crdb`UPDATE sync_queue SET status='done', completed_at=now() WHERE id=${row['id'] as string}`;
      results.processed++;
    } catch (err) {
      await crdb`UPDATE sync_queue SET status='failed', last_error=${(err as Error).message} WHERE id=${row['id'] as string}`;
      results.errors++;
    }
  }
  return results;
}

sync.post('/push', requireRole('super_admin','clinic_admin'), async (c) => {
  const auth    = c.get('auth');
  const results = await runSync(c.env, auth.clinicId);
  return c.json({ ok: true, results });
});

sync.get('/status', requireRole('super_admin','clinic_admin'), async (c) => {
  const auth = c.get('auth');
  const db   = getCockroachClient(c.env);
  const [stats] = await db`
    SELECT
      COUNT(*) FILTER (WHERE status='pending')   AS pending,
      COUNT(*) FILTER (WHERE status='in_flight') AS in_flight,
      COUNT(*) FILTER (WHERE status='done')      AS done,
      COUNT(*) FILTER (WHERE status='failed')    AS failed,
      MAX(completed_at)                          AS last_sync_at
    FROM sync_queue WHERE clinic_id = ${auth.clinicId}
  `;
  return c.json({ data: stats });
});

export default sync;
SYNCTS

# ── src/index.ts ──────────────────────────────────────────────────────────────
cat > api/src/index.ts << 'INDEXTS'
import { Hono }          from 'hono';
import { cors }          from 'hono/cors';
import { logger }        from 'hono/logger';
import { secureHeaders } from 'hono/secure-headers';
import type { Env }      from './types/env';
import { authMiddleware } from './middleware/auth';
import patientsRoute      from './routes/patients';
import encountersRoute    from './routes/encounters';
import syncRoute, { runSync } from './routes/sync';

const app = new Hono<{ Bindings: Env }>();

app.use('*', logger());
app.use('*', secureHeaders());
app.use('*', cors({
  origin: ['https://phdms.pages.dev', 'http://localhost:3000', 'http://localhost:3001'],
  allowMethods: ['GET','POST','PATCH','DELETE','OPTIONS'],
  allowHeaders: ['Content-Type','Authorization'],
  credentials: true,
}));

app.get('/health', (c) => c.json({ ok: true, service: 'phdms-api', environment: c.env.ENVIRONMENT, ts: new Date().toISOString() }));

app.use('/v1/*', authMiddleware);
app.route('/v1/patients',   patientsRoute);
app.route('/v1/encounters', encountersRoute);
app.route('/v1/sync',       syncRoute);

app.notFound((c)  => c.json({ error: `Not found: ${c.req.method} ${c.req.path}` }, 404));
app.onError((err, c) => { console.error(err); return c.json({ error: 'Internal server error' }, 500); });

const scheduled: ExportedHandlerScheduledHandler<Env> = async (_e, env, ctx) => {
  ctx.waitUntil(runSync(env).then(r => console.log('[cron]', r)));
};

export default { fetch: app.fetch, scheduled } satisfies ExportedHandler<Env>;
INDEXTS

echo ""
echo "✓ api/ scaffold complete. Now run:"
echo ""
echo "  cd api"
echo "  pnpm approve-builds   # allow sharp + unrs-resolver"
echo "  pnpm install"
echo "  pnpm dev"
