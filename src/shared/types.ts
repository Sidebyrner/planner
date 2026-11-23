/**
 * 'todo' = open and schedulable, 'waiting' = on someone else (never scheduled;
 * comes back to 'todo' at followUpAt), 'done' = finished.
 */
export type TaskStatus = 'todo' | 'waiting' | 'done';

export interface ChecklistItem {
  id: string;
  text: string;
  done: boolean;
}

export interface Task {
  id: string;
  title: string;
  notes: string;
  status: TaskStatus;
  /** 1 = low, 2 = normal, 3 = high */
  priority: number;
  estimateMin: number;
  dueAt: string | null;
  createdAt: string;
  completedAt: string | null;
  projectId: string | null;
  checklist: ChecklistItem[];
  /** Who the task is waiting on (status 'waiting', or a resurfaced follow-up). */
  waitingOn: string | null;
  /** When a waiting task comes back to 'todo'. */
  followUpAt: string | null;
}

/** A weekly window, e.g. weekdays 06:45–08:15, in the user's timezone. */
export interface TimeWindow {
  /** ISO weekdays, 1 = Monday … 7 = Sunday */
  days: number[];
  start: string; // "06:45"
  end: string; // "08:15"
}

/**
 * A working-hours range. `quick` ranges only take short tasks and Quick batches
 * (the gap before a shift); `deep` ranges only take longer work. Unset takes anything.
 */
export interface WorkRange extends TimeWindow {
  mode?: 'deep' | 'quick';
}

export const PROJECT_COLORS = ['amber', 'teal', 'indigo', 'rose', 'green', 'violet', 'orange', 'slate'] as const;
export type ProjectColor = (typeof PROJECT_COLORS)[number];

export interface Project {
  id: string;
  name: string;
  /** Short handle used as #tag in capture, lower case, no spaces. */
  tag: string;
  color: ProjectColor;
  emoji: string;
  archived: boolean;
  sortOrder: number;
  /** When this project's tasks may be scheduled. Empty = working hours. */
  windows: TimeWindow[];
  /** If true, never fall back to working hours when the windows are full. */
  windowStrict: boolean;
  /**
   * Text matched against mirrored calendar event titles (case-insensitive).
   * Matching events become time for this project's tasks instead of busy time.
   */
  hostMatch: string | null;
}

export interface CalEvent {
  id: string;
  title: string;
  notes: string;
  startAt: string;
  endAt: string;
  allDay: boolean;
  /** Set when this event is a time block reserved for a task. */
  taskId: string | null;
  googleId: string | null;
  /** Id the device calendar gave this event (source 'device' only). */
  externalId: string | null;
  /** The event's own project, or its task's project for task blocks. */
  projectId: string | null;
  /** Tasks sharing one batched block ("Quick: 3 tasks"). Empty otherwise. */
  taskIds: string[];
  /**
   * 'local' = created in Planner, 'google' = pulled from Google Calendar,
   * 'device' = mirrored from the calendars on the user's Mac or iPhone (read-only here).
   */
  source: 'local' | 'google' | 'device';
}

export interface Settings {
  /** IANA zone used for working hours and for reading typed dates. */
  timezone: string;
  timezoneConfirmed: boolean;
  workStart: string; // "09:00"
  workEnd: string; // "17:00"
  /** ISO weekdays, 1 = Monday … 7 = Sunday */
  workDays: number[];
  maxBlockMin: number;
  horizonDays: number;
  /** Minutes kept free before and after long fixed events. 0 = off. */
  bufferMin: number;
  /** Events at least this long get the buffer. */
  bufferMinEventMin: number;
  /**
   * Per-day working hours. When non-empty it replaces workStart/workEnd/workDays,
   * so each day can have its own hours (or none).
   */
  workHours: WorkRange[];
  /**
   * Title fragments (case-insensitive) of events that always block time, even
   * all-day ones, and are never used as a project's host time. E.g. "Mr J's shift".
   */
  busyMatch: string[];
}

export interface ProposedBlock {
  /** The task, or the first task of a batch. */
  taskId: string;
  /** Set for a batched block covering several short tasks. */
  taskIds?: string[];
  title: string;
  startAt: string;
  endAt: string;
  /** True when the block ends after the task's due time. */
  late: boolean;
  projectId: string | null;
  /** True when the project's windows were full and working hours were used instead. */
  outsideWindow?: boolean;
}

export interface ScheduleProposal {
  blocks: ProposedBlock[];
  /** Tasks that did not fit inside the planning horizon. */
  unscheduled: { taskId: string; title: string; remainingMin: number }[];
}

export interface FreeSlot {
  startAt: string;
  endAt: string;
  minutes: number;
}

export interface Captured {
  kind: 'task' | 'event';
  title: string;
  priority: number;
  estimateMin: number | null;
  dueAt: string | null;
  startAt: string | null;
  endAt: string | null;
  /** The #tag as typed, without the #. */
  projectTag: string | null;
  /** The matching project, if the tag matched one. */
  projectId: string | null;
  /** Set when the tag matched nothing: a project with this tag is created on save. */
  newProject: string | null;
  /** "@Sam …" makes a waiting-on task. */
  waitingOn: string | null;
  followUpAt: string | null;
}

export interface GoogleStatus {
  configured: boolean;
  connected: boolean;
  lastSyncAt: string | null;
  error: string | null;
}

export interface AppState {
  tasks: Task[];
  events: CalEvent[];
  projects: Project[];
  settings: Settings;
  google: GoogleStatus;
}
