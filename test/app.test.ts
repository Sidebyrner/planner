import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/server/app.js';

/** A stand-in for Google's token and Calendar endpoints. */
function fakeGoogle() {
  const events = new Map<string, any>();
  const calls: string[] = [];
  let seq = 0;
  const fetchFn = (async (input: any, init: any = {}) => {
    const url = new URL(String(input));
    const method = init.method ?? 'GET';
    calls.push(`${method} ${url.pathname}`);
    const json = (body: unknown, status = 200) => new Response(status === 204 ? null : JSON.stringify(body), { status });
    if (url.hostname === 'oauth2.googleapis.com') return json({ access_token: 'at', refresh_token: 'rt', expires_in: 3600 });
    const id = decodeURIComponent(url.pathname.split('/events/')[1] ?? '');
    if (method === 'GET') return json({ items: [...events.values()] });
    if (method === 'POST') {
      const created = { id: `g${++seq}`, status: 'confirmed', ...JSON.parse(init.body) };
      events.set(created.id, created);
      return json(created);
    }
    if (method === 'PATCH') {
      events.set(id, { ...events.get(id), ...JSON.parse(init.body) });
      return json(events.get(id));
    }
    if (method === 'DELETE') return events.delete(id) ? json(null, 204) : json({ error: { message: 'Not Found' } }, 404);
    return json({}, 400);
  }) as typeof fetch;
  return { events, calls, fetchFn };
}

let server: Server;
let base: string;
let google: ReturnType<typeof fakeGoogle>;
let cookie = '';

async function start(auth: { password?: string; mcpToken?: string } = {}) {
  google = fakeGoogle();
  const { app, planner } = createApp({
    dbPath: ':memory:',
    auth: { ...auth, secret: 'test-secret', secureCookies: false },
    google: { clientId: 'id', clientSecret: 'secret', redirectUri: 'http://localhost/api/google/callback' },
    fetchFn: google.fetchFn,
  });
  planner.setSettings({ timezone: 'America/New_York' });
  server = app.listen(0);
  base = `http://localhost:${(server.address() as AddressInfo).port}`;
  cookie = '';
  return planner;
}

async function api(method: string, path: string, body?: unknown) {
  const res = await fetch(base + path, {
    method,
    headers: { 'content-type': 'application/json', cookie },
    body: body ? JSON.stringify(body) : undefined,
    redirect: 'manual',
  });
  const set = res.headers.getSetCookie().map((c) => c.split(';')[0]);
  if (set.length) cookie = set.join('; ');
  return { status: res.status, body: (await res.json().catch(() => null)) as any, headers: res.headers };
}

beforeEach(() => start());
afterEach(() => void server.close());

const inDays = (d: number, hour: number) => {
  const t = new Date(Date.now() + d * 86400_000);
  t.setUTCHours(hour, 0, 0, 0);
  return t.toISOString();
};

describe('web API', () => {
  it('creates tasks, proposes blocks, books them, and releases them when the task is done', async () => {
    const task = (await api('POST', '/api/tasks', { title: 'Write report', estimateMin: 90 })).body;
    const proposal = (await api('POST', '/api/schedule/propose')).body;
    expect(proposal.blocks).toHaveLength(1);
    expect(proposal.blocks[0].taskId).toBe(task.id);

    const booked = (await api('POST', '/api/schedule/apply', { blocks: proposal.blocks })).body;
    expect(booked[0]).toMatchObject({ taskId: task.id, title: 'Write report' });
    // Fully booked now, so there is nothing left to propose.
    expect((await api('POST', '/api/schedule/propose')).body.blocks).toEqual([]);

    await api('PATCH', `/api/tasks/${task.id}`, { status: 'done' });
    const state = (await api('GET', '/api/state')).body;
    expect(state.tasks[0].status).toBe('done');
    expect(state.events).toEqual([]);
  });

  it('rejects bad input with a readable message', async () => {
    const r = await api('POST', '/api/events', { title: 'Backwards', startAt: inDays(1, 15), endAt: inDays(1, 14) });
    expect(r.status).toBe(400);
    expect(r.body.error).toMatch(/end after/);
    expect((await api('POST', '/api/tasks', { title: '' })).status).toBe(400);
    expect((await api('PATCH', '/api/tasks/nope', { title: 'x' })).status).toBe(404);
  });

  it('captures a typed line and can preview without saving', async () => {
    const preview = (await api('POST', '/api/capture', { text: 'Pay rent by tomorrow 15m', preview: true })).body;
    expect(preview.parsed).toMatchObject({ kind: 'task', title: 'Pay rent', estimateMin: 15 });
    expect((await api('GET', '/api/state')).body.tasks).toEqual([]);
    const saved = (await api('POST', '/api/capture', { text: 'Pay rent by tomorrow 15m' })).body;
    expect(saved.task.title).toBe('Pay rent');
  });
});

