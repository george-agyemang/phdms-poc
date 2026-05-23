#!/usr/bin/env bash
# setup-web.sh — run from /workspaces/phdms-poc
# Creates all web/ source files for the PHDMS Next.js frontend
set -e

echo "→ Installing web dependencies..."
cd web
pnpm add @auth0/nextjs-auth0 @tanstack/react-query @tanstack/react-query-devtools lucide-react clsx
cd ..

echo "→ Writing web source files..."

# ── .env.local.example ───────────────────────────────────────────────────────
cat > web/.env.local.example << 'EOF'
# Copy to .env.local and fill in values

# Auth0
AUTH0_SECRET=a-long-random-secret-at-least-32-chars   # openssl rand -hex 32
AUTH0_BASE_URL=http://localhost:3000
AUTH0_ISSUER_BASE_URL=https://YOUR_TENANT.auth0.com
AUTH0_CLIENT_ID=your-auth0-client-id
AUTH0_CLIENT_SECRET=your-auth0-client-secret
AUTH0_AUDIENCE=https://phdms-api

# Hono API
NEXT_PUBLIC_API_URL=http://localhost:8787
EOF

# ── src/lib/api.ts — typed API client ────────────────────────────────────────
mkdir -p web/src/lib
cat > web/src/lib/api.ts << 'EOF'
// Typed fetch wrapper for the Hono API.
// Automatically attaches the Auth0 access token from the session.

const BASE = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:8787';

async function getToken(): Promise<string | null> {
  // Called client-side: fetch the token from the Next.js /api/token relay
  try {
    const res = await fetch('/api/token');
    if (!res.ok) return null;
    const data = await res.json() as { token: string };
    return data.token;
  } catch { return null; }
}

async function request<T>(
  path: string,
  opts: RequestInit = {},
  token?: string,
): Promise<T> {
  const tok = token ?? await getToken();
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: {
      'Content-Type': 'application/json',
      ...(tok ? { Authorization: `Bearer ${tok}` } : {}),
      ...opts.headers,
    },
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText })) as { error: string };
    throw new Error(err.error ?? `HTTP ${res.status}`);
  }

  return res.json() as Promise<T>;
}

// ── Patient API ───────────────────────────────────────────────────────────────
export interface Patient {
  id: string;
  mrn: string;
  first_name: string;
  middle_name?: string;
  last_name: string;
  date_of_birth: string;
  biological_sex: string;
  blood_group: string;
  phone_primary?: string;
  email?: string;
  city?: string;
  region?: string;
  insurance_provider?: string;
  insurance_number?: string;
  known_allergies?: string[];
  chronic_conditions?: string[];
  is_deceased: boolean;
  sync_version: number;
  updated_at: string;
}

export interface PageMeta {
  page: number; limit: number; total: number; hasMore: boolean;
}

