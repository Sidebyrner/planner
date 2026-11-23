import { useState } from 'react';
import type { CalEvent, Project, Task } from '../shared/types';
import { drag } from './Calendar';
import { projectLabel, projectStyle, type ProjectMap } from './projects';
import { fmtDuration, fmtWhen } from './util';

interface Props {
  tasks: Task[];
  events: CalEvent[];
  projects: ProjectMap;
  litTaskId: string | null;
  onHoverTask: (id: string | null) => void;
  onToggle: (t: Task) => void;
  onOpen: (t: Task) => void;
  onShowBlock: (e: CalEvent) => void;
}

/** 'all', 'none' (no project), or a project id. */
type Filter = string;

export function ProjectChip({ project }: { project: Project | undefined }) {
  if (!project) return null;
  return (
    <span className="proj-chip" style={projectStyle(project)}>
      {projectLabel(project)}
    </span>
  );
}

export function Tasks({ tasks, events, projects, litTaskId, onHoverTask, onToggle, onOpen, onShowBlock }: Props) {
  const [filter, setFilter] = useState<Filter>('all');
  const now = Date.now();
  const nextBlock = new Map<string, CalEvent>();
  const booked = new Map<string, number>();
  for (const e of events) {
    if (Date.parse(e.endAt) <= now) continue;
    const ids = e.taskId ? [e.taskId] : e.taskIds;
    for (const id of ids) {
      if (!nextBlock.has(id)) nextBlock.set(id, e);
      // A Quick batch covers each of its tasks completely.
      const minutes = e.taskId ? (Date.parse(e.endAt) - Date.parse(e.startAt)) / 60_000 : Infinity;
      booked.set(id, (booked.get(id) ?? 0) + minutes);
    }
  }

  const visible = tasks.filter((t) => filter === 'all' || (filter === 'none' ? !t.projectId : t.projectId === filter));
  const open = visible
    .filter((t) => t.status === 'todo')
    .sort((a, b) => {
      const da = a.dueAt ? Date.parse(a.dueAt) : Infinity;
      const db = b.dueAt ? Date.parse(b.dueAt) : Infinity;
      // Follow-ups that came back go first: someone else's turn is over.
      return Number(!!b.waitingOn) - Number(!!a.waitingOn) || da - db || b.priority - a.priority || a.createdAt.localeCompare(b.createdAt);
    });
  const waiting = visible
    .filter((t) => t.status === 'waiting')
    .sort((a, b) => (a.followUpAt ?? '9').localeCompare(b.followUpAt ?? '9'));
  const done = visible
    .filter((t) => t.status === 'done')
    .sort((a, b) => (b.completedAt ?? '').localeCompare(a.completedAt ?? ''))
    .slice(0, 30);

  const live = [...projects.values()].filter((p) => !p.archived);
  const openCount = (id: string | null) => tasks.filter((t) => t.status === 'todo' && (t.projectId ?? null) === id).length;

  return (
    <section className="tasks" aria-label="Tasks">
      <header className="tasks-head">
        <h2>Tasks</h2>
        <span className="count">{open.length} open</span>
      </header>

      {live.length > 0 && (
        <nav className="proj-filter" aria-label="Filter by project">
          <button className={filter === 'all' ? 'is-on' : ''} onClick={() => setFilter('all')}>
            All
          </button>
          {live.map((p) => (
            <button key={p.id} className={filter === p.id ? 'is-on' : ''} style={projectStyle(p)} onClick={() => setFilter(p.id)}>
              <i className="dot" aria-hidden="true" />
              {projectLabel(p)}
              <small>{openCount(p.id) || ''}</small>
            </button>
          ))}
          <button className={filter === 'none' ? 'is-on' : ''} onClick={() => setFilter('none')}>
            No project
          </button>
        </nav>
      )}

      {open.length === 0 && (
        <p className="empty">Nothing open. Type a task in the bar above (add #project to file it), or have your agent add one.</p>
      )}

      <ul className="task-list">
        {open.map((t) => {
          const block = nextBlock.get(t.id);
          const left = Math.max(0, t.estimateMin - (booked.get(t.id) ?? 0));
          const overdue = !!t.dueAt && Date.parse(t.dueAt) < now;
          const project = t.projectId ? projects.get(t.projectId) : undefined;
          const steps = t.checklist.length ? `${t.checklist.filter((c) => c.done).length}/${t.checklist.length}` : null;
          return (
            <li
              key={t.id}
              className={`task${litTaskId === t.id ? ' is-lit' : ''}${project ? ' has-project' : ''}`}
              style={projectStyle(project)}
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
                  {filter === 'all' && <ProjectChip project={project} />}
                  {t.waitingOn && <span className="is-followup">Follow up with {t.waitingOn}</span>}
                  <span>{fmtDuration(t.estimateMin)}</span>
                  {steps && <span>☑ {steps}</span>}
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

      {waiting.length > 0 && (
        <details className="waiting" open>
          <summary>Waiting on others ({waiting.length})</summary>
          <ul className="task-list">
            {waiting.map((t) => (
              <li key={t.id} className="task is-waiting" style={projectStyle(t.projectId ? projects.get(t.projectId) : undefined)}>
                <span className="wait-icon" aria-hidden="true">⏳</span>
                <button className="task-main" onClick={() => onOpen(t)}>
                  <span className="task-title">{t.title}</span>
                  <span className="task-meta">
                    {filter === 'all' && <ProjectChip project={t.projectId ? projects.get(t.projectId) : undefined} />}
                    <span>{t.waitingOn ? `Waiting on ${t.waitingOn}` : 'Waiting'}</span>
                    {t.followUpAt && <span>follow up {fmtWhen(t.followUpAt)}</span>}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </details>
      )}

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
