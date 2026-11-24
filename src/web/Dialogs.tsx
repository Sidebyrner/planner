import { useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { checklistFromNotes } from '../shared/checklist';
import { PROJECT_COLORS, type CalEvent, type ChecklistItem, type GmailStatus, type GoogleStatus, type Project, type ProjectColor, type Settings, type Task, type TimeWindow } from '../shared/types';
import { projectLabel, projectStyle } from './projects';
import { fmtWhen, fromLocalInput, toLocalInput } from './util';

export function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current!;
    if (!d.open) d.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      className="modal"
      onClose={onClose}
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      <div className="modal-body">
        <header>
          <h2>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Close">
            ×
          </button>
        </header>
        {children}
      </div>
    </dialog>
  );
}

function useSubmit(action: () => Promise<void>) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const run = async (fn: () => Promise<void> = action) => {
    setBusy(true);
    setError('');
    try {
      await fn();
    } catch (err) {
      setError((err as Error).message);
      setBusy(false);
    }
  };
  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    void run();
  };
  return { busy, error, run, onSubmit };
}

// ---- task

const newId = () => (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2));

export function TaskDialog(props: {
  task: Task;
  projects: Project[];
  onSave: (patch: Partial<Task>) => Promise<void>;
  onDelete: () => Promise<void>;
  onSchedule: () => Promise<void>;
  onClose: () => void;
}) {
  const { task } = props;
  const [title, setTitle] = useState(task.title);
  const [notes, setNotes] = useState(task.notes);
  const [estimateMin, setEstimate] = useState(task.estimateMin);
  const [priority, setPriority] = useState(task.priority);
  const [due, setDue] = useState(task.dueAt ? toLocalInput(task.dueAt) : '');
  const [projectId, setProjectId] = useState(task.projectId ?? '');
  const [checklist, setChecklist] = useState<ChecklistItem[]>(task.checklist);
  const [newStep, setNewStep] = useState('');
  const [waiting, setWaiting] = useState(task.status === 'waiting');
  const [waitingOn, setWaitingOn] = useState(task.waitingOn ?? '');
  const [followUp, setFollowUp] = useState(task.followUpAt ? toLocalInput(task.followUpAt) : '');
  const listInNotes = checklistFromNotes(notes, newId).items.length > 0;

  const save = () =>
    props.onSave({
      title,
      notes,
      estimateMin,
      priority,
      dueAt: due ? fromLocalInput(due) : null,
      projectId: projectId || null,
      checklist,
      waitingOn: waitingOn.trim() || null,
      followUpAt: waiting && followUp ? fromLocalInput(followUp) : waiting ? null : task.followUpAt,
      // Unticking "waiting" reopens the task; leave done tasks done.
      ...(waiting ? { status: 'waiting' as const } : task.status === 'waiting' ? { status: 'todo' as const } : {}),
    });
  const { busy, error, run, onSubmit } = useSubmit(save);

  const addStep = () => {
    const text = newStep.trim();
    if (!text) return;
    setChecklist([...checklist, { id: newId(), text, done: false }]);
    setNewStep('');
  };
  const listFromNotes = () => {
    const { items, rest } = checklistFromNotes(notes, newId);
    setChecklist([...checklist, ...items]);
    setNotes(rest);
  };
  const live = props.projects.filter((p) => !p.archived || p.id === task.projectId);

  return (
    <Modal title={task.status === 'waiting' ? 'Waiting on someone' : 'Task'} onClose={props.onClose}>
      <form onSubmit={onSubmit}>
        <label>
          Title
          <input value={title} onChange={(e) => setTitle(e.target.value)} required autoFocus />
        </label>
        <div className="row">
          <label>
            Project
            <select value={projectId} onChange={(e) => setProjectId(e.target.value)}>
              <option value="">No project</option>
              {live.map((p) => (
                <option key={p.id} value={p.id}>
                  {projectLabel(p)}
                </option>
              ))}
            </select>
          </label>
          <label>
            Priority
            <select value={priority} onChange={(e) => setPriority(Number(e.target.value))}>
              <option value={3}>High</option>
              <option value={2}>Normal</option>
              <option value={1}>Low</option>
            </select>
          </label>
        </div>
        <div className="row">
          <label>
            Time needed (minutes)
            <input type="number" min={5} max={1440} step={5} value={estimateMin} onChange={(e) => setEstimate(Number(e.target.value))} required />
          </label>
          <label>
            Due
            <input type="datetime-local" value={due} onChange={(e) => setDue(e.target.value)} />
          </label>
        </div>

        <fieldset className="checklist">
          <legend>Checklist {checklist.length > 0 && `(${checklist.filter((c) => c.done).length}/${checklist.length})`}</legend>
          <ul>
            {checklist.map((c, i) => (
              <li key={c.id}>
                <input
                  type="checkbox"
                  checked={c.done}
                  aria-label={`Done: ${c.text}`}
                  onChange={() => setChecklist(checklist.map((x) => (x.id === c.id ? { ...x, done: !x.done } : x)))}
                />
                <input
                  className="step-text"
                  value={c.text}
                  aria-label={`Step ${i + 1}`}
                  onChange={(e) => setChecklist(checklist.map((x) => (x.id === c.id ? { ...x, text: e.target.value } : x)))}
                />
                <button type="button" className="icon-btn" aria-label={`Remove ${c.text}`} onClick={() => setChecklist(checklist.filter((x) => x.id !== c.id))}>
                  ×
                </button>
              </li>
            ))}
          </ul>
          <div className="add-step">
            <input
              value={newStep}
              placeholder="Add a step"
              onChange={(e) => setNewStep(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  addStep();
                }
              }}
            />
            <button type="button" className="btn" onClick={addStep} disabled={!newStep.trim()}>
              Add
            </button>
            {listInNotes && (
              <button type="button" className="btn" onClick={listFromNotes} title="Turn numbered or bulleted lines in the notes into steps">
                Make checklist from notes
              </button>
            )}
          </div>
        </fieldset>

        <fieldset className="waiting-fields">
          <label className="inline">
            <input type="checkbox" checked={waiting} onChange={(e) => setWaiting(e.target.checked)} disabled={task.status === 'done'} />
            Waiting on someone else (not scheduled until the follow-up)
          </label>
          {(waiting || waitingOn) && (
            <div className="row">
              <label>
                Who
                <input value={waitingOn} onChange={(e) => setWaitingOn(e.target.value)} placeholder="Name" required={waiting} />
              </label>
              {waiting && (
                <label>
                  Follow up
                  <input type="datetime-local" value={followUp} onChange={(e) => setFollowUp(e.target.value)} />
                </label>
              )}
            </div>
          )}
        </fieldset>

        <label>
          Notes
          <textarea rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} />
        </label>
        {error && <p className="form-error">{error}</p>}
        <footer>
          <button type="button" className="btn btn-danger" disabled={busy} onClick={() => run(props.onDelete)}>
            Delete task
          </button>
          <span className="spacer" />
          {task.status === 'todo' && !waiting && (
            <button type="button" className="btn" disabled={busy} onClick={() => run(async () => { await save(); await props.onSchedule(); })}>
              Save and find a time
            </button>
          )}
          <button className="btn btn-primary" disabled={busy}>
            Save task
          </button>
        </footer>
      </form>
    </Modal>
  );
}