export const patientsApi = {
  list: (params?: { search?: string; page?: number; limit?: number }) => {
    const qs = new URLSearchParams();
    if (params?.search) qs.set('search', params.search);
    if (params?.page)   qs.set('page',   String(params.page));
    if (params?.limit)  qs.set('limit',  String(params.limit));
    return request<{ data: Patient[]; meta: PageMeta }>(`/v1/patients?${qs}`);
  },
  get: (id: string) =>
    request<{ data: Patient }>(`/v1/patients/${id}`),
  create: (body: Partial<Patient> & { mrn: string; first_name: string; last_name: string; date_of_birth: string }) =>
    request<{ data: Patient }>('/v1/patients', { method: 'POST', body: JSON.stringify(body) }),
  update: (id: string, body: Partial<Patient>) =>
    request<{ data: Patient }>(`/v1/patients/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
};

// ── Encounter API ─────────────────────────────────────────────────────────────
export interface Encounter {
  id: string;
  patient_id: string;
  encounter_type: string;
  status: string;
  scheduled_at?: string;
  started_at?: string;
  ended_at?: string;
  chief_complaint?: string;
  provider_name?: string;
  patient_first_name?: string;
  patient_last_name?: string;
  patient_mrn?: string;
}

export const encountersApi = {
  list: (patientId?: string) => {
    const qs = patientId ? `?patient_id=${patientId}` : '';
    return request<{ data: Encounter[] }>(`/v1/encounters${qs}`);
  },
  get: (id: string) =>
    request<{ data: Encounter & { vitals: unknown[]; diagnoses: unknown[]; medications: unknown[] } }>(`/v1/encounters/${id}`),
  create: (body: { patient_id: string; encounter_type?: string; chief_complaint?: string; scheduled_at?: string }) =>
    request<{ data: Encounter }>('/v1/encounters', { method: 'POST', body: JSON.stringify(body) }),
  updateStatus: (id: string, status: string) =>
    request<{ data: Encounter }>(`/v1/encounters/${id}`, { method: 'PATCH', body: JSON.stringify({ status }) }),
};

export const syncApi = {
  status: () => request<{ data: { pending: string; done: string; failed: string; last_sync_at: string } }>('/v1/sync/status'),
  push:   () => request<{ ok: boolean; results: unknown }>('/v1/sync/push', { method: 'POST' }),
};
EOF

# ── src/lib/utils.ts ──────────────────────────────────────────────────────────
cat > web/src/lib/utils.ts << 'EOF'
import { clsx, type ClassValue } from 'clsx';

export function cn(...inputs: ClassValue[]) { return clsx(inputs); }

export function formatDate(iso: string): string {
  return new Intl.DateTimeFormat('en-GB', { day:'2-digit', month:'short', year:'numeric' }).format(new Date(iso));
}

export function calcAge(dob: string): number {
  const diff = Date.now() - new Date(dob).getTime();
  return Math.floor(diff / (365.25 * 24 * 60 * 60 * 1000));
}

export const SEX_LABEL: Record<string, string> = {
  male:'Male', female:'Female', intersex:'Intersex', unknown:'Unknown',
};
export const BLOOD_LABEL: Record<string, string> = {
  'A+':'A+','A-':'A−','B+':'B+','B-':'B−','AB+':'AB+','AB-':'AB−','O+':'O+','O-':'O−',unknown:'?',
};
export const ENC_STATUS_COLOR: Record<string, string> = {
  scheduled:   'bg-blue-100 text-blue-700',
  checked_in:  'bg-yellow-100 text-yellow-700',
  in_progress: 'bg-orange-100 text-orange-700',
  completed:   'bg-green-100 text-green-700',
  cancelled:   'bg-gray-100 text-gray-500',
  no_show:     'bg-red-100 text-red-600',
};
EOF

# ── src/app/api/auth/[auth0]/route.ts — Auth0 handler ────────────────────────
mkdir -p web/src/app/api/auth/\[auth0\]
cat > "web/src/app/api/auth/[auth0]/route.ts" << 'EOF'
import { handleAuth } from '@auth0/nextjs-auth0';
export const GET = handleAuth();
EOF

# ── src/app/api/token/route.ts — relay access token to client ────────────────
mkdir -p web/src/app/api/token
cat > web/src/app/api/token/route.ts << 'EOF'
import { getAccessToken } from '@auth0/nextjs-auth0';
import { NextResponse }   from 'next/server';

export async function GET() {
  try {
    const { accessToken } = await getAccessToken();
    return NextResponse.json({ token: accessToken });
  } catch {
    return NextResponse.json({ token: null }, { status: 401 });
  }
}
EOF

# ── src/middleware.ts — protect all routes except /api/auth ──────────────────
cat > web/src/middleware.ts << 'EOF'
import { withMiddlewareAuthRequired } from '@auth0/nextjs-auth0/edge';

export default withMiddlewareAuthRequired();

export const config = {
  matcher: ['/((?!api/auth|_next/static|_next/image|favicon.ico).*)'],
};
EOF

# ── src/components/providers.tsx ─────────────────────────────────────────────
mkdir -p web/src/components
cat > web/src/components/providers.tsx << 'EOF'
'use client';
import { UserProvider }         from '@auth0/nextjs-auth0/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ReactQueryDevtools }   from '@tanstack/react-query-devtools';
import { useState }             from 'react';

export default function Providers({ children }: { children: React.ReactNode }) {
  const [qc] = useState(() => new QueryClient({
    defaultOptions: { queries: { staleTime: 30_000, retry: 1 } },
  }));
  return (
    <UserProvider>
      <QueryClientProvider client={qc}>
        {children}
        <ReactQueryDevtools initialIsOpen={false} />
      </QueryClientProvider>
    </UserProvider>
  );
}
EOF

# ── src/components/nav.tsx ────────────────────────────────────────────────────
cat > web/src/components/nav.tsx << 'EOF'
'use client';
import Link                from 'next/link';
import { usePathname }     from 'next/navigation';
import { useUser }         from '@auth0/nextjs-auth0/client';
import { cn }              from '@/lib/utils';
import {
  LayoutDashboard, Users, Stethoscope,
  RefreshCw, LogOut, Activity,
} from 'lucide-react';

const NAV = [
  { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard'  },
  { href: '/patients',  icon: Users,           label: 'Patients'   },
  { href: '/encounters',icon: Stethoscope,     label: 'Encounters' },
  { href: '/sync',      icon: RefreshCw,       label: 'Sync'       },
];

export default function Nav() {
  const path     = usePathname();
  const { user } = useUser();

  return (
    <aside className="fixed inset-y-0 left-0 w-56 bg-[#0B1D35] flex flex-col z-30">
      {/* Logo */}
      <div className="flex items-center gap-2 px-5 py-5 border-b border-white/10">
        <Activity className="text-[#38BDF8]" size={22} />
        <span className="text-white font-semibold tracking-wide text-sm">PHDMS</span>
      </div>

      {/* Nav links */}
      <nav className="flex-1 px-3 py-4 space-y-0.5">
        {NAV.map(({ href, icon: Icon, label }) => {
          const active = path.startsWith(href);
          return (
            <Link
              key={href}
              href={href}
              className={cn(
                'flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors',
                active
                  ? 'bg-[#38BDF8]/15 text-[#38BDF8]'
                  : 'text-slate-400 hover:text-white hover:bg-white/5',
              )}
            >
              <Icon size={17} />
              {label}
            </Link>
          );
        })}
      </nav>

      {/* User */}
      {user && (
        <div className="px-4 py-4 border-t border-white/10">
          <p className="text-xs text-slate-400 truncate mb-0.5">{user.name}</p>
          <p className="text-xs text-slate-600 truncate mb-3">{user.email}</p>
          <a
            href="/api/auth/logout"
            className="flex items-center gap-2 text-xs text-slate-400 hover:text-red-400 transition-colors"
          >
            <LogOut size={14} /> Sign out
          </a>
        </div>
      )}
    </aside>
  );
}
EOF

# ── src/app/layout.tsx ────────────────────────────────────────────────────────
cat > web/src/app/layout.tsx << 'EOF'
import type { Metadata } from 'next';
import { DM_Sans, Sora } from 'next/font/google';
import './globals.css';
import Providers from '@/components/providers';
import Nav       from '@/components/nav';

const dmSans = DM_Sans({ subsets: ['latin'], variable: '--font-body' });
const sora   = Sora({  subsets: ['latin'], variable: '--font-display', weight: ['400','500','600','700'] });

export const metadata: Metadata = {
  title: 'PHDMS — Patient Health Data',
  description: 'Patient Health Data Management System',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${dmSans.variable} ${sora.variable}`}>
      <body className="bg-slate-50 text-slate-900 font-body antialiased">
        <Providers>
          <Nav />
          <main className="ml-56 min-h-screen">
            {children}
          </main>
        </Providers>
      </body>
    </html>
  );
}
EOF

