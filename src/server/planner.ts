import type { CalEvent, Captured, FreeSlot, Project, ProposedBlock, ScheduleProposal, Settings, Task } from '../shared/types.js';
import { matchProject, parseCapture } from './capture.js';
import type { GoogleCalendar } from './google.js';
import { batchTitle, findFreeSlots, proposeSchedule } from './scheduler.js';
import type { EventInput, ProjectInput, Store, TaskInput } from './store.js';

/** A block to book: one task, or a batch of short tasks sharing one block. */
export type Booking = { startAt: string; endAt: string; taskId?: string; taskIds?: string[] };

/** Statuses that hold no reserved time: finishing or handing off gives future blocks back. */
const RELEASES_TIME = new Set<Task['status']>(['done', 'waiting']);

export class NotFound extends Error {}
export class ReadOnly extends Error {}
/** Asked to plan time before anyone has told Planner which timezone the user is in. */
export class TimezoneUnset extends Error {}

/**
 * Everything the app can do, in one place. The web API and the MCP server
 * both call this, so people and agents get identical behaviour.
 */
export class Planner {
  constructor(
    readonly store: Store,
    readonly google: GoogleCalendar,
  ) {}

  // Google is best-effort: a failed write-through never loses the local change.
  private async withGoogle(fn: () => Promise<void>): Promise<void> {
    if (!this.google.connected) return;
    try {
      await fn();
    } catch (err) {
      this.store.setValue('google_error', (err as Error).message);
    }
  }

  // ---- projects

  listProjects(opts: { includeArchived?: boolean } = {}): Project[] {
    return this.store.listProjects(opts);
  }

  createProject(input: ProjectInput & { name: string }): Project {
    return this.store.createProject(input);
  }

  updateProject(id: string, patch: ProjectInput): Project {
    const project = this.store.updateProject(id, patch);
    if (!project) throw new NotFound(`No project with id ${id}`);
    return project;
  }

  removeProject(id: string): { result: 'deleted' | 'archived' } {
    const result = this.store.removeProject(id);
    if (!result) throw new NotFound(`No project with id ${id}`);
    return { result };
  }