// ---- event

export type EventDraft = { id?: string; title: string; startAt: string; endAt: string; notes: string; taskId: string | null; source: CalEvent['source']; allDay: boolean };

export function EventDialog(props: {
  event: EventDraft;
  onSave: (patch: { title: string; startAt: string; endAt: string; notes: string }) => Promise<void>;
  onDelete: () => Promise<void>;
  onDoneTask: () => Promise<void>;
  onClose: () => void;
}) {
  const { event } = props;
  const isNew = !event.id;
  const [title, setTitle] = useState(event.title);
  const [start, setStart] = useState(toLocalInput(event.startAt));
  const [end, setEnd] = useState(toLocalInput(event.endAt));
  const [notes, setNotes] = useState(event.notes);
  const { busy, error, run, onSubmit } = useSubmit(() =>
    props.onSave({ title, startAt: fromLocalInput(start), endAt: fromLocalInput(end), notes }),
  );

  // Moving the start keeps the length, the way every calendar does.
  const changeStart = (v: string) => {
    if (v && start && end) {
      const len = new Date(end).getTime() - new Date(start).getTime();
      setEnd(toLocalInput(new Date(new Date(v).getTime() + len)));
    }
    setStart(v);
  };

  return (
    <Modal title={isNew ? 'New event' : event.taskId ? 'Time block' : 'Event'} onClose={props.onClose}>
      <form onSubmit={onSubmit}>
        {event.taskId && <p className="hint">Time reserved for a task. Moving or removing it leaves the task itself alone.</p>}
        {event.source === 'google' && <p className="hint">From Google Calendar. Changes you save here are written back to it.</p>}
        {event.source === 'device' && <p className="hint">From the calendar on your Mac or iPhone. Change it there; Planner picks it up on the next sync.</p>}
        <label>
          Title
          <input value={title} onChange={(e) => setTitle(e.target.value)} required autoFocus={isNew} disabled={!!event.taskId} />
        </label>
        {event.allDay ? (
          <p className="hint">All-day event on {fmtWhen(event.startAt, false)}.</p>
        ) : (
          <div className="row">
            <label>
              Starts
              <input type="datetime-local" value={start} onChange={(e) => changeStart(e.target.value)} required />
            </label>
            <label>
              Ends
              <input type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} required />
            </label>
          </div>
        )}
        <label>
          Notes
          <textarea rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} />
        </label>
        {error && <p className="form-error">{error}</p>}
        <footer>
          {!isNew && event.source !== 'device' && (
            <button type="button" className="btn btn-danger" disabled={busy} onClick={() => run(props.onDelete)}>
              {event.taskId ? 'Remove block' : 'Delete event'}
            </button>
          )}
          <span className="spacer" />
          {event.taskId && (
            <button type="button" className="btn" disabled={busy} onClick={() => run(props.onDoneTask)}>
              Mark task done
            </button>
          )}
          {event.source !== 'device' && (
            <button className="btn btn-primary" disabled={busy}>
              {isNew ? 'Add event' : 'Save changes'}
            </button>
          )}
        </footer>
      </form>
    </Modal>
  );
}

