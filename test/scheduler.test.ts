import { describe, expect, it } from 'vitest';
import { findFreeSlots, proposeSchedule } from '../src/server/scheduler.js';
import { DEFAULT_SETTINGS } from '../src/server/store.js';
import type { CalEvent, Project, Task } from '../src/shared/types.js';

const settings = { ...DEFAULT_SETTINGS, timezone: 'America/New_York' };
// Monday 2026-11-23, 08:00 in New York (EST, UTC-5)
const now = new Date('2026-11-23T13:00:00Z');

let n = 0;
const task = (p: Partial<Task>): Task => ({
  id: `t${++n}`, title: `Task ${n}`, notes: '', status: 'todo', priority: 2, estimateMin: 60,
  dueAt: null, createdAt: `2026-11-20T00:00:0${n % 10}Z`, completedAt: null,
  projectId: null, checklist: [], waitingOn: null, followUpAt: null,
  links: [], contact: null, source: null, externalRef: null, recurrence: null, seriesId: null, showFrom: null,
  waitingSince: null, repliedAt: null, replySnippet: null, ...p,
});
const event = (startAt: string, endAt: string, p: Partial<CalEvent> = {}): CalEvent => ({
  id: `e${++n}`, title: 'Meeting', notes: '', startAt, endAt, allDay: false, taskId: null, googleId: null, externalId: null,
  source: 'local', projectId: null, taskIds: [], ignored: false, outcome: null, ...p,
});
const project = (p: Partial<Project>): Project => ({
  id: `p${++n}`, name: 'Project', tag: `p${n}`, color: 'teal', emoji: '', archived: false, sortOrder: 0,
  windows: [], windowStrict: false, hostMatch: null, links: [], ...p,
});
const minutes = (b: { startAt: string; endAt: string }) => (Date.parse(b.endAt) - Date.parse(b.startAt)) / 60000;

describe('proposeSchedule', () => {
  it('starts at the beginning of working hours in the user timezone', () => {
    const { blocks } = proposeSchedule({ tasks: [task({})], events: [], settings, now });
    expect(blocks).toHaveLength(1);
    expect(blocks[0].startAt).toBe('2026-11-23T14:00:00.000Z'); // 09:00 EST
    expect(blocks[0].endAt).toBe('2026-11-23T15:00:00.000Z');
  });

  it('works around existing events and never overlaps them', () => {
    const meeting = event('2026-11-23T14:30:00Z', '2026-11-23T16:00:00Z');
    const { blocks } = proposeSchedule({ tasks: [task({ estimateMin: 60 })], events: [meeting], settings, now });
    // 09:00-09:30 is free but too short to hold the hour, so it lands after the meeting.
    expect(blocks[0].startAt).toBe('2026-11-23T16:00:00.000Z');
  });

  it('puts the earliest deadline first, then the higher priority', () => {
    const later = task({ title: 'later', dueAt: '2026-11-27T22:00:00Z' });
    const sooner = task({ title: 'sooner', dueAt: '2026-11-24T22:00:00Z' });
    const urgent = task({ title: 'urgent', priority: 3 });
    const normal = task({ title: 'normal' });
    const { blocks } = proposeSchedule({ tasks: [normal, urgent, later, sooner], events: [], settings, now });
    expect(blocks.map((b) => b.title)).toEqual(['sooner', 'later', 'urgent', 'normal']);
  });

  it('splits long work into blocks no longer than the maximum', () => {
    const { blocks, unscheduled } = proposeSchedule({ tasks: [task({ estimateMin: 300 })], events: [], settings, now });
    expect(unscheduled).toEqual([]);
    const minutes = blocks.map((b) => (Date.parse(b.endAt) - Date.parse(b.startAt)) / 60000);
    expect(minutes).toEqual([120, 120, 60]);
  });

  it('only schedules what existing future blocks do not already cover', () => {
    const t = task({ estimateMin: 90 });
    const booked = event('2026-11-23T19:00:00Z', '2026-11-23T20:00:00Z', { taskId: t.id });
    const { blocks } = proposeSchedule({ tasks: [t], events: [booked], settings, now });
    expect(blocks).toHaveLength(1);
    expect((Date.parse(blocks[0].endAt) - Date.parse(blocks[0].startAt)) / 60000).toBe(30);
  });

  it('stacks blocks in one day when that is the only way to make the deadline', () => {
    const t = task({ estimateMin: 240, dueAt: '2026-11-23T22:00:00Z' }); // due today 17:00
    const { blocks } = proposeSchedule({ tasks: [t], events: [], settings, now });
    expect(blocks.map((b) => b.late)).toEqual([false, false]);
    expect(blocks[1].endAt).toBe('2026-11-23T18:00:00.000Z');
  });

  it('skips weekends and flags blocks that end after the due time', () => {
    const friday5pm = new Date('2026-11-27T22:00:00Z');
    const t = task({ dueAt: '2026-11-28T15:00:00Z' }); // Saturday morning
    const { blocks } = proposeSchedule({ tasks: [t], events: [], settings, now: friday5pm });
    expect(blocks[0].startAt).toBe('2026-11-30T14:00:00.000Z'); // Monday 09:00
    expect(blocks[0].late).toBe(true);
  });

  it('reports tasks that do not fit inside the horizon', () => {
    const { unscheduled } = proposeSchedule({
      tasks: [task({ estimateMin: 600 })], events: [], settings: { ...settings, horizonDays: 1 }, now,
    });
    expect(unscheduled[0].remainingMin).toBe(120);
  });

  it('ignores done tasks and all-day events', () => {
    const allDay = event('2026-11-23T05:00:00Z', '2026-11-24T05:00:00Z', { allDay: true });
    const { blocks } = proposeSchedule({ tasks: [task({ status: 'done' }), task({})], events: [allDay], settings, now });
    expect(blocks).toHaveLength(1);
    expect(blocks[0].startAt).toBe('2026-11-23T14:00:00.000Z');
  });
});

