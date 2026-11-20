import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import type { CalEvent, Settings, Task } from '../shared/types.js';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'todo',
  priority INTEGER NOT NULL DEFAULT 2,
  estimate_min INTEGER NOT NULL DEFAULT 30,
  due_at TEXT,
  created_at TEXT NOT NULL,
  completed_at TEXT
);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  google_id TEXT UNIQUE,
  source TEXT NOT NULL DEFAULT 'local'
);
CREATE INDEX IF NOT EXISTS events_start ON events(start_at);
CREATE INDEX IF NOT EXISTS events_task ON events(task_id);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`;

export const DEFAULT_SETTINGS: Settings = {
  timezone: 'UTC',
  timezoneConfirmed: false,
  workStart: '09:00',
  workEnd: '17:00',
  workDays: [1, 2, 3, 4, 5],
  maxBlockMin: 120,
  horizonDays: 14,
};

type Row = Record<string, any>;

const toTask = (r: Row): Task => ({
  id: r.id,
  title: r.title,
  notes: r.notes,
  status: r.status,
  priority: r.priority,
  estimateMin: r.estimate_min,
  dueAt: r.due_at,
  createdAt: r.created_at,
  completedAt: r.completed_at,
});

const toEvent = (r: Row): CalEvent => ({
  id: r.id,
  title: r.title,
  notes: r.notes,
  startAt: r.start_at,
  endAt: r.end_at,
  allDay: !!r.all_day,
  taskId: r.task_id,
  googleId: r.google_id,
  source: r.source,
});

/** Normalise any parseable timestamp to UTC ISO so string comparison in SQL is safe. */
export function iso(value: string): string {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) throw new Error(`Invalid date: ${value}`);
  return d.toISOString();
}

export type TaskInput = Partial<Pick<Task, 'title' | 'notes' | 'priority' | 'estimateMin' | 'dueAt' | 'status'>>;
export type EventInput = Partial<Pick<CalEvent, 'title' | 'notes' | 'startAt' | 'endAt' | 'allDay' | 'taskId' | 'googleId' | 'source'>>;

export class Store {
  readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
    this.db.exec(SCHEMA);
  }

  // ---- tasks

  listTasks(filter: { status?: string } = {}): Task[] {
    const rows = filter.status
      ? this.db.prepare('SELECT * FROM tasks WHERE status = ? ORDER BY created_at').all(filter.status)
      : this.db.prepare('SELECT * FROM tasks ORDER BY created_at').all();
    return rows.map(toTask);
  }

  getTask(id: string): Task | null {
    const r = this.db.prepare('SELECT * FROM tasks WHERE id = ?').get(id);
    return r ? toTask(r) : null;
  }

  createTask(input: TaskInput & { title: string }): Task {
    const id = randomUUID();
    this.db
      .prepare(
        `INSERT INTO tasks (id, title, notes, priority, estimate_min, due_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        input.title,
        input.notes ?? '',
        input.priority ?? 2,
        input.estimateMin ?? 30,
        input.dueAt ? iso(input.dueAt) : null,
        new Date().toISOString(),
      );
    return this.getTask(id)!;
  }

  updateTask(id: string, patch: TaskInput): Task | null {
    const cur = this.getTask(id);
    if (!cur) return null;
    const next = { ...cur, ...patch };
    const dueAt = next.dueAt ? iso(next.dueAt) : null;
    const completedAt =
      next.status === 'done' ? (cur.completedAt ?? new Date().toISOString()) : null;
    this.db
      .prepare(
        `UPDATE tasks SET title = ?, notes = ?, status = ?, priority = ?, estimate_min = ?,
         due_at = ?, completed_at = ? WHERE id = ?`,
      )
      .run(next.title, next.notes, next.status, next.priority, next.estimateMin, dueAt, completedAt, id);
    return this.getTask(id);
  }

  deleteTask(id: string): boolean {
    return this.db.prepare('DELETE FROM tasks WHERE id = ?').run(id).changes > 0;
  }

  // ---- events

  /** Events overlapping [from, to). Both bounds optional. */
  listEvents(range: { from?: string; to?: string } = {}): CalEvent[] {
    const from = range.from ? iso(range.from) : '0000';
    const to = range.to ? iso(range.to) : '9999';
    return this.db
      .prepare('SELECT * FROM events WHERE end_at > ? AND start_at < ? ORDER BY start_at')
      .all(from, to)
      .map(toEvent);
  }

  getEvent(id: string): CalEvent | null {
    const r = this.db.prepare('SELECT * FROM events WHERE id = ?').get(id);
    return r ? toEvent(r) : null;
  }

  getEventByGoogleId(googleId: string): CalEvent | null {
    const r = this.db.prepare('SELECT * FROM events WHERE google_id = ?').get(googleId);
    return r ? toEvent(r) : null;
  }

  createEvent(input: EventInput & { title: string; startAt: string; endAt: string }): CalEvent {
    const id = randomUUID();
    const startAt = iso(input.startAt);
    const endAt = iso(input.endAt);
    if (endAt <= startAt) throw new Error('An event must end after it starts.');
    this.db
      .prepare(
        `INSERT INTO events (id, title, notes, start_at, end_at, all_day, task_id, google_id, source)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        input.title,
        input.notes ?? '',
        startAt,
        endAt,
        input.allDay ? 1 : 0,
        input.taskId ?? null,
        input.googleId ?? null,
        input.source ?? 'local',
      );
    return this.getEvent(id)!;
  }

  updateEvent(id: string, patch: EventInput): CalEvent | null {
    const cur = this.getEvent(id);
    if (!cur) return null;
    const next = { ...cur, ...patch };
    const startAt = iso(next.startAt);
    const endAt = iso(next.endAt);
    if (endAt <= startAt) throw new Error('An event must end after it starts.');
    this.db
      .prepare(
        `UPDATE events SET title = ?, notes = ?, start_at = ?, end_at = ?, all_day = ?,
         task_id = ?, google_id = ?, source = ? WHERE id = ?`,
      )
      .run(next.title, next.notes, startAt, endAt, next.allDay ? 1 : 0, next.taskId, next.googleId, next.source, id);
    return this.getEvent(id);
  }

  deleteEvent(id: string): boolean {
    return this.db.prepare('DELETE FROM events WHERE id = ?').run(id).changes > 0;
  }

  // ---- settings and other key/value state

  getValue<T>(key: string): T | null {
    const r = this.db.prepare('SELECT value FROM settings WHERE key = ?').get(key) as Row | undefined;
    return r ? (JSON.parse(r.value) as T) : null;
  }

  setValue(key: string, value: unknown): void {
    if (value === null || value === undefined) {
      this.db.prepare('DELETE FROM settings WHERE key = ?').run(key);
      return;
    }
    this.db
      .prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .run(key, JSON.stringify(value));
  }

  getSettings(): Settings {
    return { ...DEFAULT_SETTINGS, ...(this.getValue<Partial<Settings>>('settings') ?? {}) };
  }

  setSettings(patch: Partial<Settings>): Settings {
    const next = { ...this.getSettings(), ...patch };
    this.setValue('settings', next);
    return next;
  }
}
