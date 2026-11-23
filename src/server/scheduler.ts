import { DateTime } from 'luxon';
import type { CalEvent, FreeSlot, Project, ProposedBlock, ScheduleProposal, Settings, Task, TimeWindow } from '../shared/types.js';

const MIN = 60_000;
const SNAP_MIN = 15;
const MIN_BLOCK_MIN = 30;
/** Open tasks this short, in the same project, share one block. */
export const QUICK_TASK_MIN = 15;
/** A batch block never grows past this, so it stays a sitting rather than an afternoon. */
const MAX_BATCH_MIN = 60;

export function batchTitle(count: number): string {
  return `Quick: ${count} tasks`;
}

const isBlock = (e: CalEvent) => !!e.taskId || e.taskIds.length > 0;

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

/** Merge overlapping or touching intervals. */
function union(intervals: Interval[]): Interval[] {
  const sorted = [...intervals].sort((a, b) => a.start - b.start);
  const out: Interval[] = [];
  for (const i of sorted) {
    const last = out[out.length - 1];
    if (last && i.start <= last.end) last.end = Math.max(last.end, i.end);
    else out.push({ ...i });
  }
  return out;
}

/** Weekly windows (e.g. weekdays 06:45–08:15) between `from` and `to`, in `zone`. */
export function windowsFrom(rules: TimeWindow[], zone: string, from: number, to: number): Interval[] {
  const out: Interval[] = [];
  let day = DateTime.fromMillis(from, { zone }).startOf('day');
  const last = DateTime.fromMillis(to, { zone });
  while (day <= last) {
    for (const rule of rules) {
      if (!rule.days.includes(day.weekday)) continue;
      const s = Math.max(day.set(parseHM(rule.start)).toMillis(), from);
      const e = Math.min(day.set(parseHM(rule.end)).toMillis(), to);
      if (e > s) out.push({ start: s, end: e });
    }
    day = day.plus({ days: 1 });
  }
  return union(out);
}