describe('projects, batches and buffers', () => {
  // Tuesday 06:45–07:45 New York = 11:45–12:45 UTC.
  const early = { days: [2], start: '06:45', end: '07:45' };
  const short = { ...settings, horizonDays: 3 };

  it('places a project task inside its window', () => {
    const p = project({ windows: [early] });
    const { blocks } = proposeSchedule({ tasks: [task({ projectId: p.id })], events: [], settings: short, projects: [p], now });
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ startAt: '2026-11-24T11:45:00.000Z', endAt: '2026-11-24T12:45:00.000Z', projectId: p.id });
    expect(blocks[0].outsideWindow).toBeUndefined();
  });

  it('falls back to working hours when the window is full, unless the project is strict', () => {
    const loose = project({ windows: [early] });
    const tasks = [
      task({ projectId: loose.id, createdAt: '2026-11-01T00:00:00Z' }),
      task({ projectId: loose.id, createdAt: '2026-11-02T00:00:00Z' }),
    ];
    const { blocks } = proposeSchedule({ tasks, events: [], settings: short, projects: [loose], now });
    expect(blocks.map((b) => [b.startAt, !!b.outsideWindow])).toEqual([
      ['2026-11-23T14:00:00.000Z', true],
      ['2026-11-24T11:45:00.000Z', false],
    ]);

    const strict = { ...loose, windowStrict: true };
    const strictRun = proposeSchedule({ tasks, events: [], settings: short, projects: [strict], now });
    expect(strictRun.blocks).toHaveLength(1);
    expect(strictRun.unscheduled).toEqual([{ taskId: tasks[1].id, title: tasks[1].title, remainingMin: 60 }]);
  });

  it('uses calendar events matching hostMatch as the project\'s own time', () => {
    const p = project({ hostMatch: 'career block' });
    // 06:00–08:00 Tuesday, a recurring block the user already keeps on their calendar.
    const host = event('2026-11-24T11:00:00Z', '2026-11-24T13:00:00Z', { title: 'Morning Career Block', source: 'device' });
    const mine = task({ projectId: p.id });
    const other = task({});
    const { blocks } = proposeSchedule({ tasks: [mine, other], events: [host], settings: short, projects: [p], now });
    expect(blocks.find((b) => b.taskId === mine.id)?.startAt).toBe('2026-11-24T11:00:00.000Z');
    // Everyone else still treats the host event as busy, and works in normal hours.
    expect(blocks.find((b) => b.taskId === other.id)?.startAt).toBe('2026-11-23T14:00:00.000Z');
  });

  it('batches short tasks of the same project into one Quick block', () => {
    const p = project({});
    const quick = [1, 2, 3].map((i) => task({ projectId: p.id, estimateMin: 15, createdAt: `2026-11-0${i}T00:00:00Z` }));
    const loner = task({ estimateMin: 15, createdAt: '2026-11-09T00:00:00Z' });
    const { blocks } = proposeSchedule({ tasks: [...quick, loner], events: [], settings, projects: [p], now });
    const batch = blocks.find((b) => b.taskIds);
    expect(batch).toMatchObject({ title: 'Quick: 3 tasks', startAt: '2026-11-23T14:00:00.000Z', projectId: p.id });
    expect(batch!.taskIds!.sort()).toEqual(quick.map((t) => t.id).sort());
    expect(minutes(batch!)).toBe(45);
    expect(blocks.find((b) => b.taskId === loner.id && !b.taskIds)).toBeTruthy();
  });

  it('treats tasks in a booked batch as scheduled', () => {
    const [a, b] = [task({ estimateMin: 15 }), task({ estimateMin: 15 })];
    const booked = event('2026-11-23T19:00:00Z', '2026-11-23T19:30:00Z', { taskIds: [a.id, b.id], title: 'Quick: 2 tasks' });
    expect(proposeSchedule({ tasks: [a, b], events: [booked], settings, now }).blocks).toEqual([]);
  });

  it('keeps a buffer around long fixed events only', () => {
    const buffered = { ...settings, bufferMin: 30, bufferMinEventMin: 120 };
    const shift = event('2026-11-23T14:00:00Z', '2026-11-23T17:00:00Z', { title: 'Shift', source: 'device' });
    expect(proposeSchedule({ tasks: [task({})], events: [shift], settings: buffered, now }).blocks[0].startAt).toBe('2026-11-23T17:30:00.000Z');
    const call = event('2026-11-23T14:00:00Z', '2026-11-23T15:00:00Z', { title: 'Call' });
    expect(proposeSchedule({ tasks: [task({})], events: [call], settings: buffered, now }).blocks[0].startAt).toBe('2026-11-23T15:00:00.000Z');
  });
});

