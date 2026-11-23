import { DateTime } from 'luxon';
import type { Recurrence } from '../shared/types.js';

/**
 * The occurrence after `base`, read in the user's timezone and keeping its time
 * of day. Weekly byDay picks the next listed weekday, jumping `interval` weeks
 * once the week's days are used up; monthly byMonthDay does the same per month
 * and clamps to the month's length (31 -> 30 in November).
 */
export function nextOccurrence(rule: Recurrence, base: DateTime): DateTime {
  const n = rule.interval ?? 1;
  const time = { hour: base.hour, minute: base.minute, second: base.second, millisecond: 0 };

  if (rule.freq === 'daily') return base.plus({ days: n });

  if (rule.freq === 'weekly') {
    const days = [...new Set(rule.byDay ?? [])].sort((a, b) => a - b);
    if (!days.length) return base.plus({ weeks: n });
    const later = days.find((d) => d > base.weekday);
    if (later) return base.plus({ days: later - base.weekday });
    return base.startOf('week').plus({ weeks: n, days: days[0] - 1 }).set(time);
  }

  const monthDays = [...new Set(rule.byMonthDay ?? [])].sort((a, b) => a - b);
  if (!monthDays.length) return base.plus({ months: n });
  const later = monthDays.find((d) => d > base.day && d <= base.daysInMonth!);
  if (later) return base.set({ day: later });
  const month = base.startOf('month').plus({ months: n });
  return month.set({ day: Math.min(monthDays[0], month.daysInMonth!), ...time });
}

/**
 * When the next instance is due: the first occurrence after the last due date
 * that is still ahead of `now`, so a chore done late doesn't come back overdue.
 * Without a due date it counts from `now` and is due at the end of that day.
 */
export function nextDue(rule: Recurrence, lastDue: string | null, now: Date, zone: string): string {
  const current = DateTime.fromMillis(now.getTime(), { zone });
  let at: DateTime = lastDue ? DateTime.fromISO(lastDue, { zone }) : current.set({ hour: 23, minute: 59, second: 0, millisecond: 0 });
  for (let i = 0; i < 1000; i++) {
    at = nextOccurrence(rule, at);
    if (at > current) break;
  }
  return at.toUTC().toISO()!;
}

/** When a task due at `dueAt` should appear: the start of the day `leadTimeDays` before. */
export function showFromFor(rule: Recurrence | null | undefined, dueAt: string | null | undefined, zone: string): string | null {
  if (!rule || rule.leadTimeDays === undefined || !dueAt) return null;
  return DateTime.fromISO(dueAt, { zone }).minus({ days: rule.leadTimeDays }).startOf('day').toUTC().toISO()!;
}
