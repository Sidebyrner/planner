import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { CalEvent, ProposedBlock, Settings } from '../shared/types';
import { projectStyle, type ProjectMap } from './projects';
import { addDays, DAY_MS, fmtTime, fmtWeekday, sameDay } from './util';

const HOUR_H = 52;
const SNAP = 15;

/** What is being dragged. Kept here because drop targets cannot read drag data until the drop. */
export const drag: { current: null | { kind: 'task'; id: string; minutes: number } | { kind: 'event'; id: string; minutes: number; grabMin: number } } = {
  current: null,
};

interface Placed {
  key: string;
  top: number;
  height: number;
  col: number;
  cols: number;
  startsAt: Date;
  endsAt: Date;
  event?: CalEvent;
  proposal?: ProposedBlock;
}

/** Lay out one day's blocks side by side where they overlap. */
function place(day: Date, events: CalEvent[], proposals: ProposedBlock[]): Placed[] {
  const d0 = day.getTime();
  const d1 = d0 + DAY_MS;
  const items: Placed[] = [];
  const add = (startAt: string, endAt: string, rest: Partial<Placed> & { key: string }) => {
    const s = Math.max(Date.parse(startAt), d0);
    const e = Math.min(Date.parse(endAt), d1);
    if (e <= s) return;
    items.push({
      top: ((s - d0) / 3600_000) * HOUR_H,
      height: Math.max(((e - s) / 3600_000) * HOUR_H, 18),
      col: 0,
      cols: 1,
      startsAt: new Date(startAt),
      endsAt: new Date(endAt),
      ...rest,
    });
  };
  for (const e of events) if (!e.allDay) add(e.startAt, e.endAt, { key: e.id, event: e });
  for (const p of proposals) add(p.startAt, p.endAt, { key: `p-${p.taskId}-${p.startAt}`, proposal: p });
  items.sort((a, b) => a.top - b.top || b.height - a.height);

  let cluster: Placed[] = [];
  let clusterEnd = -1;
  const flush = () => {
    const cols = Math.max(...cluster.map((c) => c.col)) + 1;
    for (const c of cluster) c.cols = cols;
    cluster = [];
  };
  for (const it of items) {
    if (cluster.length && it.top >= clusterEnd) flush();
    const taken = new Set(cluster.filter((c) => c.top + c.height > it.top).map((c) => c.col));
    while (taken.has(it.col)) it.col++;
    cluster.push(it);
    clusterEnd = Math.max(clusterEnd, it.top + it.height);
  }
  if (cluster.length) flush();
  return items;
}

interface Props {
  start: Date;
  days: number;
  events: CalEvent[];
  proposals: ProposedBlock[];
  settings: Settings;
  projects: ProjectMap;
  litTaskId: string | null;
  onHoverTask: (id: string | null) => void;
  onOpenEvent: (e: CalEvent) => void;
  onNewEvent: (start: Date) => void;
  onMoveEvent: (id: string, start: Date, minutes: number) => void;
  onDropTask: (taskId: string, start: Date, minutes: number) => void;
  onDropProposal: (p: ProposedBlock) => void;
}

