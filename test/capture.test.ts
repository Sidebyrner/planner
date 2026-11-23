import { describe, expect, it } from 'vitest';
import { parseCapture } from '../src/server/capture.js';
import type { Project } from '../src/shared/types.js';

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
    expect(p('Buy limes')).toEqual({
      kind: 'task', title: 'Buy limes', priority: 2, estimateMin: null, dueAt: null, startAt: null, endAt: null,
      projectTag: null, projectId: null, newProject: null, waitingOn: null, followUpAt: null,
    });
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

describe('parseCapture tags and mentions', () => {
  const projects: Project[] = [
    { id: 'p1', name: 'Bar', tag: 'bar', color: 'amber', emoji: '', archived: false, sortOrder: 1, windows: [], windowStrict: false, hostMatch: null },
    { id: 'p2', name: 'Freelance', tag: 'freelance', color: 'indigo', emoji: '', archived: false, sortOrder: 2, windows: [], windowStrict: false, hostMatch: null },
  ];
  const t = (text: string) => parseCapture(text, { ...opts, projects });

  it('takes #tag anywhere in the line and leaves it out of the title', () => {
    expect(t('Order kegs #bar 15m')).toMatchObject({ title: 'Order kegs', projectTag: 'bar', projectId: 'p1', estimateMin: 15 });
    expect(t('#free Send proposal by Monday')).toMatchObject({ title: 'Send proposal', projectId: 'p2' });
  });

  it('marks an unknown tag as a new project', () => {
    expect(t('Update CV #Career')).toMatchObject({ title: 'Update CV', projectId: null, newProject: 'career' });
  });

  it('tags events too', () => {
    expect(t('Rep visit Monday 2pm #bar')).toMatchObject({ kind: 'event', title: 'Rep visit', projectId: 'p1' });
  });

  it('turns @Name into a waiting task with a follow-up date', () => {
    expect(t('@Sam send the invoice Tuesday #freelance')).toMatchObject({
      kind: 'task', title: 'send the invoice', waitingOn: 'Sam', projectId: 'p2', dueAt: null,
      followUpAt: '2026-11-24T14:00:00.000Z', // Tuesday 09:00 New York
    });
    expect(t('Ask @Alex about the keys')).toMatchObject({ title: 'Ask about the keys', waitingOn: 'Alex', followUpAt: '2026-11-22T14:00:00.000Z' });
  });
});