# ── src/app/globals.css ───────────────────────────────────────────────────────
cat > web/src/app/globals.css << 'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer base {
  :root {
    --font-body:    'DM Sans', sans-serif;
    --font-display: 'Sora', sans-serif;
  }
  .font-body    { font-family: var(--font-body); }
  .font-display { font-family: var(--font-display); }
}

/* Smooth page transitions */
main { animation: fadeIn 0.18s ease; }
@keyframes fadeIn { from { opacity:0; transform:translateY(4px); } to { opacity:1; transform:translateY(0); } }
EOF

# ── src/app/page.tsx — root redirect ─────────────────────────────────────────
cat > web/src/app/page.tsx << 'EOF'
import { redirect } from 'next/navigation';
export default function Root() { redirect('/dashboard'); }
EOF

# ── src/app/dashboard/page.tsx ────────────────────────────────────────────────
mkdir -p web/src/app/dashboard
cat > web/src/app/dashboard/page.tsx << 'EOF'
import { getSession }     from '@auth0/nextjs-auth0';
import { redirect }       from 'next/navigation';
import Link               from 'next/link';
import { Users, Stethoscope, RefreshCw, Plus } from 'lucide-react';

export default async function Dashboard() {
  const session = await getSession();
  if (!session) redirect('/api/auth/login');

  const user = session.user;

  const cards = [
    { icon: Users,        label: 'Patients',   href: '/patients',   color: 'text-blue-500',  bg: 'bg-blue-50'  },
    { icon: Stethoscope,  label: 'Encounters',  href: '/encounters', color: 'text-violet-500',bg: 'bg-violet-50'},
    { icon: RefreshCw,    label: 'Sync Status', href: '/sync',       color: 'text-emerald-500',bg:'bg-emerald-50'},
  ];

  return (
    <div className="p-8">
      {/* Header */}
      <div className="mb-8">
        <h1 className="font-display text-2xl font-semibold text-slate-800">
          Good {getGreeting()}, {user.given_name ?? user.name}
        </h1>
        <p className="text-slate-500 text-sm mt-1">
          {new Intl.DateTimeFormat('en-GB',{ weekday:'long', day:'numeric', month:'long', year:'numeric' }).format(new Date())}
        </p>
      </div>

      {/* Quick actions */}
      <div className="grid grid-cols-3 gap-4 mb-8">
        {cards.map(({ icon: Icon, label, href, color, bg }) => (
          <Link
            key={href}
            href={href}
            className="bg-white rounded-xl p-5 border border-slate-100 hover:border-slate-200 hover:shadow-sm transition-all group"
          >
            <div className={`${bg} ${color} w-10 h-10 rounded-lg flex items-center justify-center mb-3 group-hover:scale-105 transition-transform`}>
              <Icon size={20} />
            </div>
            <p className="font-medium text-slate-800 text-sm">{label}</p>
            <p className="text-slate-400 text-xs mt-0.5">View →</p>
          </Link>
        ))}
      </div>

      {/* CTA */}
      <div className="bg-[#0B1D35] rounded-xl p-6 flex items-center justify-between">
        <div>
          <p className="font-display font-semibold text-white text-lg">Register a new patient</p>
          <p className="text-slate-400 text-sm mt-1">Add a patient record to the clinic database</p>
        </div>
        <Link
          href="/patients/new"
          className="flex items-center gap-2 bg-[#38BDF8] hover:bg-[#0EA5E9] text-[#0B1D35] font-semibold text-sm px-4 py-2.5 rounded-lg transition-colors"
        >
          <Plus size={16} /> New Patient
        </Link>
      </div>
    </div>
  );
}

