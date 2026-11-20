import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { Request, Response } from 'express';
import { DateTime } from 'luxon';
import { z } from 'zod';
import type { Planner } from './planner.js';

const when = z.string().describe('ISO 8601 timestamp with offset, e.g. 2026-11-24T14:00:00-05:00');
const priority = z.number().int().min(1).max(3).describe('1 = low, 2 = normal, 3 = high');

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
        'Planner holds one person\'s tasks and calendar together. Tasks carry an estimate, a due time and a priority; ' +
        'a task gets done by reserving time blocks for it on the calendar. Call get_agenda first to see the day and the ' +
        "user's timezone. All timestamps are ISO 8601; include an offset when you send one. To plan work, use " +
        'propose_schedule to preview blocks, then apply_schedule for the ones worth booking (or auto_schedule to do both). ' +
        'When Google Calendar is connected, every event you create, move or delete is written through to it.',
    },
  );

  server.registerTool(
    'get_agenda',
    {
      title: 'Get agenda',
      description:
        'One day at a glance: the events on that day, open tasks (with how much of each is still unscheduled), ' +
        'overdue tasks, the user\'s timezone and working hours, and the current time. Start here.',
      inputSchema: { date: z.string().optional().describe('YYYY-MM-DD in the user\'s timezone. Defaults to today.') },
      annotations: { readOnlyHint: true },
    },
    tool(async ({ date }) => {
      await planner.syncIfStale().catch(() => {});
      const settings = planner.getSettings();
      const day = (date ? DateTime.fromISO(date, { zone: settings.timezone }) : DateTime.now().setZone(settings.timezone)).startOf('day');
      if (!day.isValid) throw new Error('date must look like 2026-11-24');
      const now = new Date().toISOString();
      const future = planner.listEvents({ from: now });
      const tasks = planner.listTasks({ status: 'todo' }).map((t) => {
        const blocks = future.filter((e) => e.taskId === t.id);
        const booked = blocks.reduce((s, e) => s + (Date.parse(e.endAt) - Date.parse(e.startAt)) / 60000, 0);
        return { ...t, unscheduledMin: Math.max(0, t.estimateMin - booked), nextBlockAt: blocks[0]?.startAt ?? null, overdue: !!t.dueAt && t.dueAt < now };
      });
      return {
        now,
        date: day.toISODate(),
        timezone: settings.timezone,
        workingHours: { start: settings.workStart, end: settings.workEnd, isoWeekdays: settings.workDays },
        events: planner.listEvents({ from: day.toUTC().toISO()!, to: day.plus({ days: 1 }).toUTC().toISO()! }),
        openTasks: tasks,
        google: planner.google.status(),
      };
    }),
  );

  server.registerTool(
    'list_tasks',
    {
      title: 'List tasks',
      description: 'List tasks. Defaults to open tasks; pass status "done" or "all" for others.',
      inputSchema: { status: z.enum(['todo', 'done', 'all']).optional() },
      annotations: { readOnlyHint: true },
    },
    tool(({ status }) => planner.listTasks(status === 'all' ? {} : { status: status ?? 'todo' })),
  );

  server.registerTool(
    'create_task',
    {
      title: 'Create task',
      description: 'Add a task. It is not on the calendar until a block is scheduled for it.',
      inputSchema: {
        title: z.string().min(1),
        notes: z.string().optional(),
        priority: priority.optional(),
        estimateMin: z.number().int().min(5).max(24 * 60).optional().describe('How long the work takes, in minutes. Default 30.'),
        dueAt: when.optional(),
      },
    },
    tool((args) => planner.createTask(args)),
  );

  server.registerTool(
    'update_task',
    {
      title: 'Update task',
      description:
        'Change a task. Set status "done" to complete it (this also releases its future time blocks), or "todo" to reopen. ' +
        'Pass dueAt null to clear the due time.',
      inputSchema: {
        id: z.string(),
        title: z.string().min(1).optional(),
        notes: z.string().optional(),
        priority: priority.optional(),
        estimateMin: z.number().int().min(5).max(24 * 60).optional(),
        dueAt: when.nullable().optional(),
        status: z.enum(['todo', 'done']).optional(),
      },
    },
    tool(({ id, ...patch }) => planner.updateTask(id, patch)),
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
      },
    },
    tool((args) => planner.createEvent(args)),
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
      description: 'Book time blocks for tasks, usually the ones propose_schedule returned (edited if needed).',
      inputSchema: { blocks: z.array(z.object({ taskId: z.string(), startAt: when, endAt: when })).min(1) },
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
        '("Draft proposal by Friday 2h !high", "Call supplier Friday 2pm 30 min"). Prefer create_task / create_event when you already know the fields.',
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
