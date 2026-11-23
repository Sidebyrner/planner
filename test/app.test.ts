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

  it('refuses to plan until the timezone is known, then plans once it is set', async () => {
    const planner = await start();
    planner.setSettings({ timezone: 'UTC', timezoneConfirmed: false });
    await api('POST', '/api/tasks', { title: 'Write report', estimateMin: 60 });
    const refused = await api('POST', '/api/schedule/propose');
    expect(refused.status).toBe(409);
    expect(refused.body.error).toMatch(/timezone/);
    await api('PUT', '/api/settings', { timezone: 'America/Detroit', timezoneConfirmed: true });
    expect((await api('POST', '/api/schedule/propose')).status).toBe(200);
  });

  it('saves per-day working hours and busy rules, and rejects a backwards range', async () => {
    await start();
    const workHours = [{ days: [7, 1, 2, 3, 4], start: '09:00', end: '10:50', mode: 'quick' }];
    const saved = (await api('PUT', '/api/settings', { workHours, busyMatch: ["Mr J's shift"] })).body;
    expect(saved.workHours).toEqual(workHours);
    expect(saved.busyMatch).toEqual(["Mr J's shift"]);
    const bad = await api('PUT', '/api/settings', { workHours: [{ days: [1], start: '17:00', end: '09:00' }] });
    expect(bad.status).toBe(400);
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

describe('projects, waiting-on and batches', () => {
  it('creates, renames, archives and deletes projects', async () => {
    const created = (await api('POST', '/api/projects', { name: "Mr Smith's Bar", emoji: '🍺', color: 'amber' })).body;
    expect(created).toMatchObject({ tag: 'mr-smiths-bar', archived: false, windows: [] });
    expect((await api('POST', '/api/projects', { name: 'Again', tag: 'mr-smiths-bar' })).body.error).toMatch(/already a project/);

    const renamed = (await api('PATCH', `/api/projects/${created.id}`, { tag: 'bar', windows: [{ days: [6, 7], start: '10:00', end: '12:00' }] })).body;
    expect(renamed).toMatchObject({ tag: 'bar', windows: [{ days: [6, 7], start: '10:00', end: '12:00' }] });
    expect((await api('PATCH', `/api/projects/${created.id}`, { windows: [{ days: [1], start: '12:00', end: '10:00' }] })).status).toBe(400);

    // In use: archived, not deleted.
    await api('POST', '/api/tasks', { title: 'Order kegs', projectId: created.id });
    expect((await api('DELETE', `/api/projects/${created.id}`)).body).toEqual({ result: 'archived' });
    const empty = (await api('POST', '/api/projects', { name: 'Empty' })).body;
    expect((await api('DELETE', `/api/projects/${empty.id}`)).body).toEqual({ result: 'deleted' });
    expect((await api('GET', '/api/state')).body.projects.map((p: any) => [p.tag, p.archived])).toEqual([['bar', true]]);
  });

  it('captures #tags into projects, creating unknown ones', async () => {
    const bar = (await api('POST', '/api/projects', { name: 'Bar', tag: 'bar' })).body;
    const preview = (await api('POST', '/api/capture', { text: 'Order kegs #bar 15m', preview: true })).body.parsed;
    expect(preview).toMatchObject({ title: 'Order kegs', projectId: bar.id, newProject: null, estimateMin: 15 });

    const fresh = (await api('POST', '/api/capture', { text: 'Update CV #career by Friday' })).body;
    expect(fresh.parsed).toMatchObject({ newProject: 'career', projectId: null });
    expect(fresh.project).toMatchObject({ tag: 'career' });
    expect(fresh.task.projectId).toBe(fresh.project.id);

    // A unique prefix is enough once the project exists.
    expect((await api('POST', '/api/capture', { text: 'Print menus #ba', preview: true })).body.parsed.projectId).toBe(bar.id);
  });

  it('captures @Name as a waiting task that is never scheduled and comes back on its follow-up date', async () => {
    server.close();
    const planner = await start();
    const { task } = (await api('POST', '/api/capture', { text: '@Sam send the invoice tomorrow' })).body;
    expect(task).toMatchObject({ title: 'send the invoice', status: 'waiting', waitingOn: 'Sam', dueAt: null });
    expect(Date.parse(task.followUpAt)).toBeGreaterThan(Date.now());
    expect((await api('POST', '/api/schedule/propose')).body.blocks).toEqual([]);

    planner.store.updateTask(task.id, { followUpAt: new Date(Date.now() - 60_000).toISOString() });
    const back = (await api('GET', '/api/state')).body.tasks.find((t: any) => t.id === task.id);
    expect(back).toMatchObject({ status: 'todo', waitingOn: 'Sam' });
  });

  it('releases booked time when a task is handed to someone else', async () => {
    const task = (await api('POST', '/api/tasks', { title: 'Write report', estimateMin: 60 })).body;
    const proposal = (await api('POST', '/api/schedule/propose')).body;
    await api('POST', '/api/schedule/apply', { blocks: proposal.blocks });
    expect((await api('GET', '/api/state')).body.events).toHaveLength(1);
    await api('PATCH', `/api/tasks/${task.id}`, { status: 'waiting', waitingOn: 'Alex' });
    const state = (await api('GET', '/api/state')).body;
    expect(state.events).toEqual([]);
    expect(state.tasks[0]).toMatchObject({ status: 'waiting', waitingOn: 'Alex' });
    expect(state.tasks[0].followUpAt).toBeTruthy();
  });

  it('books a Quick batch and removes it only when every task in it is finished', async () => {
    const bar = (await api('POST', '/api/projects', { name: 'Bar', tag: 'bar' })).body;
    const ids: string[] = [];
    for (const title of ['Order limes', 'Order mix', 'Call rep']) {
      ids.push((await api('POST', '/api/tasks', { title, estimateMin: 15, projectId: bar.id })).body.id);
    }
    const proposal = (await api('POST', '/api/schedule/propose')).body;
    expect(proposal.blocks).toHaveLength(1);
    expect(proposal.blocks[0]).toMatchObject({ title: 'Quick: 3 tasks', projectId: bar.id });

    const [batch] = (await api('POST', '/api/schedule/apply', { blocks: proposal.blocks })).body;
    expect(batch).toMatchObject({ title: 'Quick: 3 tasks', taskId: null, projectId: bar.id });
    expect(batch.taskIds.sort()).toEqual([...ids].sort());
    expect((await api('POST', '/api/schedule/propose')).body.blocks).toEqual([]);

    await api('PATCH', `/api/tasks/${ids[0]}`, { status: 'done' });
    await api('DELETE', `/api/tasks/${ids[1]}`);
    let events = (await api('GET', '/api/state')).body.events;
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ title: 'Quick: 2 tasks' });
    expect(events[0].taskIds.sort()).toEqual([ids[0], ids[2]].sort());

    await api('PATCH', `/api/tasks/${ids[2]}`, { status: 'done' });
    events = (await api('GET', '/api/state')).body.events;
    expect(events).toEqual([]);
  });

  it('keeps checklists and colours blocks by their task\'s project', async () => {
    const p = (await api('POST', '/api/projects', { name: 'Home', color: 'green' })).body;
    const t = (await api('POST', '/api/tasks', { title: 'Paint', projectId: p.id, checklist: [{ id: 'a', text: 'Primer', done: false }] })).body;
    expect(t.checklist).toEqual([{ id: 'a', text: 'Primer', done: false }]);
    const block = (await api('POST', '/api/events', { title: 'Paint', startAt: inDays(1, 15), endAt: inDays(1, 16), taskId: t.id })).body;
    expect(block.projectId).toBe(p.id);
    const other = (await api('POST', '/api/projects', { name: 'Other' })).body;
    await api('PATCH', `/api/tasks/${t.id}`, { projectId: other.id });
    expect((await api('GET', '/api/state')).body.events[0].projectId).toBe(other.id);
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
    expect(tools).toEqual(expect.arrayContaining(['get_agenda', 'create_task', 'propose_schedule', 'apply_schedule', 'find_free_slots', 'capture', 'get_now', 'ignore_event', 'update_settings']));

    const task = await call(client, 'create_task', { title: 'Prep tasting menu', estimateMin: 60, priority: 3 });
    const proposal = await call(client, 'propose_schedule');
    expect(proposal.blocks[0].taskId).toBe(task.id);
    const booked = await call(client, 'apply_schedule', { blocks: proposal.blocks });
    expect(booked).toHaveLength(1);

    const agenda = await call(client, 'get_agenda');
    expect(agenda.timezone).toBe('America/New_York');
    expect(agenda.openTasksByProject[0].tasks[0]).toMatchObject({ id: task.id, unscheduledMin: 0 });

    await call(client, 'update_task', { id: task.id, status: 'done' });
    expect(await call(client, 'list_tasks')).toEqual([]);
    expect(await call(client, 'list_events')).toEqual([]);

    expect(await call(client, 'delete_event', { id: 'missing' })).toEqual({ error: 'No event with id missing' });
    // The web app sees what the agent did.
    expect((await api('GET', '/api/state')).body.tasks[0].status).toBe('done');
  });

  it('groups follow-ups by person and marks blocks over MCP', async () => {
    const client = await connectClient();
    const past = new Date(Date.now() - 3 * 86400_000).toISOString();
    const later = new Date(Date.now() + 3 * 86400_000).toISOString();
    await call(client, 'create_task', { title: 'Salude content', waitingOn: 'Matt', followUpAt: past, contact: { name: 'Matt', email: 'matt@example.com' } });
    await call(client, 'create_task', { title: 'Menu photos', waitingOn: 'matt', followUpAt: later });
    await call(client, 'create_task', { title: 'Quote', waitingOn: 'Daryl', followUpAt: later });
    const review = await call(client, 'weekly_review');
    expect(review.followUpsByPerson.map((p: any) => [p.person, p.overdue.length, p.pending.length])).toEqual([
      ['Matt', 1, 1],
      ['Daryl', 0, 1],
    ]);
    expect(review.followUpsByPerson[0]).toMatchObject({ contact: { email: 'matt@example.com' } });
    expect(review.followUpsByPerson[0].overdue[0].daysPast).toBe(3);

    const task = await call(client, 'create_task', { title: 'Draft deck', estimateMin: 90 });
    const start = Date.now() - 2 * 3600_000;
    const [block] = await call(client, 'apply_schedule', {
      blocks: [{ taskId: task.id, startAt: new Date(start).toISOString(), endAt: new Date(start + 3600_000).toISOString() }],
    });
    expect((await call(client, 'get_agenda')).toReview.map((b: any) => b.id)).toEqual([block.id]);
    const marked = await call(client, 'mark_block', { id: block.id, outcome: 'done' });
    expect(marked.tasks[0].estimateMin).toBe(30);
  });

  it('works with projects, checklists and waiting-on by name', async () => {
    const client = await connectClient();
    const project = await call(client, 'create_project', { name: 'Side work', emoji: '💼', color: 'indigo' });
    expect(project).toMatchObject({ tag: 'side-work', color: 'indigo' });

    const task = await call(client, 'create_task', { title: 'Send proposal', project: '#side-work', checklist: ['Draft', 'Price it', 'Send'] });
    expect(task.projectId).toBe(project.id);
    expect(task.checklist.map((c: any) => c.text)).toEqual(['Draft', 'Price it', 'Send']);
    const checked = await call(client, 'check_item', { id: task.id, item: 'price' });
    expect(checked.checklist.map((c: any) => c.done)).toEqual([false, true, false]);

    const ask = await call(client, 'create_task', { title: 'Confirm the invoice', waitingOn: 'Sam', project: 'Side work' });
    expect(ask).toMatchObject({ status: 'waiting', waitingOn: 'Sam' });
    expect(ask.followUpAt).toBeTruthy();
    expect((await call(client, 'list_waiting')).waiting.map((t: any) => t.id)).toEqual([ask.id]);

    const overview = await call(client, 'get_project', { project: 'side' });
    expect(overview.open.map((t: any) => t.id)).toEqual([task.id]);
    expect(overview.waiting.map((t: any) => t.id)).toEqual([ask.id]);
    expect((await call(client, 'get_project', { project: '#nope' })).error).toMatch(/No project matches/);

    const week = await call(client, 'plan_week');
    expect(week.byProject[0]).toMatchObject({ project: '💼 Side work (#side-work)', blocks: 1 });
    expect((await call(client, 'weekly_review')).waiting).toBe(1);
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

describe('device sync (iOS and macOS apps)', () => {
  const window = () => ({ from: inDays(-1, 0), to: inDays(30, 0) });
  const sync = (body: Record<string, unknown>, token = 'device-token') =>
    fetch(`${base}/api/device/events`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ ...window(), events: [], ...body }),
    }).then(async (r) => ({ status: r.status, body: (await r.json()) as any }));

  beforeEach(async () => {
    server.close();
    await start({ password: 'pw' });
  });

  it('accepts only the device token, and only when one is configured', async () => {
    expect((await sync({})).status).toBe(401); // no DEVICE_TOKEN on this server
    server.close();
    await startWithDevice();
    expect((await sync({}, 'wrong')).status).toBe(401);
    expect((await sync({})).status).toBe(200);
  });

  async function startWithDevice() {
    google = fakeGoogle();
    const { app, planner } = createApp({
      dbPath: ':memory:',
      auth: { password: 'pw', deviceToken: 'device-token', secret: 's', secureCookies: false },
      google: { redirectUri: 'x' },
      fetchFn: google.fetchFn,
    });
    planner.setSettings({ timezone: 'UTC', workDays: [1, 2, 3, 4, 5, 6, 7], workStart: '00:00', workEnd: '23:59' });
    server = app.listen(0);
    base = `http://localhost:${(server.address() as AddressInfo).port}`;
    return planner;
  }

  it('mirrors device events, updates and removes them, and keeps them read-only', async () => {
    const planner = await startWithDevice();
    const dentist = { externalId: 'ek-1', title: 'Dentist', startAt: inDays(1, 15), endAt: inDays(1, 16) };
    let r = await sync({ events: [dentist, { externalId: 'ek-2', title: 'Gym', startAt: inDays(2, 7), endAt: inDays(2, 8) }] });
    expect(r.body).toMatchObject({ upserted: 2, removed: 0, blocks: [] });
    let mirrored = planner.listEvents().filter((e) => e.source === 'device');
    expect(mirrored.map((e) => e.title).sort()).toEqual(['Dentist', 'Gym']);

    // Moved on the phone, Gym deleted on the phone.
    r = await sync({ events: [{ ...dentist, startAt: inDays(1, 17), endAt: inDays(1, 18) }] });
    expect(r.body).toMatchObject({ upserted: 1, removed: 1 });
    mirrored = planner.listEvents().filter((e) => e.source === 'device');
    expect(mirrored).toHaveLength(1);
    expect(mirrored[0]).toMatchObject({ title: 'Dentist', startAt: inDays(1, 17), externalId: 'ek-1' });

    // Planner refuses to edit what the device owns.
    await expect(planner.updateEvent(mirrored[0].id, { title: 'x' })).rejects.toThrow(/Change it there/);
  });

  it('schedules around device events and returns blocks for the Planner calendar', async () => {
    const planner = await startWithDevice();
    // Starts in the past so no sliver of time before it is free.
    const busyStart = new Date(Math.floor(Date.now() / 3600_000) * 3600_000 - 3600_000);
    const busyEnd = new Date(busyStart.getTime() + 30 * 86400_000);
    // The device says the next 30 days are booked solid except a gap starting 2 days out.
    const gap = new Date(busyStart.getTime() + 2 * 86400_000);
    await sync({
      events: [
        { externalId: 'a', title: 'Busy', startAt: busyStart.toISOString(), endAt: gap.toISOString() },
        { externalId: 'b', title: 'Busy', startAt: new Date(gap.getTime() + 3600_000).toISOString(), endAt: busyEnd.toISOString() },
      ],
    });
    const task = planner.createTask({ title: 'Write report', estimateMin: 60 });
    const { created } = await planner.autoSchedule();
    expect(created).toHaveLength(1);
    expect(created[0].startAt).toBe(gap.toISOString());

    const r = await sync({});
    // The mirror is now empty, but the booked block is still reported for the app to write.
    expect(r.body.blocks).toHaveLength(1);
    expect(r.body.blocks[0]).toMatchObject({ taskId: task.id, title: 'Write report' });
  });

  it('returns events created in Planner, not only task blocks, for the Planner calendar', async () => {
    const planner = await startWithDevice();
    const task = planner.createTask({ title: 'Deep work', estimateMin: 60 });
    const block = await planner.createEvent({ title: 'Deep work', startAt: inDays(1, 9), endAt: inDays(1, 10), taskId: task.id });
    const { event: dentist } = await planner.capture('Dentist tomorrow 3pm');
    await sync({ events: [{ externalId: 'ek-1', title: 'From the phone', startAt: inDays(2, 9), endAt: inDays(2, 10) }] });

    const r = await sync({ events: [{ externalId: 'ek-1', title: 'From the phone', startAt: inDays(2, 9), endAt: inDays(2, 10) }] });
    expect(r.body.blocks.map((e: any) => e.id).sort()).toEqual([block.id, dentist!.id].sort());
    expect(r.body.blocks.find((e: any) => e.id === dentist!.id)).toMatchObject({ title: 'Dentist', taskId: null, source: 'local' });
  });

  it('applies Planner events the user moved or deleted in Apple Calendar', async () => {
    const planner = await startWithDevice();
    const task = planner.createTask({ title: 'Deep work', estimateMin: 120 });
    const a = await planner.createEvent({ title: 'Deep work', startAt: inDays(1, 9), endAt: inDays(1, 10), taskId: task.id });
    const b = await planner.createEvent({ title: 'Deep work', startAt: inDays(2, 9), endAt: inDays(2, 10), taskId: task.id });
    const lunch = await planner.createEvent({ title: 'Lunch', startAt: inDays(1, 12), endAt: inDays(1, 13) });
    const call = await planner.createEvent({ title: 'Call Sam', startAt: inDays(3, 12), endAt: inDays(3, 13) });
    await sync({ events: [{ externalId: 'ek-1', title: 'Phone event', startAt: inDays(4, 9), endAt: inDays(4, 10) }] });
    const mirrored = planner.listEvents().find((e) => e.source === 'device')!;

    const r = await sync({
      events: [{ externalId: 'ek-1', title: 'Phone event', startAt: inDays(4, 9), endAt: inDays(4, 10) }],
      blockChanges: [
        { id: a.id, startAt: inDays(1, 14), endAt: inDays(1, 15) },
        { id: b.id, deleted: true },
        { id: lunch.id, deleted: true },
        { id: call.id, startAt: inDays(3, 16), endAt: inDays(3, 17) },
        { id: mirrored.id, deleted: true },
        { id: 'gone', deleted: true },
      ],
    });
    expect(r.body.blocks.map((e: any) => [e.id, e.startAt]).sort()).toEqual(
      [
        [a.id, inDays(1, 14)],
        [call.id, inDays(3, 16)],
      ].sort(),
    );
    expect(r.body.rejected).toEqual([{ id: mirrored.id, reason: 'Not an event created in Planner.' }]);
    expect(planner.listEvents().find((e) => e.id === lunch.id)).toBeUndefined();
    expect(planner.listEvents().find((e) => e.id === mirrored.id)).toBeTruthy();
  });

  it('rejects malformed input', async () => {
    await startWithDevice();
    expect((await sync({ events: [{ title: 'no id', startAt: inDays(1, 1), endAt: inDays(1, 2) }] })).status).toBe(400);
    expect((await sync({ from: inDays(2, 0), to: inDays(1, 0) })).status).toBe(400);
  });
});