// ---- projects

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

type ProjectDraft = Omit<Project, 'id' | 'sortOrder' | 'archived'> & { id?: string; archived: boolean };
const blankProject = (): ProjectDraft => ({ name: '', tag: '', color: 'teal', emoji: '', archived: false, windows: [], windowStrict: false, hostMatch: null, links: [] });

export function ProjectsDialog(props: {
  projects: Project[];
  onSave: (draft: ProjectDraft) => Promise<void>;
  onRemove: (id: string) => Promise<void>;
  onClose: () => void;
}) {
  const [editing, setEditing] = useState<ProjectDraft | null>(null);
  // The dialog stays open between saves, so busy has to clear on success too.
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError('');
    try {
      await fn();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const visible = props.projects.filter((p) => !p.archived);
  const archived = props.projects.filter((p) => p.archived);

  if (editing) {
    return (
      <ProjectForm
        draft={editing}
        busy={busy}
        error={error}
        onCancel={() => setEditing(null)}
        onSave={(d) => run(async () => {
          await props.onSave(d);
          setEditing(null);
        })}
        onRemove={editing.id ? () => run(async () => {
          await props.onRemove(editing.id!);
          setEditing(null);
        }) : undefined}
        onClose={props.onClose}
      />
    );
  }

  return (
    <Modal title="Projects" onClose={props.onClose}>
      <p className="hint">Type #tag in the capture bar to file a task under a project. Projects can have their own hours for scheduling.</p>
      <ul className="proj-list">
        {visible.map((p) => (
          <li key={p.id} style={projectStyle(p)}>
            <i className="dot" aria-hidden="true" />
            <span className="proj-name">{projectLabel(p)}</span>
            <code>#{p.tag}</code>
            <span className="hint">{p.windows.length || p.hostMatch ? 'Own hours' : 'Working hours'}</span>
            <button className="btn" onClick={() => setEditing({ ...p })}>
              Edit
            </button>
          </li>
        ))}
      </ul>
      {archived.length > 0 && (
        <details>
          <summary>Archived ({archived.length})</summary>
          <ul className="proj-list">
            {archived.map((p) => (
              <li key={p.id} style={projectStyle(p)}>
                <i className="dot" aria-hidden="true" />
                <span className="proj-name">{projectLabel(p)}</span>
                <button className="btn" onClick={() => run(() => props.onSave({ ...p, archived: false }))}>
                  Restore
                </button>
              </li>
            ))}
          </ul>
        </details>
      )}
      {error && <p className="form-error">{error}</p>}
      <footer>
        <span className="spacer" />
        <button className="btn btn-primary" onClick={() => setEditing(blankProject())}>
          New project
        </button>
      </footer>
    </Modal>
  );
}

function ProjectForm(props: {
  draft: ProjectDraft;
  busy: boolean;
  error: string;
  onSave: (d: ProjectDraft) => void;
  onRemove?: () => void;
  onCancel: () => void;
  onClose: () => void;
}) {
  const [d, setD] = useState(props.draft);
  const setWindow = (i: number, w: TimeWindow) => setD({ ...d, windows: d.windows.map((x, j) => (j === i ? w : x)) });
  return (
    <Modal title={d.id ? `Edit ${d.name}` : 'New project'} onClose={props.onClose}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          props.onSave(d);
        }}
      >
        <div className="row">
          <label>
            Name
            <input value={d.name} onChange={(e) => setD({ ...d, name: e.target.value })} required autoFocus />
          </label>
          <label>
            Tag (for #capture)
            <input value={d.tag} onChange={(e) => setD({ ...d, tag: e.target.value })} placeholder="from the name" />
          </label>
        </div>
        <div className="row">
          <label>
            Emoji
            <input value={d.emoji} onChange={(e) => setD({ ...d, emoji: e.target.value })} maxLength={8} />
          </label>
          <fieldset className="colors">
            <legend>Colour</legend>
            {PROJECT_COLORS.map((c) => (
              <label key={c} className={`swatch${d.color === c ? ' is-on' : ''}`} style={{ ['--proj' as string]: `var(--p-${c})` }} title={c}>
                <input type="radio" name="color" value={c} checked={d.color === c} onChange={() => setD({ ...d, color: c as ProjectColor })} />
              </label>
            ))}
          </fieldset>
        </div>

        <h3>When to schedule it</h3>
        <p className="hint">Leave empty to use your working hours.</p>
        {d.windows.map((w, i) => (
          <div key={i} className="window-row">
            <fieldset className="days">
              {WEEKDAYS.map((name, di) => (
                <label key={name} className="day-toggle">
                  <input
                    type="checkbox"
                    checked={w.days.includes(di + 1)}
                    onChange={() =>
                      setWindow(i, { ...w, days: w.days.includes(di + 1) ? w.days.filter((x) => x !== di + 1) : [...w.days, di + 1].sort() })
                    }
                  />
                  <span>{name}</span>
                </label>
              ))}
            </fieldset>
            <input type="time" value={w.start} onChange={(e) => setWindow(i, { ...w, start: e.target.value })} aria-label="From" required />
            <input type="time" value={w.end} onChange={(e) => setWindow(i, { ...w, end: e.target.value })} aria-label="Until" required />
            <button type="button" className="icon-btn" aria-label="Remove these hours" onClick={() => setD({ ...d, windows: d.windows.filter((_, j) => j !== i) })}>
              ×
            </button>
          </div>
        ))}
        <button type="button" className="btn" onClick={() => setD({ ...d, windows: [...d.windows, { days: [1, 2, 3, 4, 5], start: '09:00', end: '12:00' }] })}>
          Add hours
        </button>
        <label>
          Also use calendar events whose title contains
          <input value={d.hostMatch ?? ''} onChange={(e) => setD({ ...d, hostMatch: e.target.value || null })} placeholder="e.g. Career block" />
        </label>
        <label className="inline">
          <input type="checkbox" checked={d.windowStrict} onChange={(e) => setD({ ...d, windowStrict: e.target.checked })} />
          Only these hours (don't fall back to working hours when they're full)
        </label>

        {props.error && <p className="form-error">{props.error}</p>}
        <footer>
          {props.onRemove && (
            <button type="button" className="btn btn-danger" disabled={props.busy} onClick={props.onRemove} title="Archives it if it has tasks">
              Remove
            </button>
          )}
          <span className="spacer" />
          <button type="button" className="btn" onClick={props.onCancel}>
            Back
          </button>
          <button className="btn btn-primary" disabled={props.busy}>
            Save project
          </button>
        </footer>
      </form>
    </Modal>
  );
}

