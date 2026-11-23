import { useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import type { CalEvent, GoogleStatus, Settings, Task } from '../shared/types';
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

export function TaskDialog(props: {
  task: Task;
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
  const save = () => props.onSave({ title, notes, estimateMin, priority, dueAt: due ? fromLocalInput(due) : null });
  const { busy, error, run, onSubmit } = useSubmit(save);

  return (
    <Modal title="Task" onClose={props.onClose}>
      <form onSubmit={onSubmit}>
        <label>
          Title
          <input value={title} onChange={(e) => setTitle(e.target.value)} required autoFocus />
        </label>
        <div className="row">
          <label>
            Time needed (minutes)
            <input type="number" min={5} max={1440} step={5} value={estimateMin} onChange={(e) => setEstimate(Number(e.target.value))} required />
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
        <label>
          Due
          <input type="datetime-local" value={due} onChange={(e) => setDue(e.target.value)} />
        </label>
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
          {task.status === 'todo' && (
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

// ---- settings

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export function SettingsDialog(props: {
  settings: Settings;
  google: GoogleStatus;
  canSignOut: boolean;
  onSave: (patch: Partial<Settings>) => Promise<void>;
  onSync: () => Promise<void>;
  onDisconnect: () => Promise<void>;
  onSignOut: () => void;
  onClose: () => void;
}) {
  const { google } = props;
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
