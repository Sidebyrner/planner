import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { Request, Response } from 'express';
import { DateTime } from 'luxon';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { PROJECT_COLORS, type CalEvent, type Project, type Task } from '../shared/types.js';
import type { Planner } from './planner.js';
import { SettingsPatch } from './api.js';
import { remainingMinutes, workRanges } from './scheduler.js';

const when = z.string().describe('ISO 8601 timestamp with offset, e.g. 2026-11-24T14:00:00-05:00');
const priority = z.number().int().min(1).max(3).describe('1 = low, 2 = normal, 3 = high');
const projectRef = z.string().describe('Project name, #tag or id, e.g. "#career" or "Career"');
const timeWindow = z.object({
  days: z.array(z.number().int().min(1).max(7)).min(1).describe('ISO weekdays, 1 = Monday … 7 = Sunday'),
  start: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).describe('"06:45"'),
  end: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).describe('"08:15"'),
});

const hours = (minutes: number) => Math.round((minutes / 60) * 10) / 10;
const minutesOf = (e: Pick<CalEvent, 'startAt' | 'endAt'>) => (Date.parse(e.endAt) - Date.parse(e.startAt)) / 60000;
const projectLabel = (p: Project | undefined) => (p ? `${p.emoji ? `${p.emoji} ` : ''}${p.name} (#${p.tag})` : 'No project');

function ok(data: unknown) {
  return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }] };
}

/** Wrap a handler so a thrown error reaches the agent as a readable tool error. */
function tool<A>(fn: (args: A) => unknown | Promise<unknown>) {
  return async (args: A) => {
    try {
      return ok(await fn(args));
    } catch (err) {
      return { isError: true, content: [{ type: 'text' as const, text: (err as Error).message }] };
    }
  };
}

