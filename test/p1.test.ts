import { createHmac } from 'node:crypto';
import { DateTime } from 'luxon';
import { describe, expect, it } from 'vitest';
import { createApp } from '../src/server/app.js';
import { nextDue, nextOccurrence, showFromFor } from '../src/server/recurrence.js';
import { BlockWatcher } from '../src/server/webhook.js';

const zone = 'America/Detroit';

function makePlanner() {
  const { planner } = createApp({
    dbPath: ':memory:',
    auth: { secret: 'test', secureCookies: false },
    google: { clientId: undefined, clientSecret: undefined, redirectUri: 'x' },
  });
  planner.setSettings({ timezone: zone, workDays: [1, 2, 3, 4, 5, 6, 7], workStart: '09:00', workEnd: '17:00' });
  return planner;
}

const local = (iso: string) => DateTime.fromISO(iso, { zone });
const at = (iso: string) => local(iso).toUTC().toISO()!;

describe('nextOccurrence', () => {
  it('walks weekly byDay and jumps the interval when the week is used up', () => {
    const rule = { freq: 'weekly' as const, byDay: [2, 5] }; // Tue, Fri
    const tue = local('2026-11-24T18:00');
    expect(nextOccurrence(rule, tue).toISO()).toBe(local('2026-11-27T18:00').toISO());
    expect(nextOccurrence(rule, local('2026-11-27T18:00')).toISO()).toBe(local('2026-12-01T18:00').toISO());
    const fortnightly = { ...rule, interval: 2 };
    expect(nextOccurrence(fortnightly, local('2026-11-27T18:00')).toISO()).toBe(local('2026-12-08T18:00').toISO());
  });

  it('clamps monthly byMonthDay to short months', () => {
    const rule = { freq: 'monthly' as const, byMonthDay: [31] };
    expect(nextOccurrence(rule, local('2026-10-31T12:00')).toISO()).toBe(local('2026-11-30T12:00').toISO());
    const twice = { freq: 'monthly' as const, byMonthDay: [1, 15] };
    expect(nextOccurrence(twice, local('2026-11-01T09:00')).toISO()).toBe(local('2026-11-15T09:00').toISO());
    expect(nextOccurrence(twice, local('2026-11-15T09:00')).toISO()).toBe(local('2026-12-01T09:00').toISO());
  });

  it('keeps the wall-clock time across a DST change', () => {
    const next = nextOccurrence({ freq: 'weekly' }, local('2026-10-30T09:00'));
    expect(next.toISO()).toBe(local('2026-11-06T09:00').toISO());
    expect(next.toUTC().hour).toBe(14);
  });
});

describe('nextDue', () => {
  it('skips occurrences already in the past', () => {
    const due = nextDue({ freq: 'weekly', byDay: [6] }, at('2026-11-07T12:00'), new Date(at('2026-11-23T10:00')), zone);
    expect(due).toBe(at('2026-11-28T12:00'));
  });

  it('shows a bill a few days before it is due', () => {
    expect(showFromFor({ freq: 'monthly', byMonthDay: [15], leadTimeDays: 3 }, at('2026-12-15T17:00'), zone)).toBe(at('2026-12-12T00:00'));
    expect(showFromFor({ freq: 'monthly' }, at('2026-12-15T17:00'), zone)).toBeNull();
  });
});

