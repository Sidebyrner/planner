import * as chrono from 'chrono-node';
import { DateTime } from 'luxon';
import type { Captured, Project } from '../shared/types.js';
import { slugTag } from './store.js';

const DURATION = /(?:\bfor\s+)?(?<![\w:.])(\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|h)\b/i;
const TAG = /(?:^|\s)#([\p{L}\p{N}][\p{L}\p{N}_'’-]*)/u;
const MENTION = /(?:^|\s)@([\p{L}][\p{L}\p{N}_'’.-]*)/u;
/** "waiting on Matt", "waiting for Ryan" at the start of a line: the same as @Matt. */
const WAITING_ON = /^\s*waiting\s+(?:on|for)\s+([\p{L}][\p{L}\p{N}_'’.-]*)\s*/iu;
/** "re: Salude content" — what the line is about. */
const RE = /(?:^|\s)re:?\s+/i;
/** "check Wed", "chase Friday", "follow up Monday": the date is when to chase. */
const FOLLOW_UP_WORD = /\b(check(?:\s+in)?|chase|follow[\s-]?up|ping|nudge)(?:\s+(?:on|at))?\s*$/i;
/** Waiting tasks with no date given come back after this many days. */
const DEFAULT_FOLLOW_UP_DAYS = 2;

/** Exact tag first, then a single project whose tag or name starts with what was typed. */
export function matchProject(typed: string, projects: Project[]): Project | null {
  const slug = slugTag(typed);
  if (!slug) return null;
  const live = projects.filter((p) => !p.archived);
  const exact = live.find((p) => p.tag === slug) ?? projects.find((p) => p.tag === slug);
  if (exact) return exact;
  const prefixed = live.filter((p) => p.tag.startsWith(slug) || slugTag(p.name).startsWith(slug));
  return prefixed.length === 1 ? prefixed[0] : null;
}

/** Live projects with a word of their name or tag starting with `word` ("backsplash" -> Mr Backsplash). */
function projectsNamedBy(word: string, projects: Project[]): Project[] {
  const slug = slugTag(word);
  if (slug.length < 4) return [];
  return projects.filter(
    (p) => !p.archived && [...slugTag(p.name).split('-'), ...p.tag.split('-')].some((part) => part.startsWith(slug)),
  );
}

function cut(text: string, m: RegExpMatchArray): string {
  return (text.slice(0, m.index) + ' ' + text.slice(m.index! + m[0].length)).trim();
}
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
 *
 *   "Order kegs #bar 15m"            -> task in the project tagged #bar
 *   "@Sam send the invoice Friday"   -> waiting on Sam, follow up Friday
 *   "waiting on Matt re: Salude content, check Wed"
 *                                    -> waiting on Matt, project Salude (if one fits), follow up Wednesday
 */
export function parseCapture(input: string, opts: { now?: Date; timezone: string; projects?: Project[] }): Captured {
  const now = opts.now ?? new Date();
  const zone = opts.timezone;
  let text = input.trim();

  let forced: 'task' | 'event' | null = null;
  const prefix = text.match(/^(task|todo|event|meeting)\s*:\s*/i);
  if (prefix) {
    forced = /task|todo/i.test(prefix[1]) ? 'task' : 'event';
    text = text.slice(prefix[0].length);
  }

  let projectTag: string | null = null;
  const tag = text.match(TAG);
  if (tag) {
    projectTag = tag[1];
    text = cut(text, tag);
  }
  const project = projectTag ? matchProject(projectTag, opts.projects ?? []) : null;

  let waitingOn: string | null = null;
  const lead = forced !== 'event' ? text.match(WAITING_ON) : null;
  if (lead) {
    waitingOn = lead[1].replace(/[.,'’-]+$/, '');
    text = text.slice(lead[0].length);
    forced = 'task';
  }
  const mention = waitingOn ? null : text.match(MENTION);
  if (mention && forced !== 'event') {
    waitingOn = mention[1].replace(/[.'’-]+$/, '');
    text = cut(text, mention);
    forced = 'task';
  }
  // "re: Salude content" names the project when one word of it fits exactly one project.
  const about = text.match(RE);
  let implied: Project | null = null;
  if (about) {
    text = cut(text, about);
    if (!projectTag) {
      const subject = text.slice(about.index).split(/[,;]|\b(?:check|chase|follow|by|due)\b/i)[0];
      const hits = new Set(
        subject
          .split(/\s+/)
          .filter((w) => w.replace(/\W/g, '').length >= 4)
          .flatMap((w) => projectsNamedBy(w, opts.projects ?? [])),
      );
      if (hits.size === 1) implied = [...hits][0];
    }
  }
  const tagged = {
    projectTag: projectTag ?? implied?.tag ?? null,
    projectId: project?.id ?? implied?.id ?? null,
    newProject: projectTag && !project ? slugTag(projectTag) || null : null,
    waitingOn,
  };

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
    if (FOLLOW_UP_WORD.test(before)) {
      before = before.replace(FOLLOW_UP_WORD, '');
    } else if (DEADLINE_WORD.test(before)) {
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
      ...tagged,
      followUpAt: null,
    };
  }

  if (waitingOn) {
    // For a waiting task the date says when to chase it, not when it's due.
    const followUp = when
      ? hasTime
        ? when
        : when.set({ hour: 9, minute: 0, second: 0, millisecond: 0 })
      : ref.plus({ days: DEFAULT_FOLLOW_UP_DAYS }).set({ hour: 9, minute: 0, second: 0, millisecond: 0 });
    return {
      kind,
      title,
      priority,
      estimateMin,
      dueAt: null,
      startAt: null,
      endAt: null,
      ...tagged,
      followUpAt: followUp.toUTC().toISO(),
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
    ...tagged,
    followUpAt: null,
  };
}