export function buildMcpServer(planner: Planner): McpServer {
  const server = new McpServer(
    { name: 'planner', version: '0.1.0' },
    {
      instructions:
        'Planner holds one person\'s tasks and calendar together. Tasks carry an estimate, a due time and a priority, and ' +
        'usually belong to a project (list_projects; refer to one by name or #tag). A task gets done by reserving time ' +
        'blocks for it on the calendar; projects can have their own time windows, and short tasks of one project share a ' +
        '"Quick" block. Call get_agenda first to see the day and the user\'s timezone. All timestamps are ISO 8601; include ' +
        'an offset when you send one. Put steps in a checklist (set_checklist) rather than in the title or notes. When a ' +
        'task is waiting on someone else, set waitingOn and followUpAt instead of scheduling it; list_waiting shows them. ' +
        'To plan work, use plan_week or propose_schedule to preview blocks, then apply_schedule for the ones worth ' +
        'booking (or auto_schedule to do both). weekly_review summarises the week by project.',
    },
  );

  const projectsById = () => new Map(planner.listProjects({ includeArchived: true }).map((p) => [p.id, p]));
  const projectId = (ref: string | null | undefined) => (ref ? planner.resolveProject(ref).id : ref === null || ref === '' ? null : undefined);
  /** Open-task view with what's left to schedule and when it's next on the calendar. */
  const openTaskView = (t: Task, future: CalEvent[], now: number, projects: Map<string, Project>) => {
    const blocks = future.filter((e) => e.taskId === t.id || e.taskIds.includes(t.id));
    return {
      ...t,
      project: t.projectId ? projects.get(t.projectId)?.name ?? null : null,
      unscheduledMin: remainingMinutes(t, future, now),
      nextBlockAt: blocks[0]?.startAt ?? null,
      overdue: !!t.dueAt && Date.parse(t.dueAt) < now,
      checklistProgress: t.checklist.length ? `${t.checklist.filter((c) => c.done).length}/${t.checklist.length}` : null,
    };
  };

  server.registerTool(
    'get_agenda',
    {
      title: 'Get agenda',
      description:
        'One day at a glance: the events on that day, open tasks grouped by project (with how much of each is still ' +
        'unscheduled), overdue tasks, follow-ups that are due, the user\'s timezone and working hours, and the current time. Start here.',
      inputSchema: { date: z.string().optional().describe('YYYY-MM-DD in the user\'s timezone. Defaults to today.') },
      annotations: { readOnlyHint: true },
    },
    tool(async ({ date }) => {
      await planner.syncIfStale().catch(() => {});
      planner.resurfaceWaiting();
      const settings = planner.getSettings();
      const day = (date ? DateTime.fromISO(date, { zone: settings.timezone }) : DateTime.now().setZone(settings.timezone)).startOf('day');
      if (!day.isValid) throw new Error('date must look like 2026-11-24');
      const now = Date.now();
      const nowIso = new Date(now).toISOString();
      const future = planner.listEvents({ from: nowIso });
      const projects = projectsById();
      const open = planner.listTasks({ status: 'todo' }).map((t) => openTaskView(t, future, now, projects));
      const groups = new Map<string, typeof open>();
      for (const t of open) groups.set(t.projectId ?? '', [...(groups.get(t.projectId ?? '') ?? []), t]);
      return {
        now: nowIso,
        date: day.toISODate(),
        timezone: settings.timezone,
        timezoneConfirmed: settings.timezoneConfirmed,
        workingHours: workRanges(settings).map((r) => ({ isoWeekdays: r.days, start: r.start, end: r.end, ...(r.mode ? { mode: r.mode } : {}) })),
        busyMatch: settings.busyMatch,
        events: planner.listEvents({ from: day.toUTC().toISO()!, to: day.plus({ days: 1 }).toUTC().toISO()! }),
        openTasksByProject: [...groups.entries()].map(([id, tasks]) => ({ project: projectLabel(projects.get(id)), projectId: id || null, tasks })),
        followUps: open.filter((t) => t.waitingOn).map((t) => ({ id: t.id, title: t.title, waitingOn: t.waitingOn })),
        google: planner.google.status(),
      };
    }),
  );

  server.registerTool(
    'list_tasks',
    {
      title: 'List tasks',
      description: 'List tasks. Defaults to open tasks; pass status "waiting", "done" or "all" for others, and project to filter.',
      inputSchema: { status: z.enum(['todo', 'waiting', 'done', 'all']).optional(), project: projectRef.optional() },
      annotations: { readOnlyHint: true },
    },
    tool(({ status, project }) =>
      planner.listTasks({
        ...(status === 'all' ? {} : { status: status ?? 'todo' }),
        ...(project ? { projectId: planner.resolveProject(project).id } : {}),
      }),
    ),
  );

  server.registerTool(
    'create_task',
    {
      title: 'Create task',
      description:
        'Add a task. It is not on the calendar until a block is scheduled for it. Give it a project when one fits. ' +
        'Pass waitingOn (a person) for something someone else has to do; it is then never scheduled and comes back at followUpAt.',
      inputSchema: {
        title: z.string().min(1),
        notes: z.string().optional(),
        priority: priority.optional(),
        estimateMin: z.number().int().min(5).max(24 * 60).optional().describe('How long the work takes, in minutes. Default 30.'),
        dueAt: when.optional(),
        project: projectRef.optional(),
        checklist: z.array(z.string().min(1)).max(100).optional().describe('Steps, in order.'),
        waitingOn: z.string().min(1).optional(),
        followUpAt: when.optional().describe('When to chase a waiting task. Default: in two days.'),
      },
    },
    tool(({ project, checklist, ...args }) =>
      planner.createTask({
        ...args,
        projectId: projectId(project),
        ...(checklist ? { checklist: checklist.map((text) => ({ id: randomUUID(), text, done: false })) } : {}),
        ...(args.waitingOn ? { status: 'waiting' as const } : {}),
      }),
    ),
  );

  server.registerTool(
    'update_task',
    {
      title: 'Update task',
      description:
        'Change a task. Status "done" completes it and "waiting" hands it to someone else (both release its future time ' +
        'blocks); "todo" reopens it. Pass dueAt or project null to clear them.',
      inputSchema: {
        id: z.string(),
        title: z.string().min(1).optional(),
        notes: z.string().optional(),
        priority: priority.optional(),
        estimateMin: z.number().int().min(5).max(24 * 60).optional(),
        dueAt: when.nullable().optional(),
        status: z.enum(['todo', 'waiting', 'done']).optional(),
        project: projectRef.nullable().optional(),
        waitingOn: z.string().nullable().optional(),
        followUpAt: when.nullable().optional(),
      },
    },
    tool(({ id, project, ...patch }) =>
      planner.updateTask(id, { ...patch, ...(project !== undefined ? { projectId: projectId(project) } : {}) }),
    ),
  );

  server.registerTool(
    'set_checklist',
    {
      title: 'Set checklist',
      description: 'Replace a task\'s checklist with these steps, in order. Steps already on the list keep their done state.',
      inputSchema: { id: z.string(), items: z.array(z.string().min(1)).max(100) },
    },
    tool(async ({ id, items }) => {
      const task = planner.listTasks().find((t) => t.id === id);
      if (!task) throw new Error(`No task with id ${id}`);
      const existing = new Map(task.checklist.map((c) => [c.text.toLowerCase(), c]));
      const checklist = items.map((text) => existing.get(text.toLowerCase()) ?? { id: randomUUID(), text, done: false });
      return planner.updateTask(id, { checklist });
    }),
  );

  server.registerTool(
    'check_item',
    {
      title: 'Check off a step',
      description: 'Mark one checklist step done (or not). Match by the step\'s id or the start of its text.',
      inputSchema: { id: z.string().describe('Task id'), item: z.string().min(1), done: z.boolean().optional().describe('Default true') },
    },
    tool(async ({ id, item, done }) => {
      const task = planner.listTasks().find((t) => t.id === id);
      if (!task) throw new Error(`No task with id ${id}`);
      const needle = item.toLowerCase();
      const target = task.checklist.find((c) => c.id === item) ?? task.checklist.find((c) => c.text.toLowerCase().startsWith(needle));
      if (!target) throw new Error(`No step matching "${item}". Steps: ${task.checklist.map((c) => c.text).join(' | ') || 'none'}`);
      return planner.updateTask(id, { checklist: task.checklist.map((c) => (c === target ? { ...c, done: done ?? true } : c)) });
    }),
  );

  server.registerTool(
    'list_waiting',
    {
      title: 'List waiting-on',
      description: 'Tasks waiting on someone else, soonest follow-up first, plus resurfaced follow-ups now back on the open list.',
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    tool(() => {
      planner.resurfaceWaiting();
      const projects = projectsById();
      const view = (t: Task) => ({ id: t.id, title: t.title, waitingOn: t.waitingOn, followUpAt: t.followUpAt, project: projectLabel(projects.get(t.projectId ?? '')) });
      return {
        waiting: planner.listTasks({ status: 'waiting' }).sort((a, b) => (a.followUpAt ?? '9').localeCompare(b.followUpAt ?? '9')).map(view),
        followUpNow: planner.listTasks({ status: 'todo' }).filter((t) => t.waitingOn).map(view),
      };
    }),
  );

  server.registerTool(
    'list_projects',
    {
      title: 'List projects',
      description: 'Projects with their #tag, colour, time windows and open-task count. Archived ones only when asked.',
      inputSchema: { includeArchived: z.boolean().optional() },
      annotations: { readOnlyHint: true },
    },
    tool(({ includeArchived }) => {
      const open = planner.listTasks({ status: 'todo' });
      return planner.listProjects({ includeArchived }).map((p) => ({ ...p, openTasks: open.filter((t) => t.projectId === p.id).length }));
    }),
  );

  const projectInput = {
    tag: z.string().optional().describe('Short handle for #tag capture. Default: from the name.'),
    color: z.enum(PROJECT_COLORS).optional(),
    emoji: z.string().max(16).optional(),
    windows: z.array(timeWindow).max(14).optional().describe('When this project\'s tasks may be scheduled. Empty = working hours.'),
    windowStrict: z.boolean().optional().describe('Never fall back to working hours when the windows are full.'),
    hostMatch: z.string().nullable().optional().describe('Calendar events whose title contains this become time for this project.'),
  };

  server.registerTool(
    'create_project',
    { title: 'Create project', description: 'Add a project.', inputSchema: { name: z.string().min(1), ...projectInput } },
    tool((args) => planner.createProject(args)),
  );

  server.registerTool(
    'update_project',
    {
      title: 'Update project',
      description: 'Rename a project, change its tag, colour, emoji or time windows, or archive it.',
      inputSchema: { project: projectRef, name: z.string().min(1).optional(), archived: z.boolean().optional(), ...projectInput },
    },
    tool(({ project, ...patch }) => planner.updateProject(planner.resolveProject(project).id, patch)),
  );

  server.registerTool(
    'get_project',
    {
      title: 'Get project',
      description: 'One project: open tasks, upcoming blocks, waiting-on items and what was finished in the last 14 days.',
      inputSchema: { project: projectRef },
      annotations: { readOnlyHint: true },
    },
    tool(({ project }) => {
      const p = planner.resolveProject(project);
      const now = Date.now();
      const future = planner.listEvents({ from: new Date(now).toISOString() });
      const tasks = planner.listTasks({ projectId: p.id });
      const projects = projectsById();
      return {
        project: p,
        open: tasks.filter((t) => t.status === 'todo').map((t) => openTaskView(t, future, now, projects)),
        waiting: tasks.filter((t) => t.status === 'waiting'),
        upcomingBlocks: future.filter((e) => e.projectId === p.id),
        recentlyDone: tasks.filter((t) => t.status === 'done' && t.completedAt && Date.parse(t.completedAt) > now - 14 * 86400_000),
      };
    }),
  );

  server.registerTool(
    'get_settings',
    {
      title: 'Get settings',
      description: 'Timezone, working hours (per-day ranges), always-busy title rules, block length, horizon and buffers.',
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    tool(async () => planner.getSettings()),
  );

  server.registerTool(
    'update_settings',
    {
      title: 'Update settings',
      description:
        'Change scheduling settings. workHours is a list of {days, start, end, mode?} ranges in the user\'s timezone and ' +
        'replaces the single workStart/workEnd/workDays range (send [] to go back to it); mode "quick" ranges only take ' +
        'short tasks and Quick batches, "deep" only longer work. busyMatch lists title fragments of events that always ' +
        'block time (e.g. "Mr J\'s shift"), even all-day ones, and are never used as a project\'s host time. Each list ' +
        'you send replaces the old one.',
      inputSchema: SettingsPatch.shape,
    },
    tool(async (patch) => planner.setSettings(SettingsPatch.parse(patch))),
  );

  server.registerTool(
    'plan_week',
    {
      title: 'Plan the week',
      description:
        'Preview blocks for open tasks over the next 7 days, using project windows and Quick batches, with a summary per ' +
        'project (hours proposed, blocks outside their windows, what did not fit). Nothing is saved; book with apply_schedule.',
      inputSchema: { project: projectRef.optional().describe('Only this project.') },
      annotations: { readOnlyHint: true },
    },
    tool(async ({ project }) => {
      await planner.syncIfStale().catch(() => {});
      const weekEnd = new Date(Date.now() + 7 * 86400_000).toISOString();
      const onlyProject = project ? planner.resolveProject(project).id : null;
      const taskIds = onlyProject ? planner.listTasks({ status: 'todo', projectId: onlyProject }).map((t) => t.id) : undefined;
      const proposal = planner.propose({ taskIds });
      const blocks = proposal.blocks.filter((b) => b.startAt < weekEnd);
      const projects = projectsById();
      const summary = new Map<string, { project: string; proposedHours: number; blocks: number; outsideWindow: number }>();
      for (const b of blocks) {
        const key = b.projectId ?? '';
        const s = summary.get(key) ?? { project: projectLabel(projects.get(key)), proposedHours: 0, blocks: 0, outsideWindow: 0 };
        s.proposedHours = hours(s.proposedHours * 60 + minutesOf(b));
        s.blocks += 1;
        if (b.outsideWindow) s.outsideWindow += 1;
        summary.set(key, s);
      }
      const later = proposal.blocks.filter((b) => b.startAt >= weekEnd);
      return { blocks, byProject: [...summary.values()], laterThisHorizon: later.length, unscheduled: proposal.unscheduled };
    }),
  );

  server.registerTool(
    'weekly_review',
    {
      title: 'Weekly review',
      description:
        'The week so far (from Monday in the user\'s timezone) by project: tasks finished, hours booked, plus what is overdue, ' +
        'which follow-ups are due, and open tasks with no time booked.',
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    tool(() => {
      planner.resurfaceWaiting();
      const settings = planner.getSettings();
      const now = Date.now();
      const weekStart = DateTime.fromMillis(now, { zone: settings.timezone }).startOf('week').toUTC().toISO()!;
      const weekEnd = DateTime.fromISO(weekStart).plus({ days: 7 }).toUTC().toISO()!;
      const projects = projectsById();
      const tasks = planner.listTasks();
      const weekEvents = planner.listEvents({ from: weekStart, to: weekEnd });
      const future = planner.listEvents({ from: new Date(now).toISOString() });
      const keys = new Set(['', ...projects.keys()]);
      const byProject = [...keys]
        .map((id) => {
          const mine = (t: Task) => (t.projectId ?? '') === id;
          const done = tasks.filter((t) => mine(t) && t.status === 'done' && t.completedAt && t.completedAt >= weekStart);
          const blocks = weekEvents.filter((e) => (e.taskId || e.taskIds.length) && (e.projectId ?? '') === id);
          const p = projects.get(id);
          return {
            project: projectLabel(p),
            archived: p?.archived ?? false,
            finished: done.map((t) => t.title),
            bookedHours: hours(blocks.reduce((s, e) => s + minutesOf(e), 0)),
            openTasks: tasks.filter((t) => mine(t) && t.status === 'todo').length,
          };
        })
        .filter((r) => !r.archived || r.finished.length || r.bookedHours);
      const open = tasks.filter((t) => t.status === 'todo');
      return {
        weekStart,
        byProject,
        overdue: open.filter((t) => t.dueAt && Date.parse(t.dueAt) < now).map((t) => ({ id: t.id, title: t.title, dueAt: t.dueAt })),
        followUpsDue: open.filter((t) => t.waitingOn).map((t) => ({ id: t.id, title: t.title, waitingOn: t.waitingOn })),
        waiting: tasks.filter((t) => t.status === 'waiting').length,
        notBooked: open.filter((t) => remainingMinutes(t, future, now) > 0).map((t) => ({ id: t.id, title: t.title, project: projectLabel(projects.get(t.projectId ?? '')) })),
      };
    }),
  );

  server.registerTool(
    'delete_task',
    {
      title: 'Delete task',
      description: 'Permanently delete a task and every time block reserved for it.',
      inputSchema: { id: z.string() },
      annotations: { destructiveHint: true },
    },
    tool(async ({ id }) => {
      await planner.deleteTask(id);
      return { deleted: id };
    }),
  );

  server.registerTool(
    'list_events',
    {
      title: 'List events',
      description: 'Calendar events overlapping a time range, including task blocks (those have a taskId). Defaults to the next 7 days.',
      inputSchema: { from: when.optional(), to: when.optional() },
      annotations: { readOnlyHint: true },
    },
    tool(async ({ from, to }) => {
      await planner.syncIfStale().catch(() => {});
      const start = from ?? new Date().toISOString();
      const end = to ?? new Date(Date.parse(start) + 7 * 24 * 60 * 60 * 1000).toISOString();
      return planner.listEvents({ from: start, to: end });
    }),
  );

  server.registerTool(
    'create_event',
    {
      title: 'Create event',
      description: 'Put an event on the calendar. Pass taskId to make it a time block reserved for that task.',
      inputSchema: {
        title: z.string().min(1),
        startAt: when,
        endAt: when,
        notes: z.string().optional(),
        allDay: z.boolean().optional(),
        taskId: z.string().optional(),
        project: projectRef.optional(),
      },
    },
    tool(({ project, ...args }) => planner.createEvent({ ...args, projectId: projectId(project) })),
  );

  server.registerTool(
    'update_event',
    {
      title: 'Update event',
      description: 'Move, resize or rename an event or task block.',
      inputSchema: {
        id: z.string(),
        title: z.string().min(1).optional(),
        startAt: when.optional(),
        endAt: when.optional(),
        notes: z.string().optional(),
        allDay: z.boolean().optional(),
      },
    },
    tool(({ id, ...patch }) => planner.updateEvent(id, patch)),
  );

  server.registerTool(
    'delete_event',
    {
      title: 'Delete event',
      description: 'Remove an event or task block from the calendar (and from Google Calendar when connected). The task itself stays.',
      inputSchema: { id: z.string() },
      annotations: { destructiveHint: true },
    },
    tool(async ({ id }) => {
      await planner.deleteEvent(id);
      return { deleted: id };
    }),
  );

  server.registerTool(
    'find_free_slots',
    {
      title: 'Find free time',
      description: 'Open stretches inside working hours that no event occupies. Defaults to the next 7 days and slots of 30 minutes or more.',
      inputSchema: { from: when.optional(), to: when.optional(), minMinutes: z.number().int().min(5).optional() },
      annotations: { readOnlyHint: true },
    },
    tool(async (args) => {
      await planner.syncIfStale().catch(() => {});
      return planner.freeSlots(args);
    }),
  );

  server.registerTool(
    'propose_schedule',
    {
      title: 'Propose schedule',
      description:
        'Preview time blocks for open tasks that are not fully scheduled: earliest due first, then priority, fitted into free ' +
        'working hours. Nothing is saved. Blocks marked late end after the task is due; unscheduled lists what did not fit.',
      inputSchema: { taskIds: z.array(z.string()).optional().describe('Limit to these tasks. Default: all open tasks.') },
      annotations: { readOnlyHint: true },
    },
    tool(async (args) => {
      await planner.syncIfStale().catch(() => {});
      return planner.propose(args);
    }),
  );

  server.registerTool(
    'apply_schedule',
    {
      title: 'Apply schedule',
      description:
        'Book time blocks for tasks, usually the ones propose_schedule or plan_week returned (edited if needed). ' +
        'Pass taskIds for a Quick block shared by several short tasks.',
      inputSchema: {
        blocks: z
          .array(z.object({ taskId: z.string().optional(), taskIds: z.array(z.string()).optional(), startAt: when, endAt: when }))
          .min(1),
      },
    },
    tool(({ blocks }) => planner.apply(blocks)),
  );

  server.registerTool(
    'auto_schedule',
    {
      title: 'Auto-schedule',
      description: 'Propose and book in one step. Use when the user has asked for their tasks to be planned without reviewing each block.',
      inputSchema: { taskIds: z.array(z.string()).optional() },
    },
    tool(async (args) => {
      await planner.syncIfStale().catch(() => {});
      return planner.autoSchedule(args);
    }),
  );

  server.registerTool(
    'capture',
    {
      title: 'Quick capture',
      description:
        'Create a task or event from one plain-language line, parsed the same way as the app\'s capture bar ' +
        '("Draft proposal by Friday 2h !high #work", "Call supplier Friday 2pm 30 min", "@Sam send the invoice Friday"). ' +
        '#tag sets the project (an unknown tag creates one); @Name makes a waiting-on task. Prefer create_task / create_event when you already know the fields.',
      inputSchema: { text: z.string().min(1) },
    },
    tool(({ text }) => planner.capture(text)),
  );

  return server;
}

/** Stateless Streamable HTTP: a fresh server per request, nothing held between calls. */
export function mcpHandler(planner: Planner) {
  return async (req: Request, res: Response) => {
    if (req.method !== 'POST') {
      res.status(405).set('Allow', 'POST').json({ jsonrpc: '2.0', error: { code: -32000, message: 'Method not allowed.' }, id: null });
      return;
    }
    const server = buildMcpServer(planner);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    res.on('close', () => {
      void transport.close();
      void server.close();
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (err) {
      console.error('MCP request failed:', err);
      if (!res.headersSent) {
        res.status(500).json({ jsonrpc: '2.0', error: { code: -32603, message: 'Internal server error' }, id: null });
      }
    }
  };
}