describe('login', () => {
  it('locks the API behind the password when one is set', async () => {
    server.close();
    await start({ password: 'hunter2' });
    expect((await api('GET', '/api/state')).status).toBe(401);
    expect((await api('POST', '/api/login', { password: 'wrong' })).status).toBe(401);
    expect((await api('POST', '/api/login', { password: 'hunter2' })).status).toBe(200);
    expect((await api('GET', '/api/state')).status).toBe(200);
    await api('POST', '/api/logout');
    expect((await api('GET', '/api/state')).status).toBe(401);
  });
});

describe('Google Calendar sync', () => {
  async function connect() {
    const start = await api('GET', '/api/google/connect');
    const state = new URL(start.headers.get('location')!).searchParams.get('state');
    const done = await api('GET', `/api/google/callback?code=abc&state=${state}`);
    expect(done.status).toBe(302);
  }

  it('refuses a callback whose state does not match', async () => {
    await api('GET', '/api/google/connect');
    await api('GET', '/api/google/callback?code=abc&state=forged');
    const { google: status } = (await api('GET', '/api/state')).body;
    expect(status.connected).toBe(false);
    expect(status.error).toMatch(/expired/);
  });

  it('mirrors Google events, writes local changes through, and follows deletions', async () => {
    google.events.set('gx', { id: 'gx', status: 'confirmed', summary: 'Team sync', start: { dateTime: inDays(1, 15) }, end: { dateTime: inDays(1, 16) } });
    google.events.set('gday', { id: 'gday', status: 'confirmed', summary: 'Holiday', start: { date: '2026-11-26' }, end: { date: '2026-11-27' } });
    await connect();

    let state = (await api('GET', '/api/state')).body;
    expect(state.google.connected).toBe(true);
    const mirrored = state.events.find((e: any) => e.googleId === 'gx');
    expect(mirrored).toMatchObject({ title: 'Team sync', source: 'google', allDay: false });
    if (Date.parse('2026-11-26') > Date.now() - 14 * 86400_000 && Date.parse('2026-11-26') < Date.now() + 60 * 86400_000) {
      expect(state.events.find((e: any) => e.googleId === 'gday')).toMatchObject({ allDay: true, startAt: '2026-11-26T05:00:00.000Z' });
    }

    // Created here -> appears in Google, tagged with its task.
    const task = (await api('POST', '/api/tasks', { title: 'Deep work' })).body;
    const block = (await api('POST', '/api/events', { title: 'Deep work', startAt: inDays(2, 15), endAt: inDays(2, 16), taskId: task.id })).body;
    expect(block.googleId).toBeTruthy();
    expect(google.events.get(block.googleId)).toMatchObject({ summary: 'Deep work', extendedProperties: { private: { plannerTaskId: task.id } } });

    // Moved here -> patched in Google.
    await api('PATCH', `/api/events/${block.id}`, { startAt: inDays(2, 17), endAt: inDays(2, 18) });
    expect(google.events.get(block.googleId).start.dateTime).toBe(inDays(2, 17));

    // Moved and deleted in Google -> followed on the next sync, keeping the task link.
    google.events.get(block.googleId).start = { dateTime: inDays(3, 15) };
    google.events.get(block.googleId).end = { dateTime: inDays(3, 16) };
    google.events.delete('gx');
    state = (await api('POST', '/api/google/sync')).body;
    expect(state.events.find((e: any) => e.googleId === 'gx')).toBeUndefined();
    expect(state.events.find((e: any) => e.id === block.id)).toMatchObject({ startAt: inDays(3, 15), taskId: task.id });

    // Deleted here -> deleted in Google.
    await api('DELETE', `/api/events/${block.id}`);
    expect(google.events.has(block.googleId)).toBe(false);
  });

  it('keeps the local change and records the problem when Google is down', async () => {
    // A server whose Google account is linked, but where every call to Google fails.
    server.close();
    const { app, planner } = createApp({
      dbPath: ':memory:',
      auth: { secret: 's', secureCookies: false },
      google: { clientId: 'id', clientSecret: 'secret', redirectUri: 'x' },
      fetchFn: (async () => new Response(JSON.stringify({ error: { message: 'Backend Error' } }), { status: 503 })) as typeof fetch,
    });
    planner.store.setValue('google_tokens', { accessToken: 'at', refreshToken: 'rt', expiresAt: Date.now() + 3600_000 });
    planner.store.setValue('google_last_sync', new Date().toISOString());
    server = app.listen(0);
    base = `http://localhost:${(server.address() as AddressInfo).port}`;

    const created = await api('POST', '/api/events', { title: 'Offline', startAt: inDays(1, 15), endAt: inDays(1, 16) });
    expect(created.status).toBe(200);
    expect(created.body.googleId).toBeNull();
    expect((await api('GET', '/api/state')).body.google.error).toMatch(/Backend Error/);
  });
});