describe('repeating tasks', () => {
  it('queues the next instance on completion, once, and keeps the done one as history', async () => {
    const planner = makePlanner();
    const first = planner.createTask({
      title: 'Car payment',
      dueAt: at('2026-11-20T17:00'),
      recurrence: { freq: 'monthly', byMonthDay: [20], leadTimeDays: 5 },
      checklist: [{ id: 'a', text: 'Log in', done: true }],
      links: [{ label: 'Lender', url: 'https://example.com/pay' }],
    });
    expect(first.seriesId).toBe(first.id);
    await planner.updateTask(first.id, { status: 'done' });
    const series = planner.listTasks({ seriesId: first.id });
    expect(series).toHaveLength(2);
    const next = series.find((t) => t.id !== first.id)!;
    expect(next).toMatchObject({ status: 'todo', title: 'Car payment', links: first.links });
    expect(Date.parse(next.dueAt!)).toBeGreaterThan(Date.now());
    expect(local(next.dueAt!).day).toBe(20);
    expect(next.checklist).toEqual([{ id: 'a', text: 'Log in', done: false }]);
    expect(next.showFrom).toBe(showFromFor(next.recurrence, next.dueAt, zone));

    // Reopening and finishing again doesn't make a third.
    await planner.updateTask(first.id, { status: 'todo' });
    await planner.updateTask(first.id, { status: 'done' });
    expect(planner.listTasks({ seriesId: first.id })).toHaveLength(2);
  });

  it('is not scheduled before its lead time', () => {
    const planner = makePlanner();
    const due = new Date(Date.now() + 20 * 86400_000).toISOString();
    planner.createTask({ title: 'Mortgage', dueAt: due, recurrence: { freq: 'monthly', byMonthDay: [15], leadTimeDays: 3 } });
    planner.createTask({ title: 'Now', estimateMin: 30 });
    expect(planner.propose().blocks.map((b) => b.title)).toEqual(['Now']);
  });
});

describe('ignoring events', () => {
  const day = (h: number, m = 0) => DateTime.now().setZone(zone).plus({ days: 2 }).set({ hour: h, minute: m, second: 0, millisecond: 0 });
  const window = () => ({ from: day(9).toUTC().toISO()!, to: day(17).toUTC().toISO()! });
  const freeMinutes = (planner: ReturnType<typeof makePlanner>) =>
    planner.freeSlots({ ...window(), minMinutes: 15 }).reduce((s, f) => s + f.minutes, 0);

  function deviceGym(planner: ReturnType<typeof makePlanner>, startHour: number) {
    const start = day(startHour).toUTC().toISO()!;
    return planner.store.createEvent({
      title: 'Gym',
      startAt: start,
      endAt: day(startHour + 1).toUTC().toISO()!,
      source: 'device',
      externalId: `CAL:gym-series@google.com@${new Date(start).toISOString()}`,
    });
  }

  it('drops one event, a whole series, or anything matching a title', () => {
    const planner = makePlanner();
    const a = deviceGym(planner, 10);
    deviceGym(planner, 13);
    planner.store.createEvent({ title: 'Mow the lawn', startAt: day(15).toUTC().toISO()!, endAt: day(16).toUTC().toISO()!, source: 'device', externalId: 'CAL:mow' });
    expect(freeMinutes(planner)).toBe(8 * 60 - 180);

    planner.ignoreEvent(a.id, { scope: 'event', ignore: true });
    expect(freeMinutes(planner)).toBe(8 * 60 - 120);

    const { ignoredSeries } = planner.ignoreEvent(a.id, { scope: 'series', ignore: true });
    expect(ignoredSeries).toEqual(['CAL:gym-series@google.com']);
    expect(freeMinutes(planner)).toBe(8 * 60 - 60);

    planner.setSettings({ ignoreMatch: ['mow'] });
    expect(freeMinutes(planner)).toBe(8 * 60);
    expect(planner.schedulingStatus(planner.store.getEvent(a.id)!)).toBe('ignored');

    // Undoing the series brings both gym blocks back, the one-off flag included.
    planner.ignoreEvent(a.id, { scope: 'series', ignore: false });
    expect(freeMinutes(planner)).toBe(8 * 60 - 120);
  });

  it('lets busyMatch win over ignoreMatch', () => {
    const planner = makePlanner();
    planner.store.createEvent({ title: "Mr J's shift", startAt: day(11).toUTC().toISO()!, endAt: day(17).toUTC().toISO()!, source: 'device', externalId: 'CAL:shift' });
    planner.setSettings({ ignoreMatch: ['shift'], busyMatch: ["mr j's"] });
    expect(freeMinutes(planner)).toBe(120);
  });

  it('refuses to ignore a Planner task block', async () => {
    const planner = makePlanner();
    const t = planner.createTask({ title: 'Work' });
    const w = window();
    const [block] = await planner.apply([{ taskId: t.id, startAt: w.from, endAt: w.to }]);
    expect(() => planner.ignoreEvent(block.id, { scope: 'event', ignore: true })).toThrow(/task block/);
  });
});

