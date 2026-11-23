export type TaskStatus = 'todo' | 'done';

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
}

export interface ProposedBlock {
  taskId: string;
  title: string;
  startAt: string;
  endAt: string;
  /** True when the block ends after the task's due time. */
  late: boolean;
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
  settings: Settings;
  google: GoogleStatus;
}
