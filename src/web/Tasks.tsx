import type { CalEvent, Task } from '../shared/types';
import { drag } from './Calendar';
import { fmtDuration, fmtWhen } from './util';

interface Props {
  tasks: Task[];
  events: CalEvent[];
  litTaskId: string | null;
  onHoverTask: (id: string | null) => void;
  onToggle: (t: Task) => void;
  onOpen: (t: Task) => void;
  onShowBlock: (e: CalEvent) => void;
}

export function Tasks({ tasks, events, litTaskId, onHoverTask, onToggle, onOpen, onShowBlock }: Props) {
  const now = Date.now();
  const nextBlock = new Map<string, CalEvent>();
  const booked = new Map<string, number>();
  for (const e of events) {
    if (!e.taskId || Date.parse(e.endAt) <= now) continue;
    if (!nextBlock.has(e.taskId)) nextBlock.set(e.taskId, e);
    booked.set(e.taskId, (booked.get(e.taskId) ?? 0) + (Date.parse(e.endAt) - Date.parse(e.startAt)) / 60_000);
  }

  const open = tasks
    .filter((t) => t.status === 'todo')
    .sort((a, b) => {
      const da = a.dueAt ? Date.parse(a.dueAt) : Infinity;
      const db = b.dueAt ? Date.parse(b.dueAt) : Infinity;
      return da - db || b.priority - a.priority || a.createdAt.localeCompare(b.createdAt);
    });
  const done = tasks
    .filter((t) => t.status === 'done')
    .sort((a, b) => (b.completedAt ?? '').localeCompare(a.completedAt ?? ''))
    .slice(0, 30);

  return (
    <section className="tasks" aria-label="Tasks">
      <header className="tasks-head">
        <h2>Tasks</h2>
        <span className="count">{open.length} open</span>
      </header>

      {open.length === 0 && (
        <p className="empty">Nothing open. Type a task in the bar above, or have your agent add one.</p>
      )}

      <ul className="task-list">
        {open.map((t) => {
          const block = nextBlock.get(t.id);
          const left = Math.max(0, t.estimateMin - (booked.get(t.id) ?? 0));
          const overdue = !!t.dueAt && Date.parse(t.dueAt) < now;
          return (
            <li
              key={t.id}
              className={`task${litTaskId === t.id ? ' is-lit' : ''}`}
              draggable
              onDragStart={(ev) => {
                drag.current = { kind: 'task', id: t.id, minutes: left || t.estimateMin };
                ev.dataTransfer.setData('text/plain', t.title);
                ev.dataTransfer.effectAllowed = 'copy';
              }}
              onDragEnd={() => (drag.current = null)}
              onMouseEnter={() => onHoverTask(t.id)}
              onMouseLeave={() => onHoverTask(null)}
            >
              <input type="checkbox" checked={false} onChange={() => onToggle(t)} aria-label={`Mark "${t.title}" done`} />
              <button className="task-main" onClick={() => onOpen(t)}>
                <span className="task-title">
                  {t.priority === 3 && <span className="pri pri-high">High</span>}
                  {t.priority === 1 && <span className="pri pri-low">Low</span>}
                  {t.title}
                </span>
                <span className="task-meta">
                  <span>{fmtDuration(t.estimateMin)}</span>
                  {t.dueAt && <span className={overdue ? 'is-overdue' : ''}>{overdue ? 'was due' : 'due'} {fmtWhen(t.dueAt)}</span>}
                </span>
              </button>
              {block ? (
                <button className={`slot${left > 0 ? ' is-partial' : ''}`} onClick={() => onShowBlock(block)} title="Show on the calendar">
                  {fmtWhen(block.startAt)}
                  {left > 0 && <small>{fmtDuration(left)} still unplaced</small>}
                </button>
              ) : (
                <span className="slot is-none">Not scheduled</span>
              )}
            </li>
          );
        })}
      </ul>

      {done.length > 0 && (
        <details className="done">
          <summary>Done ({done.length})</summary>
          <ul className="task-list">
            {done.map((t) => (
              <li key={t.id} className="task is-done">
                <input type="checkbox" checked onChange={() => onToggle(t)} aria-label={`Reopen "${t.title}"`} />
                <button className="task-main" onClick={() => onOpen(t)}>
                  <span className="task-title">{t.title}</span>
                </button>
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  );
}
