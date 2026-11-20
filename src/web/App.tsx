import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import type { AppState, CalEvent, Captured, ProposedBlock, ScheduleProposal, Task } from '../shared/types';
import { Calendar } from './Calendar';
import { EventDialog, SettingsDialog, TaskDialog, type EventDraft } from './Dialogs';
import { Tasks } from './Tasks';
import { addDays, api, ApiError, fmtDay, fmtDuration, fmtMonth, fmtTime, fmtWhen, startOfDay, startOfWeek } from './util';

function useDayCount(): number {
  const read = () => (window.innerWidth < 760 ? 1 : window.innerWidth < 1180 ? 3 : 7);
  const [n, setN] = useState(read);
  useEffect(() => {
    const on = () => setN(read());
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);
  return n;
}

function describe(c: Captured): string {
  if (c.kind === 'event') return `Event "${c.title}" ${fmtWhen(c.startAt!)} to ${fmtTime(c.endAt!)}`;
  const parts = [`Task "${c.title}"`];
  if (c.dueAt) parts.push(`due ${fmtWhen(c.dueAt)}`);
  if (c.estimateMin) parts.push(fmtDuration(c.estimateMin));
  if (c.priority !== 2) parts.push(c.priority === 3 ? 'high priority' : 'low priority');
  return parts.join(', ');
}

export function App() {
  const [auth, setAuth] = useState<'checking' | 'in' | 'out'>('checking');
  const [loginRequired, setLoginRequired] = useState(false);
  const [state, setState] = useState<AppState | null>(null);
  const [notice, setNotice] = useState<{ text: string; bad?: boolean } | null>(null);
  const [anchor, setAnchor] = useState(() => startOfDay(new Date()));
  const [pane, setPane] = useState<'calendar' | 'tasks'>('calendar');
  const [litTaskId, setLitTaskId] = useState<string | null>(null);
  const [proposal, setProposal] = useState<ScheduleProposal | null>(null);
  const [taskOpen, setTaskOpen] = useState<Task | null>(null);
  const [eventOpen, setEventOpen] = useState<EventDraft | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const days = useDayCount();

  const fail = useCallback((err: unknown) => {
    if (err instanceof ApiError && err.status === 401) return setAuth('out');
    setNotice({ text: (err as Error).message, bad: true });
  }, []);

  const reload = useCallback(async () => {
    try {
      const next = await api<AppState>('GET', '/state');
      // First visit: adopt the browser's timezone so working hours mean what the user expects.
      if (!next.settings.timezoneConfirmed) {
        const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
        next.settings = await api('PUT', '/settings', { timezone, timezoneConfirmed: true });
      }
      setState(next);
    } catch (err) {
      fail(err);
    }
  }, [fail]);

  useEffect(() => {
    api('GET', '/me')
      .then((me) => {
        setLoginRequired(me.loginRequired);
        setAuth(me.signedIn ? 'in' : 'out');
      })
      .catch(fail);
  }, [fail]);

  useEffect(() => {
    if (auth !== 'in') return;
    void reload();
    // Agents change things behind the page's back, so keep it fresh.
    const t = setInterval(() => document.visibilityState === 'visible' && void reload(), 30_000);
    const onFocus = () => void reload();
    window.addEventListener('focus', onFocus);
    return () => {
      clearInterval(t);
      window.removeEventListener('focus', onFocus);
    };
  }, [auth, reload]);

  useEffect(() => {
    if (!notice || notice.bad) return;
    const t = setTimeout(() => setNotice(null), 5000);
    return () => clearTimeout(t);
  }, [notice]);

  /** Run a change, then refresh. */
  const act = useCallback(
    async (fn: () => Promise<unknown>, done?: string) => {
      setBusy(true);
      try {
        await fn();
        await reload();
        if (done) setNotice({ text: done });
      } catch (err) {
        fail(err);
      } finally {
        setBusy(false);
      }
    },
    [reload, fail],
  );
  /** Same, but lets a dialog show the error itself. */
  const actStrict = async (fn: () => Promise<unknown>) => {
    await fn();
    await reload();
  };

  const start = useMemo(() => (days === 7 ? startOfWeek(anchor) : anchor), [days, anchor]);
  const show = (date: string | Date) => {
    setAnchor(startOfDay(new Date(date)));
    setPane('calendar');
  };

  const plan = () =>
    act(async () => {
      const p = await api<ScheduleProposal>('POST', '/schedule/propose');
      if (!p.blocks.length) {
        setProposal(null);
        setNotice({
          text: p.unscheduled.length
            ? `No free working time in the next ${state!.settings.horizonDays} days for ${p.unscheduled.length} task${p.unscheduled.length > 1 ? 's' : ''}. Free up time or widen your working hours in Settings.`
            : 'Every open task already has time on the calendar.',
          bad: p.unscheduled.length > 0,
        });
        return;
      }
      setProposal(p);
      show(p.blocks[0].startAt);
    });

  const book = () =>
    act(async () => {
      const n = proposal!.blocks.length;
      await api('POST', '/schedule/apply', { blocks: proposal!.blocks });
      setProposal(null);
      setNotice({ text: `Booked ${n} block${n > 1 ? 's' : ''}.` });
    });

  const dropProposal = (p: ProposedBlock) =>
    setProposal((cur) => {
      if (!cur) return cur;
      const blocks = cur.blocks.filter((b) => b !== p);
      return blocks.length ? { ...cur, blocks } : null;
    });

  if (auth === 'checking') return null;
  if (auth === 'out') return <Login onDone={() => setAuth('in')} />;
  if (!state) return <p className="loading">Loading your week…</p>;

  const end = addDays(start, days - 1);
  const rangeLabel = days === 1 ? fmtDay(start) : start.getMonth() === end.getMonth() ? fmtMonth(start) : `${fmtDay(start)} to ${fmtDay(end)}`;
  const lateCount = proposal?.blocks.filter((b) => b.late).length ?? 0;

  return (
    <div className="app">
      <header className="top">
        <h1>Planner</h1>
        <Capture
          onCaptured={(text) => {
            setNotice({ text });
            void reload();
          }}
          onShow={show}
          onError={fail}
        />
        <button className="btn btn-plan" onClick={plan} disabled={busy}>
          Plan my tasks
        </button>
        <button className="icon-btn" onClick={() => setSettingsOpen(true)} aria-label="Settings" title="Settings">
          <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true">
            <path fill="currentColor" d="M3 5h8v2H3zm11 0h3v2h-3zM11 3.5h2v5h-2zM3 13h3v2H3zm6 0h8v2H9zm-3-1.500h2v5H6z" />
          </svg>
        </button>
      </header>

      {notice && (
        <div className={`notice${notice.bad ? ' is-bad' : ''}`} role="status">
          <span>{notice.text}</span>
          <button className="icon-btn" onClick={() => setNotice(null)} aria-label="Dismiss">
            ×
          </button>
        </div>
      )}
      {state.google.error && !notice && (
        <div className="notice is-bad" role="status">
          <span>Google Calendar is out of sync: {state.google.error}</span>
          <button className="btn" onClick={() => act(() => api('POST', '/google/sync'), 'Synced with Google Calendar.')}>
            Sync again
          </button>
        </div>
      )}

      {proposal && (
        <div className="proposal" role="region" aria-label="Proposed schedule">
          <p>
            <b>
              {proposal.blocks.length} block{proposal.blocks.length > 1 ? 's' : ''} proposed
            </b>
            , shown dashed on the calendar.
            {lateCount > 0 && ` ${lateCount} would finish after the task is due.`}
            {proposal.unscheduled.length > 0 && ` ${proposal.unscheduled.length} task${proposal.unscheduled.length > 1 ? 's' : ''} did not fit.`}
          </p>
          <button className="btn" onClick={() => setProposal(null)}>
            Discard
          </button>
          <button className="btn btn-primary" onClick={book} disabled={busy}>
            Book these blocks
          </button>
        </div>
      )}

      <nav className="panes" aria-label="View">
        <button className={pane === 'calendar' ? 'is-on' : ''} onClick={() => setPane('calendar')}>
          Calendar
        </button>
        <button className={pane === 'tasks' ? 'is-on' : ''} onClick={() => setPane('tasks')}>
          Tasks ({state.tasks.filter((t) => t.status === 'todo').length})
        </button>
      </nav>

      <main className={`main show-${pane}`}>
        <Tasks
          tasks={state.tasks}
          events={state.events}
          litTaskId={litTaskId}
          onHoverTask={setLitTaskId}
          onToggle={(t) => act(() => api('PATCH', `/tasks/${t.id}`, { status: t.status === 'todo' ? 'done' : 'todo' }))}
          onOpen={setTaskOpen}
          onShowBlock={(e) => show(e.startAt)}
        />

        <section className="cal-wrap" aria-label="Calendar">
          <div className="cal-bar">
            <div className="cal-nav">
              <button className="btn" onClick={() => setAnchor(startOfDay(new Date()))}>
                Today
              </button>
              <button className="icon-btn" onClick={() => setAnchor(addDays(start, -days))} aria-label="Earlier">
                ‹
              </button>
              <button className="icon-btn" onClick={() => setAnchor(addDays(start, days))} aria-label="Later">
                ›
              </button>
            </div>
            <h2>{rangeLabel}</h2>
            <span className="sync">
              {state.google.connected
                ? `Google Calendar synced ${state.google.lastSyncAt ? fmtWhen(state.google.lastSyncAt) : 'never'}`
                : 'Google Calendar not connected'}
            </span>
          </div>
          <Calendar
            start={start}
            days={days}
            events={state.events}
            proposals={proposal?.blocks ?? []}
            settings={state.settings}
            litTaskId={litTaskId}
            onHoverTask={setLitTaskId}
            onOpenEvent={setEventOpen}
            onNewEvent={(at) =>
              setEventOpen({ title: '', notes: '', startAt: at.toISOString(), endAt: new Date(at.getTime() + 3600_000).toISOString(), taskId: null, source: 'local', allDay: false })
            }
            onMoveEvent={(id, at, minutes) =>
              act(() => api('PATCH', `/events/${id}`, { startAt: at.toISOString(), endAt: new Date(at.getTime() + minutes * 60_000).toISOString() }))
            }
            onDropTask={(taskId, at, minutes) =>
              act(() =>
                api('POST', '/schedule/apply', { blocks: [{ taskId, startAt: at.toISOString(), endAt: new Date(at.getTime() + minutes * 60_000).toISOString() }] }),
              )
            }
            onDropProposal={dropProposal}
          />
        </section>
      </main>

      {taskOpen && (
        <TaskDialog
          task={taskOpen}
          onClose={() => setTaskOpen(null)}
          onSave={async (patch) => {
            await actStrict(() => api('PATCH', `/tasks/${taskOpen.id}`, patch));
            setTaskOpen(null);
          }}
          onDelete={async () => {
            await actStrict(() => api('DELETE', `/tasks/${taskOpen.id}`));
            setTaskOpen(null);
          }}
          onSchedule={async () => {
            setTaskOpen(null);
            await plan();
          }}
        />
      )}

      {eventOpen && (
        <EventDialog
          event={eventOpen}
          onClose={() => setEventOpen(null)}
          onSave={async (patch) => {
            await actStrict(() => (eventOpen.id ? api('PATCH', `/events/${eventOpen.id}`, eventOpen.allDay ? { title: patch.title, notes: patch.notes } : patch) : api('POST', '/events', patch)));
            setEventOpen(null);
          }}
          onDelete={async () => {
            await actStrict(() => api('DELETE', `/events/${eventOpen.id}`));
            setEventOpen(null);
          }}
          onDoneTask={async () => {
            await actStrict(() => api('PATCH', `/tasks/${eventOpen.taskId}`, { status: 'done' }));
            setEventOpen(null);
          }}
        />
      )}

      {settingsOpen && (
        <SettingsDialog
          settings={state.settings}
          google={state.google}
          canSignOut={loginRequired}
          onClose={() => setSettingsOpen(false)}
          onSave={async (patch) => {
            await actStrict(() => api('PUT', '/settings', patch));
            setSettingsOpen(false);
          }}
          onSync={() => actStrict(() => api('POST', '/google/sync'))}
          onDisconnect={() => actStrict(() => api('POST', '/google/disconnect'))}
          onSignOut={() => api('POST', '/logout').then(() => setAuth('out'))}
        />
      )}
    </div>
  );
}

function Capture(props: { onCaptured: (summary: string) => void; onShow: (date: string) => void; onError: (e: unknown) => void }) {
  const [text, setText] = useState('');
  const [preview, setPreview] = useState<Captured | null>(null);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const value = text.trim();
    if (!value) return setPreview(null);
    let stale = false;
    const t = setTimeout(() => {
      api('POST', '/capture', { text: value, preview: true })
        .then((r) => !stale && setPreview(r.parsed))
        .catch(() => {});
    }, 180);
    return () => {
      stale = true;
      clearTimeout(t);
    };
  }, [text]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const typing = /INPUT|TEXTAREA|SELECT/.test((e.target as HTMLElement).tagName);
      if (e.key === '/' && !typing && !document.querySelector('dialog[open]')) {
        e.preventDefault();
        input.current?.focus();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const value = text.trim();
    if (!value || busy) return;
    setBusy(true);
    try {
      const r = await api('POST', '/capture', { text: value });
      setText('');
      setPreview(null);
      props.onCaptured(`Added: ${describe(r.parsed)}.`);
      if (r.event) props.onShow(r.event.startAt);
    } catch (err) {
      props.onError(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="capture" onSubmit={submit}>
      <input
        ref={input}
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder="Add a task or event, like “Draft proposal by Friday 2h”"
        aria-label="Add a task or event"
        aria-describedby="capture-preview"
        autoComplete="off"
      />
      <button className="btn btn-primary" disabled={busy || !text.trim()}>
        Add
      </button>
      <p id="capture-preview" className="capture-preview" aria-live="polite">
        {preview ? describe(preview) : ''}
      </p>
    </form>
  );
}

function Login({ onDone }: { onDone: () => void }) {
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    try {
      await api('POST', '/login', { password });
      onDone();
    } catch (err) {
      setError((err as Error).message);
    }
  };
  return (
    <form className="login" onSubmit={submit}>
      <h1>Planner</h1>
      <label>
        Password
        <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoFocus required autoComplete="current-password" />
      </label>
      {error && <p className="form-error">{error}</p>}
      <button className="btn btn-primary">Sign in</button>
    </form>
  );
}