/** Working-hour windows between `from` and `to`, in the user's timezone. */
export function workWindows(settings: Settings, from: number, to: number): Interval[] {
  return windowsFrom([{ days: settings.workDays, start: settings.workStart, end: settings.workEnd }], settings.timezone, from, to);
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

function busyFrom(events: CalEvent[], settings?: Pick<Settings, 'bufferMin' | 'bufferMinEventMin'>): Interval[] {
  const pad = (settings?.bufferMin ?? 0) * MIN;
  const longEnough = (settings?.bufferMinEventMin ?? 0) * MIN;
  // All-day events (birthdays, holidays, out-of-office markers) don't block time.
  return events
    .filter((e) => !e.allDay)
    .map((e) => {
      const start = Date.parse(e.startAt);
      const end = Date.parse(e.endAt);
      // Long fixed commitments (a shift, a trip) get breathing room; Planner's own blocks don't.
      const padded = pad > 0 && !isBlock(e) && end - start >= longEnough;
      return padded ? { start: start - pad, end: end + pad } : { start, end };
    });
}

function snapped(intervals: Interval[]): Interval[] {
  return intervals
    .map((i) => ({ start: snapUp(i.start), end: i.end }))
    .filter((i) => i.end - i.start >= SNAP_MIN * MIN);
}

/** Open time inside working hours, with starts snapped to a 15-minute grid. */
export function freeIntervals(events: CalEvent[], settings: Settings, from: number, to: number): Interval[] {
  return snapped(subtract(workWindows(settings, from, to), busyFrom(events, settings)));
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
  // A future batch block covers its short tasks completely.
  if (events.some((e) => e.taskIds.includes(task.id) && Date.parse(e.endAt) > now)) return 0;
  const booked = events
    .filter((e) => e.taskId === task.id && Date.parse(e.endAt) > now)
    .reduce((sum, e) => sum + (Date.parse(e.endAt) - Math.max(Date.parse(e.startAt), now)) / MIN, 0);
  return Math.max(0, Math.round(task.estimateMin - booked));
}

/** One thing to place: a task, or a batch of short tasks from the same project. */
interface Work {
  tasks: Task[];
  remaining: number;
  projectId: string | null;
  due: number | null;
  priority: number;
  createdAt: string;
  /** A batch must land in one piece. */
  whole: boolean;
}

function byUrgency(a: Work, b: Work): number {
  const da = a.due ?? Infinity;
  const db = b.due ?? Infinity;
  if (da !== db) return da - db;
  if (a.priority !== b.priority) return b.priority - a.priority;
  return a.createdAt.localeCompare(b.createdAt);
}

function single(task: Task, remaining: number): Work {
  return {
    tasks: [task],
    remaining,
    projectId: task.projectId ?? null,
    due: task.dueAt ? Date.parse(task.dueAt) : null,
    priority: task.priority,
    createdAt: task.createdAt,
    whole: false,
  };
}

/** Group short tasks of the same project into batches of up to MAX_BATCH_MIN. */
function buildWork(items: { task: Task; remaining: number }[], batch: boolean): Work[] {
  if (!batch) return items.map((i) => single(i.task, i.remaining));
  const work: Work[] = [];
  const quick = new Map<string, { task: Task; remaining: number }[]>();
  for (const i of items) {
    if (i.remaining > QUICK_TASK_MIN) {
      work.push(single(i.task, i.remaining));
      continue;
    }
    const key = i.task.projectId ?? '';
    quick.set(key, [...(quick.get(key) ?? []), i]);
  }
  for (const group of quick.values()) {
    if (group.length < 2) {
      work.push(...group.map((i) => single(i.task, i.remaining)));
      continue;
    }
    // Most urgent first, so the earliest batch holds what's due soonest.
    const sorted = group.map((i) => single(i.task, i.remaining)).sort(byUrgency);
    let chunk: Work[] = [];
    const flush = () => {
      if (chunk.length === 1) work.push(chunk[0]);
      else if (chunk.length > 1) {
        work.push({
          tasks: chunk.flatMap((w) => w.tasks),
          remaining: chunk.reduce((s, w) => s + w.remaining, 0),
          projectId: chunk[0].projectId,
          due: chunk.reduce<number | null>((d, w) => (w.due === null ? d : d === null ? w.due : Math.min(d, w.due)), null),
          priority: Math.max(...chunk.map((w) => w.priority)),
          createdAt: chunk.map((w) => w.createdAt).sort()[0],
          whole: true,
        });
      }
      chunk = [];
    };
    for (const w of sorted) {
      if (chunk.reduce((s, c) => s + c.remaining, 0) + w.remaining > MAX_BATCH_MIN) flush();
      chunk.push(w);
    }
    flush();
  }
  return work;
}

/**
 * Propose time blocks for every open task that isn't fully booked yet.
 * Earliest due date goes first, then higher priority, then older tasks.
 *
 * A task in a project with time windows is placed inside those windows (and
 * inside calendar events matching the project's hostMatch); if they're full and
 * the project isn't strict, it falls back to working hours and is marked
 * outsideWindow. Short tasks of one project share a block when `batch` is on.
 * Nothing is written; the caller applies the blocks it accepts.
 */
export function proposeSchedule(input: {
  tasks: Task[];
  events: CalEvent[];
  settings: Settings;
  projects?: Project[];
  now?: Date;
  taskIds?: string[];
  /** Group short tasks of the same project. Default true. */
  batch?: boolean;
}): ScheduleProposal {
  const { settings, events } = input;
  const now = (input.now ?? new Date()).getTime();
  const horizon = now + settings.horizonDays * 24 * 60 * MIN;
  const maxBlock = Math.max(MIN_BLOCK_MIN, settings.maxBlockMin);
  const projects = new Map((input.projects ?? []).map((p) => [p.id, p]));

  const items = input.tasks
    .filter((t) => t.status === 'todo' && (!input.taskIds || input.taskIds.includes(t.id)))
    .map((t) => ({ task: t, remaining: remainingMinutes(t, events, now) }))
    .filter((q) => q.remaining > 0);
  const queue = buildWork(items, input.batch ?? true).sort(byUrgency);

  // Where each project's work may go, worked out once per project.
  const general = workWindows(settings, now, horizon);
  const plans = new Map<string, { primary: Interval[]; fallback: Interval[] | null; busy: Interval[] }>();
  const planFor = (projectId: string | null) => {
    const key = projectId ?? '';
    const cached = plans.get(key);
    if (cached) return cached;
    const p = projectId ? projects.get(projectId) : undefined;
    const match = p?.hostMatch?.trim().toLowerCase();
    const hosts = match ? events.filter((e) => !e.allDay && !isBlock(e) && e.title.toLowerCase().includes(match)) : [];
    const hostIds = new Set(hosts.map((e) => e.id));
    const hostTime = hosts
      .map((e) => ({ start: Math.max(Date.parse(e.startAt), now), end: Math.min(Date.parse(e.endAt), horizon) }))
      .filter((i) => i.end > i.start);
    const ruled = p && p.windows.length ? windowsFrom(p.windows, settings.timezone, now, horizon) : [];
    const hasOwn = !!p && (p.windows.length > 0 || hostTime.length > 0);
    const plan = {
      primary: hasOwn ? union([...ruled, ...hostTime]) : general,
      fallback: hasOwn && !p!.windowStrict ? general : null,
      // A host event is the project's own time, so it isn't busy for that project.
      busy: busyFrom(hostIds.size ? events.filter((e) => !hostIds.has(e.id)) : events, settings),
    };
    plans.set(key, plan);
    return plan;
  };

  const placed: Interval[] = [];
  const blocks: ProposedBlock[] = [];
  const unscheduled: ScheduleProposal['unscheduled'] = [];
  const minutesIn = (s: Interval) => Math.floor((s.end - s.start) / MIN);

  for (const w of queue) {
    const plan = planFor(w.projectId);
    const due = w.due;
    // Free stretches this work already has a block in, identified by where they end.
    const used = new Set<number>();
    const lead = w.tasks[0];

    while (w.remaining > 0) {
      const want = Math.min(w.remaining, w.whole ? w.remaining : maxBlock);
      // A chunk must be a real block or finish the task: no slivers.
      const least = w.whole ? want : Math.min(want, MIN_BLOCK_MIN);

      // Prefer a stretch that holds the whole chunk, and spread a long task across
      // different stretches. Stack blocks in one stretch only when that is the sole
      // way to fit the work, or to finish before it is due.
      const choose = (windows: Interval[]) => {
        const free = snapped(subtract(windows, [...plan.busy, ...placed]));
        const first = (reuse: boolean, need: number) => free.findIndex((s) => used.has(s.end) === reuse && minutesIn(s) >= need);
        const pick = (reuse: boolean) => {
          const whole = first(reuse, want);
          return whole >= 0 ? whole : first(reuse, least);
        };
        const endOf = (i: number) => free[i].start + Math.min(want, minutesIn(free[i])) * MIN;
        let i = pick(false);
        const stacked = pick(true);
        if (i < 0 || (due !== null && stacked >= 0 && endOf(i) > due && endOf(stacked) <= due)) i = stacked;
        return i < 0 ? null : { slot: free[i], end: endOf(i) };
      };

      let outsideWindow = false;
      let found = choose(plan.primary);
      if (!found && plan.fallback) {
        found = choose(plan.fallback);
        outsideWindow = !!found;
      }
      if (!found) break;

      const { slot, end } = found;
      const batch = w.tasks.length > 1;
      blocks.push({
        taskId: lead.id,
        ...(batch ? { taskIds: w.tasks.map((t) => t.id) } : {}),
        title: batch ? batchTitle(w.tasks.length) : lead.title,
        startAt: new Date(slot.start).toISOString(),
        endAt: new Date(end).toISOString(),
        late: due !== null && end > due,
        projectId: w.projectId,
        ...(outsideWindow ? { outsideWindow: true } : {}),
      });
      placed.push({ start: slot.start, end });
      w.remaining -= Math.round((end - slot.start) / MIN);
      used.add(slot.end);
    }
    if (w.remaining > 0) {
      for (const t of w.tasks) {
        const share = w.tasks.length > 1 ? remainingMinutes(t, events, now) : w.remaining;
        unscheduled.push({ taskId: t.id, title: t.title, remainingMin: share });
      }
    }
  }

  blocks.sort((a, b) => a.startAt.localeCompare(b.startAt));
  return { blocks, unscheduled };
}