export function Calendar(props: Props) {
  const { start, days, events, proposals, settings } = props;
  const scroller = useRef<HTMLDivElement>(null);
  const [now, setNow] = useState(() => new Date());
  const [dropAt, setDropAt] = useState<{ day: number; top: number; height: number } | null>(null);

  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 60_000);
    return () => clearInterval(t);
  }, []);

  const workStartH = parseInt(settings.workStart, 10) + parseInt(settings.workStart.slice(3), 10) / 60;
  const workEndH = parseInt(settings.workEnd, 10) + parseInt(settings.workEnd.slice(3), 10) / 60;

  useLayoutEffect(() => {
    if (scroller.current) scroller.current.scrollTop = Math.max(0, (workStartH - 1) * HOUR_H - 14);
  }, [workStartH]);

  const columns = useMemo(
    () =>
      Array.from({ length: days }, (_, i) => {
        const day = addDays(start, i);
        const t0 = day.getTime();
        const t1 = t0 + DAY_MS;
        const inDay = (s: string, e: string) => Date.parse(e) > t0 && Date.parse(s) < t1;
        return {
          day,
          allDay: events.filter((e) => e.allDay && inDay(e.startAt, e.endAt)),
          placed: place(
            day,
            events.filter((e) => inDay(e.startAt, e.endAt)),
            proposals.filter((p) => inDay(p.startAt, p.endAt)),
          ),
        };
      }),
    [start, days, events, proposals],
  );

  const hasAllDay = columns.some((c) => c.allDay.length);

  const timeAt = (day: Date, clientY: number, el: HTMLElement, offsetMin = 0, snap = SNAP) => {
    const y = clientY - el.getBoundingClientRect().top;
    const minutes = Math.round(((y / HOUR_H) * 60 - offsetMin) / snap) * snap;
    return new Date(day.getTime() + Math.max(0, Math.min(minutes, 24 * 60 - SNAP)) * 60_000);
  };

  return (
    <div className="cal">
      <div className="cal-head" style={{ gridTemplateColumns: `var(--gutter) repeat(${days}, minmax(0, 1fr))` }}>
        <div />
        {columns.map(({ day }) => (
          <div key={day.getTime()} className={`cal-day-name${sameDay(day, now) ? ' is-today' : ''}`}>
            <span>{fmtWeekday(day)}</span>
            <b>{day.getDate()}</b>
          </div>
        ))}
        {hasAllDay && (
          <>
            <div className="cal-allday-label">all day</div>
            {columns.map(({ day, allDay }) => (
              <div key={day.getTime()} className="cal-allday">
                {allDay.map((e) => (
                  <button key={e.id} className="chip-allday" onClick={() => props.onOpenEvent(e)}>
                    {e.title}
                  </button>
                ))}
              </div>
            ))}
          </>
        )}
      </div>

      <div className="cal-scroll" ref={scroller}>
        <div className="cal-body" style={{ gridTemplateColumns: `var(--gutter) repeat(${days}, minmax(0, 1fr))`, height: 24 * HOUR_H }}>
          <div className="cal-hours" aria-hidden="true">
            {Array.from({ length: 23 }, (_, h) => (
              <span key={h} style={{ top: (h + 1) * HOUR_H }}>
                {fmtTime(new Date(2020, 0, 1, h + 1))}
              </span>
            ))}
          </div>

          {columns.map(({ day, placed }, di) => {
            const works = settings.workDays.includes(((day.getDay() + 6) % 7) + 1);
            const isToday = sameDay(day, now);
            return (
              <div
                key={day.getTime()}
                className="cal-col"
                style={{ backgroundSize: `100% ${HOUR_H}px` }}
                onClick={(ev) => {
                  if (ev.target === ev.currentTarget) props.onNewEvent(timeAt(day, ev.clientY, ev.currentTarget, 15, 30));
                }}
                onDragOver={(ev) => {
                  const d = drag.current;
                  if (!d) return;
                  ev.preventDefault();
                  const at = timeAt(day, ev.clientY, ev.currentTarget, d.kind === 'event' ? d.grabMin : 0);
                  setDropAt({ day: di, top: ((at.getTime() - day.getTime()) / 3600_000) * HOUR_H, height: (d.minutes / 60) * HOUR_H });
                }}
                onDragLeave={() => setDropAt(null)}
                onDrop={(ev) => {
                  const d = drag.current;
                  drag.current = null;
                  setDropAt(null);
                  if (!d) return;
                  ev.preventDefault();
                  const at = timeAt(day, ev.clientY, ev.currentTarget, d.kind === 'event' ? d.grabMin : 0);
                  if (d.kind === 'task') props.onDropTask(d.id, at, d.minutes);
                  else props.onMoveEvent(d.id, at, d.minutes);
                }}
              >
                {works ? (
                  <>
                    <div className="cal-off" style={{ top: 0, height: workStartH * HOUR_H }} />
                    <div className="cal-off" style={{ top: workEndH * HOUR_H, bottom: 0 }} />
                  </>
                ) : (
                  <div className="cal-off" style={{ inset: 0 }} />
                )}

                {placed.map((it) => {
                  const style = {
                    top: it.top,
                    height: it.height - 2,
                    left: `calc(${(it.col / it.cols) * 100}% + 2px)`,
                    width: `calc(${100 / it.cols}% - 5px)`,
                  };
                  const short = it.height < 40;
                  const range = `${fmtTime(it.startsAt)} to ${fmtTime(it.endsAt)}`;
                  if (it.proposal) {
                    const p = it.proposal;
                    const pProject = p.projectId ? props.projects.get(p.projectId) : undefined;
                    return (
                      <div
                        key={it.key}
                        className={`block is-proposed${p.late ? ' is-late' : ''}${short ? ' is-short' : ''}${pProject ? ' has-project' : ''}`}
                        style={{ ...style, ...projectStyle(pProject) }}
                        title={p.outsideWindow ? `${p.title}: outside ${pProject?.name ?? 'the project'}'s hours, which were full` : undefined}
                      >
                        <span className="block-title">{p.title}</span>
                        {!short && <span className="block-time">{p.late ? `${range}, after it is due` : range}</span>}
                        <button className="block-x" aria-label={`Drop the proposed block for ${p.title}`} onClick={() => props.onDropProposal(p)}>
                          ×
                        </button>
                      </div>
                    );
                  }
                  const e = it.event!;
                  const minutes = Math.round((Date.parse(e.endAt) - Date.parse(e.startAt)) / 60_000);
                  const isTask = !!e.taskId || e.taskIds.length > 0;
                  const eProject = e.projectId ? props.projects.get(e.projectId) : undefined;
                  const lit = !!props.litTaskId && (e.taskId === props.litTaskId || e.taskIds.includes(props.litTaskId));
                  return (
                    <button
                      key={it.key}
                      className={`block ${isTask ? 'is-task' : 'is-event'}${short ? ' is-short' : ''}${lit ? ' is-lit' : ''}${eProject ? ' has-project' : ''}`}
                      style={{ ...style, ...projectStyle(eProject) }}
                      draggable={e.source !== 'device'}
                      title={`${e.title}, ${range}`}
                      onDragStart={(ev) => {
                        const grabMin = ((ev.clientY - ev.currentTarget.getBoundingClientRect().top) / HOUR_H) * 60;
                        drag.current = { kind: 'event', id: e.id, minutes, grabMin };
                        ev.dataTransfer.setData('text/plain', e.title);
                        ev.dataTransfer.effectAllowed = 'move';
                      }}
                      onDragEnd={() => {
                        drag.current = null;
                        setDropAt(null);
                      }}
                      onMouseEnter={() => isTask && props.onHoverTask(e.taskId ?? e.taskIds[0])}
                      onMouseLeave={() => isTask && props.onHoverTask(null)}
                      onClick={() => props.onOpenEvent(e)}
                    >
                      <span className="block-title">{e.title}</span>
                      {!short && <span className="block-time">{range}</span>}
                    </button>
                  );
                })}

                {dropAt?.day === di && <div className="cal-drop" style={{ top: dropAt.top, height: dropAt.height }} />}
                {isToday && <div className="cal-now" style={{ top: ((now.getTime() - day.getTime()) / 3600_000) * HOUR_H }} />}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
