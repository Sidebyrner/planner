import { DateTime } from 'luxon';
import type { CalEvent, FreeSlot, ProposedBlock, ScheduleProposal, Settings, Task } from '../shared/types.js';

const MIN = 60_000;
const SNAP_MIN = 15;
const MIN_BLOCK_MIN = 30;

interface Interval {
  start: number;
  end: number;
}

function parseHM(value: string): { hour: number; minute: number } {
  const [h, m] = value.split(':').map(Number);
  return { hour: h || 0, minute: m || 0 };
}

function snapUp(ms: number): number {
  const step = SNAP_MIN * MIN;
  return Math.ceil(ms / step) * step;
}

/** Working-hour windows between `from` and `to`, in the user's timezone. */
export function workWindows(settings: Settings, from: number, to: number): Interval[] {
  const out: Interval[] = [];
  const start = parseHM(settings.workStart);
  const end = parseHM(settings.workEnd);
  let day = DateTime.fromMillis(from, { zone: settings.timezone }).startOf('day');
  const last = DateTime.fromMillis(to, { zone: settings.timezone });
  while (day <= last) {
    if (settings.workDays.includes(day.weekday)) {
      const s = Math.max(day.set(start).toMillis(), from);
      const e = Math.min(day.set(end).toMillis(), to);
      if (e > s) out.push({ start: s, end: e });
    }
    day = day.plus({ days: 1 });
  }
  return out;
}

function subtract(windows: Interval[], busy: Interval[]): Interval[] {
  const sorted = [...busy].sort((a, b) => a.start - b.start);
  const out: Interval[] = [];
  for (const w of windows) {
    let cursor = w.start;
    for (const b of sorted) {
      if (b.end <= cursor) continue;
      if (b.start >= w.end) break;
      if (b.start > cursor) out.push({ start: cursor, end: b.start });
      cursor = Math.max(cursor, b.end);
      if (cursor >= w.end) break;
    }
    if (cursor < w.end) out.push({ start: cursor, end: w.end });
  }
  return out;
}

function busyFrom(events: CalEvent[]): Interval[] {
  // All-day events (birthdays, holidays, out-of-office markers) don't block time.
  return events
    .filter((e) => !e.allDay)
    .map((e) => ({ start: Date.parse(e.startAt), end: Date.parse(e.endAt) }));
}

/** Open time inside working hours, with starts snapped to a 15-minute grid. */
export function freeIntervals(events: CalEvent[], settings: Settings, from: number, to: number): Interval[] {
  return subtract(workWindows(settings, from, to), busyFrom(events))
    .map((i) => ({ start: snapUp(i.start), end: i.end }))
    .filter((i) => i.end - i.start >= SNAP_MIN * MIN);
}

export function findFreeSlots(
  events: CalEvent[],
  settings: Settings,
  opts: { from: Date; to: Date; minMinutes?: number },
): FreeSlot[] {
  const min = opts.minMinutes ?? MIN_BLOCK_MIN;
  return freeIntervals(events, settings, opts.from.getTime(), opts.to.getTime())
    .map((i) => ({
      startAt: new Date(i.start).toISOString(),
      endAt: new Date(i.end).toISOString(),
      minutes: Math.floor((i.end - i.start) / MIN),
    }))
    .filter((s) => s.minutes >= min);
}

/** Minutes of a task not yet covered by a block that is still ahead of `now`. */
export function remainingMinutes(task: Task, events: CalEvent[], now: number): number {
  const booked = events
    .filter((e) => e.taskId === task.id && Date.parse(e.endAt) > now)
    .reduce((sum, e) => sum + (Date.parse(e.endAt) - Math.max(Date.parse(e.startAt), now)) / MIN, 0);
  return Math.max(0, Math.round(task.estimateMin - booked));
}

/**
 * Propose time blocks for every open task that isn't fully booked yet.
 * Earliest due date goes first, then higher priority, then older tasks.
 * Nothing is written; the caller applies the blocks it accepts.
 */
export function proposeSchedule(input: {
  tasks: Task[];
  events: CalEvent[];
  settings: Settings;
  now?: Date;
  taskIds?: string[];
}): ScheduleProposal {
  const { settings, events } = input;
  const now = (input.now ?? new Date()).getTime();
  const horizon = now + settings.horizonDays * 24 * 60 * MIN;
  const maxBlock = Math.max(MIN_BLOCK_MIN, settings.maxBlockMin);

  const queue = input.tasks
    .filter((t) => t.status === 'todo' && (!input.taskIds || input.taskIds.includes(t.id)))
    .map((t) => ({ task: t, remaining: remainingMinutes(t, events, now) }))
    .filter((q) => q.remaining > 0)
    .sort((a, b) => {
      const da = a.task.dueAt ? Date.parse(a.task.dueAt) : Infinity;
      const db = b.task.dueAt ? Date.parse(b.task.dueAt) : Infinity;
      if (da !== db) return da - db;
      if (a.task.priority !== b.task.priority) return b.task.priority - a.task.priority;
      return a.task.createdAt.localeCompare(b.task.createdAt);
    });

  const free = freeIntervals(events, settings, now, horizon);
  const blocks: ProposedBlock[] = [];
  const unscheduled: ScheduleProposal['unscheduled'] = [];

  const minutesIn = (s: Interval) => Math.floor((s.end - s.start) / MIN);

  for (const q of queue) {
    const due = q.task.dueAt ? Date.parse(q.task.dueAt) : null;
    // Free stretches this task already has a block in, identified by where they end.
    const used = new Set<number>();

    while (q.remaining > 0) {
      const want = Math.min(q.remaining, maxBlock);
      // A chunk must be a real block or finish the task: no slivers.
      const least = Math.min(want, MIN_BLOCK_MIN);
      const first = (reuse: boolean, need: number) =>
        free.findIndex((s) => used.has(s.end) === reuse && minutesIn(s) >= need);
      const pick = (reuse: boolean) => {
        const whole = first(reuse, want);
        return whole >= 0 ? whole : first(reuse, least);
      };
      const endOf = (i: number) => free[i].start + Math.min(want, minutesIn(free[i])) * MIN;

      // Prefer a stretch that holds the whole chunk, and spread a long task across
      // different stretches. Stack blocks in one stretch only when that is the sole
      // way to fit the work, or to finish before it is due.
      let i = pick(false);
      const stacked = pick(true);
      if (i < 0 || (due !== null && stacked >= 0 && endOf(i) > due && endOf(stacked) <= due)) i = stacked;
      if (i < 0) break;

      const slot = free[i];
      const end = endOf(i);
      blocks.push({
        taskId: q.task.id,
        title: q.task.title,
        startAt: new Date(slot.start).toISOString(),
        endAt: new Date(end).toISOString(),
        late: due !== null && end > due,
      });
      q.remaining -= Math.round((end - slot.start) / MIN);
      used.add(slot.end);
      const rest = { start: snapUp(end), end: slot.end };
      if (rest.end - rest.start >= SNAP_MIN * MIN) free[i] = rest;
      else free.splice(i, 1);
    }
    if (q.remaining > 0) {
      unscheduled.push({ taskId: q.task.id, title: q.task.title, remainingMin: q.remaining });
    }
  }

  blocks.sort((a, b) => a.startAt.localeCompare(b.startAt));
  return { blocks, unscheduled };
}