describe('MCP server', () => {
  async function connectClient(token?: string) {
    const client = new Client({ name: 'test', version: '0' });
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`${base}/mcp`), {
        requestInit: token ? { headers: { authorization: `Bearer ${token}` } } : undefined,
      }),
    );
    return client;
  }
  const call = async (client: Client, name: string, args: Record<string, unknown> = {}) => {
    const res: any = await client.callTool({ name, arguments: args });
    const text = res.content[0].text;
    return res.isError ? { error: text } : JSON.parse(text);
  };

  it('lets an agent capture, plan and complete work end to end', async () => {
    const client = await connectClient();
    const tools = (await client.listTools()).tools.map((t) => t.name);
    expect(tools).toEqual(expect.arrayContaining(['get_agenda', 'create_task', 'propose_schedule', 'apply_schedule', 'find_free_slots', 'capture']));

    const task = await call(client, 'create_task', { title: 'Prep tasting menu', estimateMin: 60, priority: 3 });
    const proposal = await call(client, 'propose_schedule');
    expect(proposal.blocks[0].taskId).toBe(task.id);
    const booked = await call(client, 'apply_schedule', { blocks: proposal.blocks });
    expect(booked).toHaveLength(1);

    const agenda = await call(client, 'get_agenda');
    expect(agenda.timezone).toBe('America/New_York');
    expect(agenda.openTasks[0]).toMatchObject({ id: task.id, unscheduledMin: 0 });

    await call(client, 'update_task', { id: task.id, status: 'done' });
    expect(await call(client, 'list_tasks')).toEqual([]);
    expect(await call(client, 'list_events')).toEqual([]);

    expect(await call(client, 'delete_event', { id: 'missing' })).toEqual({ error: 'No event with id missing' });
    // The web app sees what the agent did.
    expect((await api('GET', '/api/state')).body.tasks[0].status).toBe('done');
  });

  it('requires the bearer token when one is configured', async () => {
    server.close();
    await start({ mcpToken: 'agent-token' });
    await expect(connectClient()).rejects.toThrow();
    await expect(connectClient('wrong')).rejects.toThrow();
    const client = await connectClient('agent-token');
    expect((await client.listTools()).tools.length).toBeGreaterThan(10);
  });
});