describe('links and contacts', () => {
  it('stores them on tasks and projects and finds a task by its external ref', () => {
    const planner = makePlanner();
    const project = planner.createProject({ name: 'Salude 11', links: [{ label: 'Contract', url: 'https://example.com/c' }] });
    const t = planner.createTask({
      title: 'Content from Matt',
      status: 'waiting',
      waitingOn: 'Matt',
      contact: { name: 'Matt', email: 'matt@example.com' },
      source: 'gmail',
      externalRef: 'thread-123',
      links: [{ label: 'Email thread', url: 'https://mail.google.com/mail/u/0/#inbox/thread-123' }],
      projectId: project.id,
    });
    expect(planner.listTasks({ externalRef: 'thread-123' }).map((x) => x.id)).toEqual([t.id]);
    expect(planner.store.getTask(t.id)).toMatchObject({ contact: { name: 'Matt', email: 'matt@example.com' }, source: 'gmail' });
    expect(planner.store.getProject(project.id)!.links).toEqual(project.links);
  });
});

describe('now and block-start webhook', () => {
  async function withBlock() {
    const planner = makePlanner();
    const t = planner.createTask({
      title: 'Paint the hallway',
      checklist: [
        { id: '1', text: 'Buy paint', done: true },
        { id: '2', text: 'Tape the trim', done: false },
        { id: '3', text: 'Paint', done: false },
      ],
      links: [{ label: 'Colour', url: 'https://example.com/colour' }],
    });
    const start = Date.now() - 2 * 60_000;
    const [block] = await planner.apply([
      { taskId: t.id, startAt: new Date(start).toISOString(), endAt: new Date(start + 30 * 60_000).toISOString() },
    ]);
    const u = planner.createTask({ title: 'Invoice' });
    await planner.apply([{ taskId: u.id, startAt: new Date(start + 60 * 60_000).toISOString(), endAt: new Date(start + 90 * 60_000).toISOString() }]);
    return { planner, block, task: t, start };
  }

  it('reports the current block with its next step, and the next block', async () => {
    const { planner, task } = await withBlock();
    const now = planner.now();
    expect(now.currentBlock!.tasks[0]).toMatchObject({ id: task.id, nextStep: { text: 'Tape the trim', number: 2, of: 3 }, links: task.links });
    expect(now.currentBlock!.minutesLeft).toBe(28);
    expect(now.nextBlock!.tasks[0].title).toBe('Invoice');
    expect(now.nextBlock!.minutesUntilStart).toBe(58);
  });

  it('posts block.started once, signed', async () => {
    const { planner, block, start } = await withBlock();
    const sent: { body: string; signature: string | null }[] = [];
    const fetchFn = (async (_url: string, init: RequestInit) => {
      sent.push({ body: init.body as string, signature: new Headers(init.headers).get('x-planner-signature') });
      return new Response('ok');
    }) as typeof fetch;
    const watcher = new BlockWatcher(planner, { url: 'https://hooks.example.com/planner', secret: 's3cret', fetchFn });
    planner.store.setValue('webhook_last_check', new Date(start - 60_000).toISOString());

    const first = await watcher.tick();
    expect(first.map((p) => p.block.id)).toEqual([block.id]);
    expect(first[0].tasks[0].nextStep!.text).toBe('Tape the trim');
    expect(sent[0].signature).toBe(`sha256=${createHmac('sha256', 's3cret').update(sent[0].body).digest('hex')}`);
    expect(JSON.parse(sent[0].body).type).toBe('block.started');

    expect(await watcher.tick()).toEqual([]);
    expect(sent).toHaveLength(1);
  });
});
