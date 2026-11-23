import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import type { CalEvent, ChecklistItem, Project, Settings, Task, TimeWindow } from '../shared/types.js';

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
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  tag TEXT NOT NULL UNIQUE,
  color TEXT NOT NULL DEFAULT 'slate',
  emoji TEXT NOT NULL DEFAULT '',
  archived INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  windows TEXT NOT NULL DEFAULT '[]',
  window_strict INTEGER NOT NULL DEFAULT 0,
  host_match TEXT
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
  bufferMin: 0,
  bufferMinEventMin: 120,
};

type Row = Record<string, any>;

function parseJson<T>(value: unknown, fallback: T): T {
  if (typeof value !== 'string' || !value) return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

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
  projectId: r.project_id ?? null,
  checklist: parseJson<ChecklistItem[]>(r.checklist, []),
  waitingOn: r.waiting_on ?? null,
  followUpAt: r.follow_up_at ?? null,
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
  externalId: r.external_id ?? null,
  source: r.source,
  // Task blocks follow their task's project; see EVENT_SELECT.
  projectId: r.effective_project_id ?? r.project_id ?? null,
  taskIds: parseJson<string[]>(r.task_ids, []),
});

const toProject = (r: Row): Project => ({
  id: r.id,
  name: r.name,
  tag: r.tag,
  color: r.color,
  emoji: r.emoji,
  archived: !!r.archived,
  sortOrder: r.sort_order,
  windows: parseJson<TimeWindow[]>(r.windows, []),
  windowStrict: !!r.window_strict,
  hostMatch: r.host_match ?? null,
});

/** Events with the project they belong to: their own, else their task's (first task for a batch). */
const EVENT_SELECT = `SELECT e.*, COALESCE(e.project_id, t.project_id) AS effective_project_id
  FROM events e LEFT JOIN tasks t ON t.id = COALESCE(e.task_id, json_extract(e.task_ids, '$[0]'))`;

/** Lower case, letters/digits/dashes only: "Mr J's" -> "mr-js". */
export function slugTag(value: string): string {
  return value
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/['’]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
}

/** Normalise any parseable timestamp to UTC ISO so string comparison in SQL is safe. */
export function iso(value: string): string {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) throw new Error(`Invalid date: ${value}`);
  return d.toISOString();
}

export type TaskInput = Partial<
  Pick<Task, 'title' | 'notes' | 'priority' | 'estimateMin' | 'dueAt' | 'status' | 'projectId' | 'checklist' | 'waitingOn' | 'followUpAt'>
>;
export type EventInput = Partial<
  Pick<CalEvent, 'title' | 'notes' | 'startAt' | 'endAt' | 'allDay' | 'taskId' | 'googleId' | 'externalId' | 'source' | 'projectId' | 'taskIds'>
>;
export type ProjectInput = Partial<Omit<Project, 'id'>>;