describe('findFreeSlots', () => {
  it('returns the gaps between events inside working hours', () => {
    const slots = findFreeSlots([event('2026-11-23T15:00:00Z', '2026-11-23T16:00:00Z')], settings, {
      from: now, to: new Date('2026-11-24T05:00:00Z'),
    });
    expect(slots.map((s) => [s.startAt, s.minutes])).toEqual([
      ['2026-11-23T14:00:00.000Z', 60],
      ['2026-11-23T16:00:00.000Z', 360],
    ]);
  });
});

describe('timezone', () => {
  const detroit = { ...DEFAULT_SETTINGS, timezone: 'America/Detroit', timezoneConfirmed: true };
  it('reads a 9:00 start in the user timezone in winter and summer', () => {
    const winter = proposeSchedule({ tasks: [task({})], events: [], settings: detroit, now: new Date('2026-11-25T12:00:00Z') });
    expect(winter.blocks[0].startAt).toBe('2026-11-25T14:00:00.000Z'); // 09:00 EST
    const summer = proposeSchedule({ tasks: [task({})], events: [], settings: detroit, now: new Date('2026-07-15T11:00:00Z') });
    expect(summer.blocks[0].startAt).toBe('2026-07-15T13:00:00.000Z'); // 09:00 EDT
  });
});

describe('per-day working hours', () => {
  // Sun–Thu: 09:00–10:50 before the shift; Fri and Sat: 09:00–17:00. Monday 2026-11-23 in New York.
  const shiftWeek = {
    ...settings,
    workHours: [
      { days: [7, 1, 2, 3, 4], start: '09:00', end: '10:50' },
      { days: [5, 6], start: '09:00', end: '17:00' },
    ],
  };

  it('uses each day\'s own range and the weekend', () => {
    const slots = findFreeSlots([], shiftWeek, { from: now, to: new Date('2026-11-29T05:00:00Z') });
    const mon = slots.find((s) => s.startAt.startsWith('2026-11-23'))!;
    expect(mon).toMatchObject({ startAt: '2026-11-23T14:00:00.000Z', endAt: '2026-11-23T15:50:00.000Z' });
    const sat = slots.find((s) => s.startAt.startsWith('2026-11-28'))!;
    expect(sat).toMatchObject({ startAt: '2026-11-28T14:00:00.000Z', endAt: '2026-11-28T22:00:00.000Z' });
  });

  it('keeps quick ranges for short work only', () => {
    const quickGap = {
      ...settings,
      workHours: [
        { days: [1], start: '09:00', end: '10:00', mode: 'quick' as const },
        { days: [1], start: '13:00', end: '15:00', mode: 'deep' as const },
      ],
    };
    const long = task({ title: 'long', estimateMin: 60 });
    const short = task({ title: 'short', estimateMin: 15 });
    const { blocks } = proposeSchedule({ tasks: [long, short], events: [], settings: quickGap, now });
    expect(blocks.find((b) => b.title === 'short')!.startAt).toBe('2026-11-23T14:00:00.000Z'); // 09:00
    expect(blocks.find((b) => b.title === 'long')!.startAt).toBe('2026-11-23T18:00:00.000Z'); // 13:00
  });
});

describe('busyMatch', () => {
  it('never treats a matching event as project host time', () => {
    const shift = event('2026-11-23T15:00:00Z', '2026-11-23T20:00:00Z', { title: "Mr J's shift" });
    const jays = project({ hostMatch: 'shift', windowStrict: true });
    const t = task({ projectId: jays.id });
    const hosted = proposeSchedule({ tasks: [t], events: [shift], settings, projects: [jays], now });
    expect(hosted.blocks[0].startAt).toBe('2026-11-23T15:00:00.000Z');
    const busy = proposeSchedule({ tasks: [t], events: [shift], settings: { ...settings, busyMatch: ["mr j's shift"] }, projects: [jays], now });
    // With no host time left it plans in working hours, outside the shift.
    expect(busy.blocks).toHaveLength(1);
    expect(busy.blocks[0].endAt <= shift.startAt || busy.blocks[0].startAt >= shift.endAt).toBe(true);
  });

  it('makes a matching all-day event block the day', () => {
    const trip = event('2026-11-23T05:00:00Z', '2026-11-24T05:00:00Z', { title: 'Trip', allDay: true });
    const open = findFreeSlots([trip], settings, { from: now, to: new Date('2026-11-24T05:00:00Z') });
    expect(open.length).toBeGreaterThan(0);
    const blocked = findFreeSlots([trip], { ...settings, busyMatch: ['trip'] }, { from: now, to: new Date('2026-11-24T05:00:00Z') });
    expect(blocked).toEqual([]);
  });
});
