import type { CalEvent, Captured, FreeSlot, ProposedBlock, ScheduleProposal, Settings, Task } from '../shared/types.js';
import { parseCapture } from './capture.js';
import type { GoogleCalendar } from './google.js';
import { findFreeSlots, proposeSchedule } from './scheduler.js';
import type { EventInput, Store, TaskInput } from './store.js';

export class NotFound extends Error {}

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

  // ---- tasks

  listTasks(filter: { status?: string } = {}): Task[] {
    return this.store.listTasks(filter);
  }

  createTask(input: TaskInput & { title: string }): Task {
    return this.store.createTask(input);
  }

  async updateTask(id: string, patch: TaskInput): Promise<Task> {
    const before = this.store.getTask(id);
    const task = this.store.updateTask(id, patch);
    if (!before || !task) throw new NotFound(`No task with id ${id}`);

    const now = new Date().toISOString();
    const blocks = this.store.listEvents({ from: now }).filter((e) => e.taskId === id);
    if (task.status === 'done' && before.status !== 'done') {
      // Finishing early gives the reserved time back.
      for (const b of blocks.filter((b) => b.startAt > now)) await this.deleteEvent(b.id);
    } else if (task.title !== before.title) {
      for (const b of blocks) await this.updateEvent(b.id, { title: task.title });
    }
    return task;
  }

  async deleteTask(id: string): Promise<void> {
    const blocks = this.store.listEvents().filter((e) => e.taskId === id);
    for (const b of blocks) await this.deleteEvent(b.id);
    if (!this.store.deleteTask(id)) throw new NotFound(`No task with id ${id}`);
  }

  // ---- events

  listEvents(range: { from?: string; to?: string } = {}): CalEvent[] {
    return this.store.listEvents(range);
  }

  async createEvent(input: EventInput & { title: string; startAt: string; endAt: string }): Promise<CalEvent> {
    if (input.taskId && !this.store.getTask(input.taskId)) throw new NotFound(`No task with id ${input.taskId}`);
    let event = this.store.createEvent({ ...input, googleId: null, source: 'local' });
    await this.withGoogle(async () => {
      const googleId = await this.google.push(event);
      event = this.store.updateEvent(event.id, { googleId })!;
    });
    return event;
  }

  async updateEvent(id: string, patch: EventInput): Promise<CalEvent> {
    const { googleId: _g, source: _s, ...safe } = patch;
    const event = this.store.updateEvent(id, safe);
    if (!event) throw new NotFound(`No event with id ${id}`);
    await this.withGoogle(async () => {
      const googleId = await this.google.push(event);
      if (!event.googleId) this.store.updateEvent(id, { googleId });
    });
    return this.store.getEvent(id)!;
  }

  async deleteEvent(id: string): Promise<void> {
    const event = this.store.getEvent(id);
    if (!event) throw new NotFound(`No event with id ${id}`);
    this.store.deleteEvent(id);
    if (event.googleId) await this.withGoogle(() => this.google.remove(event.googleId!));
  }

  // ---- capture

  preview(text: string): Captured {
    return parseCapture(text, { timezone: this.store.getSettings().timezone });
  }

  async capture(text: string): Promise<{ parsed: Captured; task?: Task; event?: CalEvent }> {
    const parsed = this.preview(text);
    if (parsed.kind === 'event') {
      const event = await this.createEvent({ title: parsed.title, startAt: parsed.startAt!, endAt: parsed.endAt! });
      return { parsed, event };
    }
    const task = this.createTask({
      title: parsed.title,
      priority: parsed.priority,
      dueAt: parsed.dueAt,
      ...(parsed.estimateMin ? { estimateMin: parsed.estimateMin } : {}),
    });
    return { parsed, task };
  }

  // ---- scheduling

  freeSlots(opts: { from?: string; to?: string; minMinutes?: number }): FreeSlot[] {
    const from = opts.from ? new Date(opts.from) : new Date();
    const to = opts.to ? new Date(opts.to) : new Date(from.getTime() + 7 * 24 * 60 * 60 * 1000);
    const events = this.store.listEvents({ from: from.toISOString(), to: to.toISOString() });
    return findFreeSlots(events, this.store.getSettings(), { from, to, minMinutes: opts.minMinutes });
  }

  propose(opts: { taskIds?: string[] } = {}): ScheduleProposal {
    const now = new Date();
    return proposeSchedule({
      tasks: this.store.listTasks({ status: 'todo' }),
      events: this.store.listEvents({ from: now.toISOString() }),
      settings: this.store.getSettings(),
      now,
      taskIds: opts.taskIds,
    });
  }

  async apply(blocks: Pick<ProposedBlock, 'taskId' | 'startAt' | 'endAt'>[]): Promise<CalEvent[]> {
    const created: CalEvent[] = [];
    for (const b of blocks) {
      const task = this.store.getTask(b.taskId);
      if (!task) throw new NotFound(`No task with id ${b.taskId}`);
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
