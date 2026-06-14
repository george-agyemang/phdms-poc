import { Hono }          from 'hono';
import { cors }          from 'hono/cors';
import { logger }        from 'hono/logger';
import { secureHeaders } from 'hono/secure-headers';
import type { Env }      from './types/env';
import { authMiddleware }  from './middleware/auth';
import { auditMiddleware } from './middleware/audit';
import authRoute            from './routes/auth';
import patientsRoute        from './routes/patients';
import encountersRoute      from './routes/encounters';
import syncRoute, { runSync } from './routes/sync';
import dashboardRoute         from './routes/dashboard';

const app = new Hono<{ Bindings: Env }>();

app.use('*', logger());
app.use('*', cors({
  origin: '*',
  allowMethods: ['GET','POST','PATCH','DELETE','OPTIONS'],
  allowHeaders: ['Content-Type','Authorization'],
  credentials: false,
}));

app.get('/health', (c) => c.json({ ok: true, service: 'phdms-api', environment: c.env.ENVIRONMENT, ts: new Date().toISOString() }));

// /auth/* is outside /v1/* — no authMiddleware so the login endpoint is reachable
app.route('/auth', authRoute);

app.use('/v1/*', auditMiddleware);
app.use('/v1/*', authMiddleware);
app.route('/v1/patients',   patientsRoute);
app.route('/v1/encounters', encountersRoute);
app.route('/v1/sync',       syncRoute);
app.route('/v1/dashboard',  dashboardRoute);

app.notFound((c)  => c.json({ error: `Not found: ${c.req.method} ${c.req.path}` }, 404));
app.onError((err, c) => { console.error(err); return c.json({ error: 'Internal server error' }, 500); });

const scheduled: ExportedHandlerScheduledHandler<Env> = async (_e, env, ctx) => {
  ctx.waitUntil(runSync(env).then(r => console.log('[cron]', r)));
};

export default { fetch: app.fetch, scheduled } satisfies ExportedHandler<Env>;
