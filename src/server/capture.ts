import * as chrono from 'chrono-node';
import { DateTime } from 'luxon';
import type { Captured } from '../shared/types.js';

const DURATION = /(?:\bfor\s+)?(?<![\w:.])(\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|h)\b/i;
const DEADLINE_WORD = /\b(by|due|before|until)\s*$/i;
const LEAD_IN_WORD = /\b(on|at|from|this|next)\s*$/i;

/**
 * Turn one typed line into a task or an event.
 *
 *   "Draft proposal by Friday 2h !high"  -> task, due Friday, 2 h estimate, high priority
 *   "Call supplier Friday 2pm 30 min"    -> event, Friday 2:00-2:30 pm
 *   "Renew licence tomorrow"             -> task, due tomorrow
 *
 * A stated clock time means an event, unless it follows "by", "due" or "before".
 * Start the line with "task:" or "event:" to force either reading.
 */
export function parseCapture(input: string, opts: { now?: Date; timezone: string }): Captured {
  const now = opts.now ?? new Date();
  const zone = opts.timezone;
  let text = input.trim();

  let forced: 'task' | 'event' | null = null;
  const prefix = text.match(/^(task|todo|event|meeting)\s*:\s*/i);
  if (prefix) {
    forced = /task|todo/i.test(prefix[1]) ? 'task' : 'event';
    text = text.slice(prefix[0].length);
  }

  let priority = 2;
  const pri = text.match(/(?:^|\s)(!{1,3}|!(?:high|low|urgent)|p[123]|urgent)(?=\s|$)/i);
  if (pri) {
    const token = pri[1].toLowerCase();
    priority = token === '!low' || token === 'p3' ? 1 : token === '!' || token === 'p2' ? 2 : 3;
    text = (text.slice(0, pri.index) + ' ' + text.slice(pri.index! + pri[0].length)).trim();
  }

  let estimateMin: number | null = null;
  const dur = text.match(DURATION);
  if (dur) {
    const n = parseFloat(dur[1]);
    estimateMin = Math.round(/^h/i.test(dur[2]) ? n * 60 : n);
    text = (text.slice(0, dur.index) + ' ' + text.slice(dur.index! + dur[0].length)).trim();
  }

  const ref = DateTime.fromJSDate(now, { zone });
  const results = chrono.parse(text, { instant: now, timezone: ref.offset }, { forwardDate: true });
  const hit = results[0];

  let when: DateTime | null = null;
  let whenEnd: DateTime | null = null;
  let hasTime = false;
  let isDeadline = false;

  if (hit) {
    const build = (c: chrono.ParsedComponents) =>
      DateTime.fromObject(
        {
          year: c.get('year')!,
          month: c.get('month')!,
          day: c.get('day')!,
          hour: c.get('hour') ?? 0,
          minute: c.get('minute') ?? 0,
        },
        { zone },
      );
    hasTime = hit.start.isCertain('hour');
    when = build(hit.start);
    if (hit.end && hit.end.isCertain('hour')) whenEnd = build(hit.end);

    let before = text.slice(0, hit.index);
    const after = text.slice(hit.index + hit.text.length);
    if (DEADLINE_WORD.test(before)) {
      isDeadline = true;
      before = before.replace(DEADLINE_WORD, '');
    } else {
      before = before.replace(LEAD_IN_WORD, '');
    }
    text = `${before} ${after}`;
  }

  const title = text.replace(/\s+/g, ' ').replace(/^[\s,;:-]+|[\s,;:-]+$/g, '') || input.trim();
  const kind = forced ?? (when && hasTime && !isDeadline ? 'event' : 'task');

  if (kind === 'event') {
    // A forced event with no time lands on the next full hour.
    const start = when && hasTime ? when : (when ?? ref).set({ hour: when ? 9 : ref.hour + 1, minute: 0, second: 0, millisecond: 0 });
    const end = whenEnd && whenEnd > start ? whenEnd : start.plus({ minutes: estimateMin ?? 60 });
    return {
      kind,
      title,
      priority,
      estimateMin: Math.round(end.diff(start, 'minutes').minutes),
      dueAt: null,
      startAt: start.toUTC().toISO(),
      endAt: end.toUTC().toISO(),
    };
  }

  const due = when ? (hasTime ? when : when.endOf('day').startOf('minute')) : null;
  return {
    kind,
    title,
    priority,
    estimateMin,
    dueAt: due ? due.toUTC().toISO() : null,
    startAt: null,
    endAt: null,
  };
}