export class Store {
  readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
    this.db.exec(SCHEMA);
    this.migrate();
  }

  private migrate(): void {
    const columns = (table: string) => (this.db.prepare(`PRAGMA table_info(${table})`).all() as Row[]).map((c) => c.name);
    const addColumns = (table: string, defs: Record<string, string>) => {
      const have = columns(table);
      for (const [name, def] of Object.entries(defs)) {
        if (!have.includes(name)) this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${def}`);
      }
    };
    addColumns('events', { external_id: 'TEXT', project_id: 'TEXT', task_ids: "TEXT NOT NULL DEFAULT '[]'" });
    addColumns('tasks', {
      project_id: 'TEXT',
      checklist: "TEXT NOT NULL DEFAULT '[]'",
      waiting_on: 'TEXT',
      follow_up_at: 'TEXT',
    });
    this.db.exec(`
      CREATE UNIQUE INDEX IF NOT EXISTS events_external ON events(source, external_id) WHERE external_id IS NOT NULL;
      CREATE INDEX IF NOT EXISTS tasks_project ON tasks(project_id);
    `);
  }

  // ---- projects

  listProjects(opts: { includeArchived?: boolean } = {}): Project[] {
    const where = opts.includeArchived ? '' : 'WHERE archived = 0';
    return this.db.prepare(`SELECT * FROM projects ${where} ORDER BY sort_order, name`).all().map(toProject);
  }

  getProject(id: string): Project | null {
    const r = this.db.prepare('SELECT * FROM projects WHERE id = ?').get(id);
    return r ? toProject(r) : null;
  }

  getProjectByTag(tag: string): Project | null {
    const r = this.db.prepare('SELECT * FROM projects WHERE tag = ?').get(slugTag(tag));
    return r ? toProject(r) : null;
  }

  createProject(input: ProjectInput & { name: string }): Project {
    const id = randomUUID();
    const tag = slugTag(input.tag || input.name);
    if (!tag) throw new Error('A project needs a name with at least one letter or digit.');
    if (this.getProjectByTag(tag)) throw new Error(`There is already a project tagged #${tag}.`);
    const order = (this.db.prepare('SELECT COALESCE(MAX(sort_order), 0) + 1 AS n FROM projects').get() as Row).n;
    this.db
      .prepare(
        `INSERT INTO projects (id, name, tag, color, emoji, archived, sort_order, windows, window_strict, host_match)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        input.name.trim(),
        tag,
        input.color ?? 'slate',
        input.emoji ?? '',
        input.archived ? 1 : 0,
        input.sortOrder ?? order,
        JSON.stringify(input.windows ?? []),
        input.windowStrict ? 1 : 0,
        input.hostMatch?.trim() || null,
      );
    return this.getProject(id)!;
  }

  updateProject(id: string, patch: ProjectInput): Project | null {
    const cur = this.getProject(id);
    if (!cur) return null;
    const next = { ...cur, ...patch };
    const tag = slugTag(next.tag);
    if (!tag) throw new Error('A project tag needs at least one letter or digit.');
    const clash = this.getProjectByTag(tag);
    if (clash && clash.id !== id) throw new Error(`There is already a project tagged #${tag}.`);
    this.db
      .prepare(
        `UPDATE projects SET name = ?, tag = ?, color = ?, emoji = ?, archived = ?, sort_order = ?, windows = ?,
         window_strict = ?, host_match = ? WHERE id = ?`,
      )
      .run(
        next.name.trim(),
        tag,
        next.color,
        next.emoji,
        next.archived ? 1 : 0,
        next.sortOrder,
        JSON.stringify(next.windows),
        next.windowStrict ? 1 : 0,
        next.hostMatch?.trim() || null,
        id,
      );
    return this.getProject(id);
  }

  /** Deletes a project with no tasks; archives one that has tasks so history keeps its colour. */
  removeProject(id: string): 'deleted' | 'archived' | null {
    if (!this.getProject(id)) return null;
    const used = (this.db.prepare('SELECT COUNT(*) AS n FROM tasks WHERE project_id = ?').get(id) as Row).n;
    if (used > 0) {
      this.db.prepare('UPDATE projects SET archived = 1 WHERE id = ?').run(id);
      return 'archived';
    }
    this.db.prepare('UPDATE events SET project_id = NULL WHERE project_id = ?').run(id);
    this.db.prepare('DELETE FROM projects WHERE id = ?').run(id);
    return 'deleted';
  }

  // ---- tasks

  listTasks(filter: { status?: string; projectId?: string } = {}): Task[] {
    const where: string[] = [];
    const args: string[] = [];
    if (filter.status) {
      where.push('status = ?');
      args.push(filter.status);
    }
    if (filter.projectId) {
      where.push('project_id = ?');
      args.push(filter.projectId);
    }
    const sql = `SELECT * FROM tasks ${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY created_at`;
    return this.db.prepare(sql).all(...args).map(toTask);
  }

  getTask(id: string): Task | null {
    const r = this.db.prepare('SELECT * FROM tasks WHERE id = ?').get(id);
    return r ? toTask(r) : null;
  }

  createTask(input: TaskInput & { title: string }): Task {
    const id = randomUUID();
    const status = input.status ?? 'todo';
    const now = new Date().toISOString();
    this.db
      .prepare(
        `INSERT INTO tasks (id, title, notes, status, priority, estimate_min, due_at, created_at, completed_at,
           project_id, checklist, waiting_on, follow_up_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        input.title,
        input.notes ?? '',
        status,
        input.priority ?? 2,
        input.estimateMin ?? 30,
        input.dueAt ? iso(input.dueAt) : null,
        now,
        status === 'done' ? now : null,
        input.projectId ?? null,
        JSON.stringify(input.checklist ?? []),
        input.waitingOn?.trim() || null,
        input.followUpAt ? iso(input.followUpAt) : null,
      );
    return this.getTask(id)!;
  }

  updateTask(id: string, patch: TaskInput): Task | null {
    const cur = this.getTask(id);
    if (!cur) return null;
    const next = { ...cur, ...patch };
    const dueAt = next.dueAt ? iso(next.dueAt) : null;
    const followUpAt = next.followUpAt ? iso(next.followUpAt) : null;
    const completedAt =
      next.status === 'done' ? (cur.completedAt ?? new Date().toISOString()) : null;
    this.db
      .prepare(
        `UPDATE tasks SET title = ?, notes = ?, status = ?, priority = ?, estimate_min = ?,
         due_at = ?, completed_at = ?, project_id = ?, checklist = ?, waiting_on = ?, follow_up_at = ? WHERE id = ?`,
      )
      .run(
        next.title,
        next.notes,
        next.status,
        next.priority,
        next.estimateMin,
        dueAt,
        completedAt,
        next.projectId ?? null,
        JSON.stringify(next.checklist ?? []),
        next.waitingOn?.trim() || null,
        followUpAt,
        id,
      );
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
      .prepare(`${EVENT_SELECT} WHERE e.end_at > ? AND e.start_at < ? ORDER BY e.start_at`)
      .all(from, to)
      .map(toEvent);
  }

  getEvent(id: string): CalEvent | null {
    const r = this.db.prepare(`${EVENT_SELECT} WHERE e.id = ?`).get(id);
    return r ? toEvent(r) : null;
  }

  getEventByExternalId(source: CalEvent['source'], externalId: string): CalEvent | null {
    const r = this.db.prepare(`${EVENT_SELECT} WHERE e.source = ? AND e.external_id = ?`).get(source, externalId);
    return r ? toEvent(r) : null;
  }

  getEventByGoogleId(googleId: string): CalEvent | null {
    const r = this.db.prepare(`${EVENT_SELECT} WHERE e.google_id = ?`).get(googleId);
    return r ? toEvent(r) : null;
  }

  /** Blocks that include this task: its own blocks and batches it belongs to. */
  blocksForTask(taskId: string, range: { from?: string } = {}): CalEvent[] {
    const from = range.from ? iso(range.from) : '0000';
    return this.db
      .prepare(
        `${EVENT_SELECT} WHERE e.end_at > ? AND (e.task_id = ? OR EXISTS (SELECT 1 FROM json_each(e.task_ids) WHERE value = ?))
         ORDER BY e.start_at`,
      )
      .all(from, taskId, taskId)
      .map(toEvent);
  }

  createEvent(input: EventInput & { title: string; startAt: string; endAt: string }): CalEvent {
    const id = randomUUID();
    const startAt = iso(input.startAt);
    const endAt = iso(input.endAt);
    if (endAt <= startAt) throw new Error('An event must end after it starts.');
    this.db
      .prepare(
        `INSERT INTO events (id, title, notes, start_at, end_at, all_day, task_id, google_id, external_id, source,
           project_id, task_ids)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
        input.externalId ?? null,
        input.source ?? 'local',
        input.projectId ?? null,
        JSON.stringify(input.taskIds ?? []),
      );
    return this.getEvent(id)!;
  }

  updateEvent(id: string, patch: EventInput): CalEvent | null {
    const cur = this.getEvent(id);
    if (!cur) return null;
    // A block's effective project comes from its task; only store one set directly.
    const ownProject = 'projectId' in patch ? (patch.projectId ?? null) : this.ownProjectId(id);
    const next = { ...cur, ...patch };
    const startAt = iso(next.startAt);
    const endAt = iso(next.endAt);
    if (endAt <= startAt) throw new Error('An event must end after it starts.');
    this.db
      .prepare(
        `UPDATE events SET title = ?, notes = ?, start_at = ?, end_at = ?, all_day = ?,
         task_id = ?, google_id = ?, external_id = ?, source = ?, project_id = ?, task_ids = ? WHERE id = ?`,
      )
      .run(
        next.title,
        next.notes,
        startAt,
        endAt,
        next.allDay ? 1 : 0,
        next.taskId,
        next.googleId,
        next.externalId,
        next.source,
        ownProject,
        JSON.stringify(next.taskIds ?? []),
        id,
      );
    return this.getEvent(id);
  }

  private ownProjectId(eventId: string): string | null {
    const r = this.db.prepare('SELECT project_id FROM events WHERE id = ?').get(eventId) as Row | undefined;
    return r?.project_id ?? null;
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