// ---- settings

export function SettingsDialog(props: {
  settings: Settings;
  google: GoogleStatus;
  gmail: GmailStatus;
  canSignOut: boolean;
  onSave: (patch: Partial<Settings>) => Promise<void>;
  onSync: () => Promise<void>;
  onDisconnect: () => Promise<void>;
  onCheckReplies: () => Promise<void>;
  onDisconnectGmail: () => Promise<void>;
  onSignOut: () => void;
  onClose: () => void;
}) {
  const { google, gmail } = props;
  const [s, setS] = useState(props.settings);
  const [copied, setCopied] = useState(false);
  const { busy, error, run, onSubmit } = useSubmit(() => props.onSave({ ...s, timezoneConfirmed: true }));
  const zones: string[] = (Intl as any).supportedValuesOf?.('timeZone') ?? [];
  const mcpUrl = `${location.origin}/mcp`;
  const toggleDay = (d: number) =>
    setS({ ...s, workDays: s.workDays.includes(d) ? s.workDays.filter((x) => x !== d) : [...s.workDays, d].sort() });

  return (
    <Modal title="Settings" onClose={props.onClose}>
      <form onSubmit={onSubmit}>
        <h3>Working hours</h3>
        <p className="hint">Planner only proposes task blocks inside these hours.</p>
        <div className="row">
          <label>
            From
            <input type="time" value={s.workStart} onChange={(e) => setS({ ...s, workStart: e.target.value })} required />
          </label>
          <label>
            Until
            <input type="time" value={s.workEnd} onChange={(e) => setS({ ...s, workEnd: e.target.value })} required />
          </label>
        </div>
        <fieldset className="days">
          <legend>Working days</legend>
          {WEEKDAYS.map((name, i) => (
            <label key={name} className="day-toggle">
              <input type="checkbox" checked={s.workDays.includes(i + 1)} onChange={() => toggleDay(i + 1)} />
              <span>{name}</span>
            </label>
          ))}
        </fieldset>
        <div className="row">
          <label>
            Longest single block (minutes)
            <input type="number" min={30} max={480} step={15} value={s.maxBlockMin} onChange={(e) => setS({ ...s, maxBlockMin: Number(e.target.value) })} />
          </label>
          <label>
            Plan this many days ahead
            <input type="number" min={1} max={60} value={s.horizonDays} onChange={(e) => setS({ ...s, horizonDays: Number(e.target.value) })} />
          </label>
        </div>
        <div className="row">
          <label>
            Buffer around long events (minutes)
            <input type="number" min={0} max={120} step={5} value={s.bufferMin} onChange={(e) => setS({ ...s, bufferMin: Number(e.target.value) })} />
          </label>
          <label>
            …for events at least (minutes)
            <input type="number" min={15} max={1440} step={15} value={s.bufferMinEventMin} onChange={(e) => setS({ ...s, bufferMinEventMin: Number(e.target.value) })} />
          </label>
        </div>
        <label>
          Timezone
          <input list="zones" value={s.timezone} onChange={(e) => setS({ ...s, timezone: e.target.value })} required />
          <datalist id="zones">
            {zones.map((z) => (
              <option key={z} value={z} />
            ))}
          </datalist>
        </label>

        <h3>Google Calendar</h3>
        {!google.configured ? (
          <p className="hint">Not set up on this server yet. Add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET (the README walks through it), then restart.</p>
        ) : google.connected ? (
          <>
            <p className="hint">
              Connected to your primary calendar.{' '}
              {google.lastSyncAt ? `Last synced ${fmtWhen(google.lastSyncAt)}.` : 'Not synced yet.'}
            </p>
            <div className="row-btns">
              <button type="button" className="btn" disabled={busy} onClick={() => run(props.onSync)}>
                Sync now
              </button>
              <button type="button" className="btn btn-danger" disabled={busy} onClick={() => run(props.onDisconnect)}>
                Disconnect
              </button>
            </div>
          </>
        ) : (
          <>
            <p className="hint">Connect to see your real meetings here and have task blocks appear on your Google Calendar.</p>
            <a className="btn" href="/api/google/connect">
              Connect Google Calendar
            </a>
          </>
        )}
        {google.error && <p className="form-error">{google.error}</p>}

        <h3>Gmail replies</h3>
        {!gmail.configured ? (
          <p className="hint">Uses the same Google setup as Google Calendar (GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET).</p>
        ) : gmail.connected ? (
          <>
            <p className="hint">
              Watching for emails from people you're waiting on.{' '}
              {gmail.lastCheckAt ? `Last checked ${fmtWhen(gmail.lastCheckAt)}.` : 'Not checked yet.'}
            </p>
            <div className="row-btns">
              <button type="button" className="btn" disabled={busy} onClick={() => run(props.onCheckReplies)}>
                Check now
              </button>
              <button type="button" className="btn btn-danger" disabled={busy} onClick={() => run(props.onDisconnectGmail)}>
                Disconnect
              </button>
            </div>
          </>
        ) : (
          <>
            <p className="hint">
              Read-only. When someone you're waiting on emails you back, their follow-up is marked “replied” on every device.
              Only works for follow-ups with the person's email address. Separate from Google Calendar, so it doesn't change
              where your calendar comes from.
            </p>
            <a className="btn" href="/api/gmail/connect">
              Connect Gmail
            </a>
          </>
        )}
        {gmail.error && <p className="form-error">{gmail.error}</p>}

        <h3>Agents</h3>
        <p className="hint">Point Claude or any MCP client at this address, sending your MCP token as a bearer token.</p>
        <div className="copy-row">
          <code>{mcpUrl}</code>
          <button
            type="button"
            className="btn"
            onClick={() => navigator.clipboard.writeText(mcpUrl).then(() => setCopied(true))}
          >
            {copied ? 'Copied' : 'Copy address'}
          </button>
        </div>

        {error && <p className="form-error">{error}</p>}
        <footer>
          {props.canSignOut && (
            <button type="button" className="btn" onClick={props.onSignOut}>
              Sign out
            </button>
          )}
          <span className="spacer" />
          <button className="btn btn-primary" disabled={busy}>
            Save settings
          </button>
        </footer>
      </form>
    </Modal>
  );
}