  /** Find a project by id, #tag, tag or name (what an agent or a person would type). */
  resolveProject(ref: string): Project {
    const all = this.store.listProjects({ includeArchived: true });
    const byId = all.find((p) => p.id === ref);
    const byName = all.find((p) => p.name.toLowerCase() === ref.trim().toLowerCase());
    const found = byId ?? byName ?? matchProject(ref.replace(/^#/, ''), all);
    if (!found) throw new NotFound(`No project matches "${ref}". Known: ${all.filter((p) => !p.archived).map((p) => `#${p.tag}`).join(', ') || 'none yet'}.`);
    return found;
  }

  private checkProject(projectId: string | null | undefined): void {
    if (projectId && !this.store.getProject(projectId)) throw new NotFound(`No project with id ${projectId}`);
  }

  // ---- tasks

  listTasks(filter: { status?: string; projectId?: string } = {}): Task[] {
    return this.store.listTasks(filter);
  }

  createTask(input: TaskInput & { title: string }): Task {
    this.checkProject(input.projectId);
    if (input.status === 'waiting' && !input.followUpAt) {
      input = { ...input, followUpAt: new Date(Date.now() + 2 * 86400_000).toISOString() };
    }
    return this.store.createTask(input);
  }

  async updateTask(id: string, patch: TaskInput): Promise<Task> {
    if ('projectId' in patch) this.checkProject(patch.projectId);
    const before = this.store.getTask(id);
    if (before && patch.status === 'waiting' && !patch.followUpAt && !before.followUpAt) {
      patch = { ...patch, followUpAt: new Date(Date.now() + 2 * 86400_000).toISOString() };
    }
    const task = this.store.updateTask(id, patch);
    if (!before || !task) throw new NotFound(`No task with id ${id}`);

    const now = new Date().toISOString();
    const blocks = this.store.blocksForTask(id, { from: now });
    if (RELEASES_TIME.has(task.status) && !RELEASES_TIME.has(before.status)) {
      // Finishing early, or handing it to someone else, gives the reserved time back.
      await this.releaseBlocks(id, blocks.filter((b) => b.startAt > now));
    } else if (task.title !== before.title) {
      for (const b of blocks.filter((b) => b.taskId === id)) await this.updateEvent(b.id, { title: task.title });
    }
    return task;
  }

  /** Drop this task's future blocks; a batch is removed only once none of its tasks still need it. */
  private async releaseBlocks(taskId: string, blocks: CalEvent[]): Promise<void> {
    for (const b of blocks) {
      if (b.taskId === taskId) {
        await this.deleteEvent(b.id);
        continue;
      }
      const stillOpen = b.taskIds.filter((t) => t !== taskId && this.store.getTask(t)?.status === 'todo');
      if (stillOpen.length === 0) await this.deleteEvent(b.id);
    }
  }

  async deleteTask(id: string): Promise<void> {
    const blocks = this.store.blocksForTask(id);
    for (const b of blocks) {
      if (b.taskId === id) {
        await this.deleteEvent(b.id);
        continue;
      }
      const rest = b.taskIds.filter((t) => t !== id);
      if (rest.length === 0) await this.deleteEvent(b.id);
      else this.store.updateEvent(b.id, { taskIds: rest, title: batchTitle(rest.length) });
    }
    if (!this.store.deleteTask(id)) throw new NotFound(`No task with id ${id}`);
  }

  /** Waiting tasks whose follow-up time has come go back on the open list. */
  resurfaceWaiting(now = new Date()): Task[] {
    const due = this.store.listTasks({ status: 'waiting' }).filter((t) => t.followUpAt && Date.parse(t.followUpAt) <= now.getTime());
    return due.map((t) => this.store.updateTask(t.id, { status: 'todo' })!);
  }

  // ---- events

  listEvents(range: { from?: string; to?: string } = {}): CalEvent[] {
    return this.store.listEvents(range);
  }

  async createEvent(input: EventInput & { title: string; startAt: string; endAt: string }): Promise<CalEvent> {
    if (input.taskId && !this.store.getTask(input.taskId)) throw new NotFound(`No task with id ${input.taskId}`);
    for (const t of input.taskIds ?? []) if (!this.store.getTask(t)) throw new NotFound(`No task with id ${t}`);
    this.checkProject(input.projectId);
    let event = this.store.createEvent({ ...input, googleId: null, externalId: null, source: 'local' });
    await this.withGoogle(async () => {
      const googleId = await this.google.push(event);
      event = this.store.updateEvent(event.id, { googleId })!;
    });
    return event;
  }

  private assertEditable(id: string): CalEvent {
    const event = this.store.getEvent(id);
    if (!event) throw new NotFound(`No event with id ${id}`);
    if (event.source === 'device') {
      throw new ReadOnly('This event comes from the calendar on your Mac or iPhone. Change it there; Planner picks it up on the next sync.');
    }
    return event;
  }

  async updateEvent(id: string, patch: EventInput): Promise<CalEvent> {
    this.assertEditable(id);
    const { googleId: _g, externalId: _x, source: _s, ...safe } = patch;
    const event = this.store.updateEvent(id, safe)!;
    await this.withGoogle(async () => {
      const googleId = await this.google.push(event);
      if (!event.googleId) this.store.updateEvent(id, { googleId });
    });
    return this.store.getEvent(id)!;
  }

  async deleteEvent(id: string): Promise<void> {
    const event = this.assertEditable(id);
    this.store.deleteEvent(id);
    if (event.googleId) await this.withGoogle(() => this.google.remove(event.googleId!));
  }

  // ---- capture

  preview(text: string): Captured {
    return parseCapture(text, {
      timezone: this.store.getSettings().timezone,
      projects: this.store.listProjects({ includeArchived: true }),
    });
  }

  async capture(text: string): Promise<{ parsed: Captured; task?: Task; event?: CalEvent; project?: Project }> {
    const parsed = this.preview(text);
    let projectId = parsed.projectId;
    let project: Project | undefined;
    if (!projectId && parsed.newProject) {
      project = this.store.createProject({ name: parsed.projectTag ?? parsed.newProject, tag: parsed.newProject });
      projectId = project.id;
    }
    if (parsed.kind === 'event') {
      const event = await this.createEvent({ title: parsed.title, startAt: parsed.startAt!, endAt: parsed.endAt!, projectId });
      return { parsed, event, ...(project ? { project } : {}) };
    }
    const task = this.createTask({
      title: parsed.title,
      priority: parsed.priority,
      dueAt: parsed.dueAt,
      projectId,
      ...(parsed.estimateMin ? { estimateMin: parsed.estimateMin } : {}),
      ...(parsed.waitingOn ? { status: 'waiting' as const, waitingOn: parsed.waitingOn, followUpAt: parsed.followUpAt } : {}),
    });
    return { parsed, task, ...(project ? { project } : {}) };
  }

  // ---- scheduling

  /**
   * Working hours mean nothing until the timezone is known: with the UTC default,
   * "09:00" would book 4 AM in Detroit. Refuse instead of guessing.
   */
  private requireTimezone(): void {
    if (!this.store.getSettings().timezoneConfirmed) {
      throw new TimezoneUnset(
        'Planner does not know your timezone yet, so working hours would be read as UTC. Open the Planner app once, ' +
          'or set it with update_settings (e.g. timezone "America/Detroit"), then try again.',
      );
    }
  }

  freeSlots(opts: { from?: string; to?: string; minMinutes?: number }): FreeSlot[] {
    this.requireTimezone();
    const from = opts.from ? new Date(opts.from) : new Date();
    const to = opts.to ? new Date(opts.to) : new Date(from.getTime() + 7 * 24 * 60 * 60 * 1000);
    const events = this.store.listEvents({ from: from.toISOString(), to: to.toISOString() });
    return findFreeSlots(events, this.store.getSettings(), { from, to, minMinutes: opts.minMinutes });
  }

  propose(opts: { taskIds?: string[]; now?: Date } = {}): ScheduleProposal {
    this.requireTimezone();
    const now = opts.now ?? new Date();
    return proposeSchedule({
      tasks: this.store.listTasks({ status: 'todo' }),
      events: this.store.listEvents({ from: now.toISOString() }),
      settings: this.store.getSettings(),
      projects: this.store.listProjects(),
      now,
      taskIds: opts.taskIds,
    });
  }

  async apply(blocks: Booking[]): Promise<CalEvent[]> {
    const created: CalEvent[] = [];
    for (const b of blocks) {
      if (b.taskIds && b.taskIds.length > 1) {
        for (const id of b.taskIds) if (!this.store.getTask(id)) throw new NotFound(`No task with id ${id}`);
        created.push(await this.createEvent({ title: batchTitle(b.taskIds.length), startAt: b.startAt, endAt: b.endAt, taskIds: b.taskIds }));
        continue;
      }
      const taskId = b.taskId ?? b.taskIds?.[0];
      const task = taskId ? this.store.getTask(taskId) : null;
      if (!task) throw new NotFound(`No task with id ${taskId}`);
      created.push(await this.createEvent({ title: task.title, startAt: b.startAt, endAt: b.endAt, taskId: task.id }));
    }
    return created;
  }

  /** Propose and book in one step, for agents told to "just plan it". */
  async autoSchedule(opts: { taskIds?: string[] } = {}): Promise<{ created: CalEvent[]; unscheduled: ScheduleProposal['unscheduled'] }> {
    const proposal = this.propose(opts);
    return { created: await this.apply(proposal.blocks), unscheduled: proposal.unscheduled };
  }

  // ---- settings and sync

  getSettings(): Settings {
    return this.store.getSettings();
  }

  setSettings(patch: Partial<Settings>): Settings {
    return this.store.setSettings(patch);
  }

  /** Pull from Google if connected and the mirror is older than `maxAgeMs`. */
  async syncIfStale(maxAgeMs = 5 * 60 * 1000): Promise<void> {
    if (!this.google.connected) return;
    const last = this.google.status().lastSyncAt;
    if (last && Date.now() - Date.parse(last) < maxAgeMs) return;
    await this.sync();
  }

  async sync(): Promise<void> {
    try {
      await this.google.pull();
    } catch (err) {
      this.store.setValue('google_error', (err as Error).message);
      throw err;
    }
  }
}