function getGreeting() {
  const h = new Date().getHours();
  if (h < 12) return 'morning';
  if (h < 17) return 'afternoon';
  return 'evening';
}
EOF

# ── src/app/patients/page.tsx ─────────────────────────────────────────────────
mkdir -p web/src/app/patients
cat > web/src/app/patients/page.tsx << 'EOF'
'use client';
import { useState }        from 'react';
import { useQuery }        from '@tanstack/react-query';
import Link                from 'next/link';
import { patientsApi }     from '@/lib/api';
import { formatDate, calcAge, SEX_LABEL, BLOOD_LABEL } from '@/lib/utils';
import { Search, Plus, ChevronLeft, ChevronRight, User } from 'lucide-react';

export default function PatientsPage() {
  const [search, setSearch] = useState('');
  const [page, setPage]     = useState(1);
  const [q, setQ]           = useState('');

  const { data, isLoading, error } = useQuery({
    queryKey: ['patients', q, page],
    queryFn:  () => patientsApi.list({ search: q, page, limit: 20 }),
  });

  const patients = data?.data ?? [];
  const meta     = data?.meta;

  return (
    <div className="p-8">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="font-display text-2xl font-semibold text-slate-800">Patients</h1>
          {meta && <p className="text-slate-400 text-sm mt-0.5">{meta.total} records</p>}
        </div>
        <Link
          href="/patients/new"
          className="flex items-center gap-2 bg-[#0B1D35] hover:bg-[#0B1D35]/90 text-white text-sm font-medium px-4 py-2.5 rounded-lg transition-colors"
        >
          <Plus size={16} /> New Patient
        </Link>
      </div>

      {/* Search */}
      <div className="relative mb-4">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={16} />
        <input
          className="w-full pl-9 pr-4 py-2.5 border border-slate-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-[#38BDF8]/40 bg-white"
          placeholder="Search by name, MRN, or phone…"
          value={search}
          onChange={e => setSearch(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter') { setQ(search); setPage(1); } }}
        />
      </div>

      {/* Table */}
      <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-slate-100 bg-slate-50/50">
              {['MRN','Patient','DOB / Age','Sex','Blood','Phone','Actions'].map(h => (
                <th key={h} className="px-4 py-3 text-left text-xs font-semibold text-slate-400 uppercase tracking-wide">{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {isLoading && (
              <tr><td colSpan={7} className="px-4 py-10 text-center text-slate-400">Loading…</td></tr>
            )}
            {error && (
              <tr><td colSpan={7} className="px-4 py-10 text-center text-red-400">Failed to load patients</td></tr>
            )}
            {!isLoading && patients.length === 0 && (
              <tr><td colSpan={7} className="px-4 py-10 text-center text-slate-400">No patients found</td></tr>
            )}
            {patients.map(p => (
              <tr key={p.id} className="border-b border-slate-50 hover:bg-slate-50/50 transition-colors">
                <td className="px-4 py-3 font-mono text-xs text-slate-500">{p.mrn}</td>
                <td className="px-4 py-3">
                  <div className="flex items-center gap-2.5">
                    <div className="w-7 h-7 rounded-full bg-[#38BDF8]/15 flex items-center justify-center flex-shrink-0">
                      <User size={13} className="text-[#0EA5E9]" />
                    </div>
                    <div>
                      <p className="font-medium text-slate-800">{p.last_name}, {p.first_name}</p>
                    </div>
                  </div>
                </td>
                <td className="px-4 py-3 text-slate-600">
                  {formatDate(p.date_of_birth)}
                  <span className="text-slate-400 ml-1">({calcAge(p.date_of_birth)}y)</span>
                </td>
                <td className="px-4 py-3 text-slate-600">{SEX_LABEL[p.biological_sex]}</td>
                <td className="px-4 py-3">
                  <span className="bg-red-50 text-red-600 text-xs font-bold px-2 py-0.5 rounded">
                    {BLOOD_LABEL[p.blood_group]}
                  </span>
                </td>
                <td className="px-4 py-3 text-slate-600">{p.phone_primary ?? '—'}</td>
                <td className="px-4 py-3">
                  <Link href={`/patients/${p.id}`} className="text-[#0EA5E9] hover:underline text-xs font-medium">
                    View →
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>

        {/* Pagination */}
        {meta && meta.total > meta.limit && (
          <div className="flex items-center justify-between px-4 py-3 border-t border-slate-100">
            <p className="text-xs text-slate-400">
              Showing {(meta.page - 1) * meta.limit + 1}–{Math.min(meta.page * meta.limit, meta.total)} of {meta.total}
            </p>
            <div className="flex gap-1">
              <button
                onClick={() => setPage(p => Math.max(1, p - 1))}
                disabled={page === 1}
                className="p-1.5 rounded hover:bg-slate-100 disabled:opacity-30 transition"
              >
                <ChevronLeft size={16} />
              </button>
              <button
                onClick={() => setPage(p => p + 1)}
                disabled={!meta.hasMore}
                className="p-1.5 rounded hover:bg-slate-100 disabled:opacity-30 transition"
              >
                <ChevronRight size={16} />
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
EOF

# ── src/app/patients/new/page.tsx ─────────────────────────────────────────────
mkdir -p web/src/app/patients/new
cat > web/src/app/patients/new/page.tsx << 'EOF'
'use client';
import { useState }    from 'react';
import { useRouter }   from 'next/navigation';
import { useMutation } from '@tanstack/react-query';
import { patientsApi } from '@/lib/api';
import { ChevronLeft, Save } from 'lucide-react';
import Link from 'next/link';

type Field = { label: string; name: string; type?: string; required?: boolean; options?: string[] };

const FIELDS: Field[] = [
  { label:'MRN *',           name:'mrn',           required:true },
  { label:'First Name *',    name:'first_name',     required:true },
  { label:'Middle Name',     name:'middle_name' },
  { label:'Last Name *',     name:'last_name',      required:true },
  { label:'Date of Birth *', name:'date_of_birth',  type:'date', required:true },
  { label:'Sex',             name:'biological_sex', options:['unknown','male','female','intersex'] },
  { label:'Blood Group',     name:'blood_group',    options:['unknown','A+','A-','B+','B-','AB+','AB-','O+','O-'] },
  { label:'Phone',           name:'phone_primary' },
  { label:'Email',           name:'email',          type:'email' },
  { label:'City',            name:'city' },
  { label:'Region',          name:'region' },
  { label:'National ID',     name:'national_id' },
  { label:'Insurance Provider', name:'insurance_provider' },
  { label:'Insurance Number',   name:'insurance_number' },
  { label:'Insurance Expiry',   name:'insurance_expiry', type:'date' },
  { label:'Emergency Contact',  name:'emergency_name' },
  { label:'Emergency Phone',    name:'emergency_phone' },
];

export default function NewPatientPage() {
  const router = useRouter();
  const [form, setForm] = useState<Record<string, string>>({
    biological_sex: 'unknown', blood_group: 'unknown',
  });
  const [error, setError] = useState('');

  const mutation = useMutation({
    mutationFn: (data: typeof form) => patientsApi.create(data as Parameters<typeof patientsApi.create>[0]),
    onSuccess: (res) => router.push(`/patients/${res.data.id}`),
    onError: (e: Error) => setError(e.message),
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    mutation.mutate(form);
  };

  return (
    <div className="p-8 max-w-3xl">
      <div className="flex items-center gap-3 mb-6">
        <Link href="/patients" className="text-slate-400 hover:text-slate-600 transition-colors">
          <ChevronLeft size={20} />
        </Link>
        <h1 className="font-display text-2xl font-semibold text-slate-800">New Patient</h1>
      </div>

      <form onSubmit={handleSubmit} className="bg-white rounded-xl border border-slate-100 p-6">
        <div className="grid grid-cols-2 gap-4">
          {FIELDS.map(({ label, name, type = 'text', required, options }) => (
            <div key={name} className={name === 'mrn' ? 'col-span-2' : ''}>
              <label className="block text-xs font-semibold text-slate-500 mb-1.5 uppercase tracking-wide">
                {label}
              </label>
              {options ? (
                <select
                  name={name}
                  value={form[name] ?? ''}
                  onChange={e => setForm(f => ({ ...f, [name]: e.target.value }))}
                  className="w-full border border-slate-200 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-[#38BDF8]/40"
                >
                  {options.map(o => <option key={o} value={o}>{o}</option>)}
                </select>
              ) : (
                <input
                  type={type}
                  name={name}
                  required={required}
                  value={form[name] ?? ''}
                  onChange={e => setForm(f => ({ ...f, [name]: e.target.value }))}
                  className="w-full border border-slate-200 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-[#38BDF8]/40"
                />
              )}
            </div>
          ))}
        </div>

        {error && (
          <div className="mt-4 bg-red-50 text-red-600 text-sm px-4 py-3 rounded-lg">{error}</div>
        )}

        <div className="flex justify-end gap-3 mt-6 pt-5 border-t border-slate-100">
          <Link
            href="/patients"
            className="px-4 py-2.5 text-sm text-slate-600 hover:text-slate-800 transition-colors"
          >
            Cancel
          </Link>
          <button
            type="submit"
            disabled={mutation.isPending}
            className="flex items-center gap-2 bg-[#0B1D35] hover:bg-[#0B1D35]/90 disabled:opacity-60 text-white text-sm font-medium px-5 py-2.5 rounded-lg transition-colors"
          >
            <Save size={15} />
            {mutation.isPending ? 'Saving…' : 'Save Patient'}
          </button>
        </div>
      </form>
    </div>
  );
}
EOF

# ── src/app/patients/[id]/page.tsx ────────────────────────────────────────────
mkdir -p "web/src/app/patients/[id]"
cat > "web/src/app/patients/[id]/page.tsx" << 'EOF'
'use client';
import { useQuery }      from '@tanstack/react-query';
import { useParams }     from 'next/navigation';
import Link              from 'next/link';
import { patientsApi, encountersApi } from '@/lib/api';
import { formatDate, calcAge, SEX_LABEL, BLOOD_LABEL, ENC_STATUS_COLOR } from '@/lib/utils';
import { ChevronLeft, User, Phone, Building2, AlertCircle } from 'lucide-react';

export default function PatientDetailPage() {
  const { id } = useParams<{ id: string }>();

  const { data: pd, isLoading } = useQuery({
    queryKey: ['patient', id],
    queryFn:  () => patientsApi.get(id),
  });

  const { data: ed } = useQuery({
    queryKey: ['encounters', id],
    queryFn:  () => encountersApi.list(id),
  });

  const patient    = pd?.data;
  const encounters = ed?.data ?? [];

  if (isLoading) return <div className="p-8 text-slate-400">Loading…</div>;
  if (!patient)  return <div className="p-8 text-red-400">Patient not found</div>;

  return (
    <div className="p-8 max-w-4xl">
      {/* Back */}
      <Link href="/patients" className="flex items-center gap-1.5 text-sm text-slate-400 hover:text-slate-600 mb-5 transition-colors">
        <ChevronLeft size={16} /> All patients
      </Link>

      {/* Patient header */}
      <div className="bg-white rounded-xl border border-slate-100 p-6 mb-4 flex items-start justify-between">
        <div className="flex items-center gap-4">
          <div className="w-14 h-14 rounded-full bg-[#38BDF8]/15 flex items-center justify-center">
            <User className="text-[#0EA5E9]" size={26} />
          </div>
          <div>
            <h1 className="font-display text-xl font-semibold text-slate-800">
              {patient.first_name} {patient.middle_name} {patient.last_name}
            </h1>
            <p className="text-slate-400 text-sm">MRN: <span className="font-mono">{patient.mrn}</span></p>
          </div>
        </div>
        <span className="bg-red-50 text-red-600 font-bold text-sm px-3 py-1 rounded-lg">
          {BLOOD_LABEL[patient.blood_group]}
        </span>
      </div>

      <div className="grid grid-cols-3 gap-4 mb-4">
        {/* Demographics */}
        <div className="col-span-2 bg-white rounded-xl border border-slate-100 p-5">
          <h2 className="font-semibold text-slate-700 text-sm mb-4">Demographics</h2>
          <dl className="grid grid-cols-2 gap-3 text-sm">
            {[
              ['Date of Birth', `${formatDate(patient.date_of_birth)} (${calcAge(patient.date_of_birth)}y)`],
              ['Sex', SEX_LABEL[patient.biological_sex]],
              ['Phone', patient.phone_primary ?? '—'],
              ['Email', patient.email ?? '—'],
              ['City', patient.city ?? '—'],
              ['Region', patient.region ?? '—'],
            ].map(([label, value]) => (
              <div key={label}>
                <dt className="text-slate-400 text-xs uppercase font-semibold tracking-wide">{label}</dt>
                <dd className="text-slate-700 mt-0.5">{value}</dd>
              </div>
            ))}
          </dl>
        </div>

        {/* Insurance */}
        <div className="bg-white rounded-xl border border-slate-100 p-5">
          <h2 className="font-semibold text-slate-700 text-sm mb-4 flex items-center gap-2">
            <Building2 size={15} className="text-slate-400" /> Insurance
          </h2>
          <dl className="space-y-3 text-sm">
            {[
              ['Provider', patient.insurance_provider],
              ['Number', patient.insurance_number],
            ].map(([l, v]) => (
              <div key={l}>
                <dt className="text-slate-400 text-xs uppercase font-semibold tracking-wide">{l}</dt>
                <dd className="text-slate-700 mt-0.5">{v ?? '—'}</dd>
              </div>
            ))}
          </dl>

          {/* Allergies */}
          {(patient.known_allergies?.length ?? 0) > 0 && (
            <div className="mt-4 pt-4 border-t border-slate-100">
              <p className="text-xs font-semibold text-slate-400 uppercase tracking-wide flex items-center gap-1.5 mb-2">
                <AlertCircle size={12} className="text-amber-500" /> Allergies
              </p>
              <div className="flex flex-wrap gap-1.5">
                {patient.known_allergies!.map(a => (
                  <span key={a} className="bg-amber-50 text-amber-700 text-xs px-2 py-0.5 rounded-full">{a}</span>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Encounters */}
      <div className="bg-white rounded-xl border border-slate-100 p-5">
        <h2 className="font-semibold text-slate-700 text-sm mb-4">Encounters</h2>
        {encounters.length === 0 ? (
          <p className="text-slate-400 text-sm">No encounters recorded.</p>
        ) : (
          <div className="space-y-2">
            {encounters.map(enc => (
              <Link
                key={enc.id}
                href={`/encounters/${enc.id}`}
                className="flex items-center justify-between p-3 rounded-lg border border-slate-100 hover:border-slate-200 hover:bg-slate-50/50 transition-all group"
              >
                <div>
                  <p className="text-sm font-medium text-slate-700 capitalize">{enc.encounter_type.replace('_',' ')}</p>
                  <p className="text-xs text-slate-400">{enc.scheduled_at ? formatDate(enc.scheduled_at) : '—'}</p>
                </div>
                <div className="flex items-center gap-3">
                  <span className={`text-xs px-2.5 py-0.5 rounded-full font-medium capitalize ${ENC_STATUS_COLOR[enc.status]}`}>
                    {enc.status.replace('_',' ')}
                  </span>
                  <span className="text-slate-300 group-hover:text-slate-400 text-xs">→</span>
                </div>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
EOF

# ── src/app/encounters/page.tsx ───────────────────────────────────────────────
mkdir -p web/src/app/encounters
cat > web/src/app/encounters/page.tsx << 'EOF'
'use client';
import { useQuery }      from '@tanstack/react-query';
import Link              from 'next/link';
import { encountersApi } from '@/lib/api';
import { formatDate, ENC_STATUS_COLOR } from '@/lib/utils';

export default function EncountersPage() {
  const { data, isLoading } = useQuery({
    queryKey: ['encounters'],
    queryFn:  () => encountersApi.list(),
  });
  const encounters = data?.data ?? [];

  return (
    <div className="p-8">
      <h1 className="font-display text-2xl font-semibold text-slate-800 mb-6">Encounters</h1>
      <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-slate-100 bg-slate-50/50">
              {['Patient','Type','Scheduled','Status','Provider',''].map(h => (
                <th key={h} className="px-4 py-3 text-left text-xs font-semibold text-slate-400 uppercase tracking-wide">{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={6} className="px-4 py-10 text-center text-slate-400">Loading…</td></tr>}
            {!isLoading && encounters.length === 0 && <tr><td colSpan={6} className="px-4 py-10 text-center text-slate-400">No encounters</td></tr>}
            {encounters.map(enc => (
              <tr key={enc.id} className="border-b border-slate-50 hover:bg-slate-50/50 transition-colors">
                <td className="px-4 py-3 font-medium text-slate-800">
                  {enc.patient_last_name}, {enc.patient_first_name}
                  <span className="text-slate-400 font-mono text-xs ml-1.5">{enc.patient_mrn}</span>
                </td>
                <td className="px-4 py-3 text-slate-600 capitalize">{enc.encounter_type?.replace('_',' ')}</td>
                <td className="px-4 py-3 text-slate-500">{enc.scheduled_at ? formatDate(enc.scheduled_at) : '—'}</td>
                <td className="px-4 py-3">
                  <span className={`text-xs px-2.5 py-0.5 rounded-full font-medium capitalize ${ENC_STATUS_COLOR[enc.status]}`}>
                    {enc.status?.replace('_',' ')}
                  </span>
                </td>
                <td className="px-4 py-3 text-slate-500">{enc.provider_name ?? '—'}</td>
                <td className="px-4 py-3">
                  <Link href={`/encounters/${enc.id}`} className="text-[#0EA5E9] hover:underline text-xs font-medium">View →</Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
EOF

# ── src/app/sync/page.tsx ─────────────────────────────────────────────────────
mkdir -p web/src/app/sync
cat > web/src/app/sync/page.tsx << 'EOF'
'use client';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { syncApi } from '@/lib/api';
import { RefreshCw, CheckCircle, XCircle, Clock } from 'lucide-react';

export default function SyncPage() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['sync-status'],
    queryFn:  syncApi.status,
    refetchInterval: 10_000,
  });

  const push = useMutation({
    mutationFn: syncApi.push,
    onSuccess:  () => qc.invalidateQueries({ queryKey: ['sync-status'] }),
  });

  const stats = data?.data;

  return (
    <div className="p-8 max-w-xl">
      <div className="flex items-center justify-between mb-6">
        <h1 className="font-display text-2xl font-semibold text-slate-800">Sync Status</h1>
        <button
          onClick={() => push.mutate()}
          disabled={push.isPending}
          className="flex items-center gap-2 bg-[#0B1D35] text-white text-sm font-medium px-4 py-2.5 rounded-lg hover:bg-[#0B1D35]/90 disabled:opacity-60 transition-colors"
        >
          <RefreshCw size={15} className={push.isPending ? 'animate-spin' : ''} />
          {push.isPending ? 'Syncing…' : 'Push Now'}
        </button>
      </div>

      {isLoading ? <p className="text-slate-400">Loading…</p> : stats && (
        <div className="grid grid-cols-2 gap-3">
          {[
            { label:'Pending',    value:stats.pending,    icon:Clock,        color:'text-yellow-500', bg:'bg-yellow-50' },
            { label:'Completed',  value:stats.done,       icon:CheckCircle,  color:'text-green-500',  bg:'bg-green-50'  },
            { label:'Failed',     value:stats.failed,     icon:XCircle,      color:'text-red-500',    bg:'bg-red-50'    },
            { label:'Last Sync',  value:stats.last_sync_at ? new Intl.DateTimeFormat('en-GB',{hour:'2-digit',minute:'2-digit'}).format(new Date(stats.last_sync_at)) : '—',
              icon:RefreshCw, color:'text-blue-500', bg:'bg-blue-50' },
          ].map(({ label, value, icon: Icon, color, bg }) => (
            <div key={label} className="bg-white rounded-xl border border-slate-100 p-5 flex items-center gap-4">
              <div className={`${bg} ${color} w-10 h-10 rounded-lg flex items-center justify-center flex-shrink-0`}>
                <Icon size={18} />
              </div>
              <div>
                <p className="text-xs text-slate-400 font-semibold uppercase tracking-wide">{label}</p>
                <p className="text-xl font-display font-semibold text-slate-800 mt-0.5">{value}</p>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
EOF

echo ""
echo "✓ Web files written successfully!"
echo ""
echo "Next steps:"
echo "  1. Copy your Auth0 credentials into web/.env.local"
echo "  2. cd /workspaces/phdms-poc && pnpm install"
echo "  3. cd web && pnpm dev"
