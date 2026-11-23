import { describe, expect, it } from 'vitest';
import { findFreeSlots, proposeSchedule } from '../src/server/scheduler.js';
import { DEFAULT_SETTINGS } from '../src/server/store.js';
import type { CalEvent, Task } from '../src/shared/types.js';

const settings = { ...DEFAULT_SETTINGS, timezone: 'America/New_York' };
// Monday 2026-11-23, 08:00 in New York (EST, UTC-5)
const now = new Date('2026-11-23T13:00:00Z');

let n = 0;
const task = (p: Partial<Task>): Task => ({
  id: `t${++n}`, title: `Task ${n}`, notes: '', status: 'todo', priority: 2, estimateMin: 60,
  dueAt: null, createdAt: `2026-11-20T00:00:0${n % 10}Z`, completedAt: null, ...p,
});
const event = (startAt: string, endAt: string, p: Partial<CalEvent> = {}): CalEvent => ({
  id: `e${++n}`, title: 'Meeting', notes: '', startAt, endAt, allDay: false, taskId: null, googleId: null, externalId: null, source: 'local', ...p,
});

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
