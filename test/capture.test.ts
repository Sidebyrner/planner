import { describe, expect, it } from 'vitest';
import { parseCapture } from '../src/server/capture.js';

// Friday 2026-11-20, 10:00 in New York
const opts = { now: new Date('2026-11-20T15:00:00Z'), timezone: 'America/New_York' };
const p = (text: string) => parseCapture(text, opts);

describe('parseCapture', () => {
  it('reads a deadline, estimate and priority into a task', () => {
    expect(p('Draft proposal by Tuesday 2h !high')).toMatchObject({
      kind: 'task', title: 'Draft proposal', estimateMin: 120, priority: 3,
      dueAt: '2026-11-25T04:59:00.000Z', // end of Tuesday, New York
    });
  });

  it('treats a stated clock time as an event', () => {
    expect(p('Call supplier Monday 2pm 30 min')).toMatchObject({
      kind: 'event', title: 'Call supplier',
      startAt: '2026-11-23T19:00:00.000Z', endAt: '2026-11-23T19:30:00.000Z',
    });
  });

  it('defaults events to an hour', () => {
    const r = p('Lunch with Sam tomorrow at noon');
    expect(r).toMatchObject({ kind: 'event', title: 'Lunch with Sam', startAt: '2026-11-21T17:00:00.000Z', endAt: '2026-11-21T18:00:00.000Z' });
  });

  it('keeps a time after "by" as a task deadline', () => {
    expect(p('Send invoice by Monday 5pm')).toMatchObject({ kind: 'task', title: 'Send invoice', dueAt: '2026-11-23T22:00:00.000Z' });
  });

  it('makes a plain line an undated task', () => {
    expect(p('Buy limes')).toEqual({ kind: 'task', title: 'Buy limes', priority: 2, estimateMin: null, dueAt: null, startAt: null, endAt: null });
  });

  it('uses a bare date as the due day', () => {
    expect(p('Renew licence tomorrow')).toMatchObject({ kind: 'task', title: 'Renew licence', dueAt: '2026-11-22T04:59:00.000Z' });
  });

  it('honours a task: or event: prefix', () => {
    expect(p('task: review deck Monday 3pm')).toMatchObject({ kind: 'task', title: 'review deck', dueAt: '2026-11-23T20:00:00.000Z' });
    expect(p('event: offsite Monday')).toMatchObject({ kind: 'event', title: 'offsite', startAt: '2026-11-23T14:00:00.000Z' });
  });

  it('reads a time range', () => {
    expect(p('Standup Monday 9-9:30am')).toMatchObject({ kind: 'event', startAt: '2026-11-23T14:00:00.000Z', endAt: '2026-11-23T14:30:00.000Z' });
  });

  it('resolves dates across a daylight-saving change in the right offset', () => {
    const r = parseCapture('Dentist April 10 2027 3pm', opts); // EDT by then
    expect(r.startAt).toBe('2027-04-10T19:00:00.000Z');
  });

  it('does not mistake numbers in a title for a duration', () => {
    expect(p('Order 3 kegs')).toMatchObject({ kind: 'task', title: 'Order 3 kegs', estimateMin: null });
  });
});
