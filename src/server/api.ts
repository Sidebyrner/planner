import { Router, type NextFunction, type Request, type Response } from 'express';
import { z } from 'zod';
import { PROJECT_COLORS, type AppState } from '../shared/types.js';
import { randomToken, type Auth } from './auth.js';
import { DeviceSync, syncDevice } from './device.js';
import { NotFound, ReadOnly, type Planner } from './planner.js';

const when = z.string().refine((v) => !Number.isNaN(Date.parse(v)), 'Not a valid date');
const hm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);

export const ChecklistSchema = z
  .array(z.object({ id: z.string().min(1).max(100), text: z.string().trim().min(1).max(500), done: z.boolean() }))
  .max(100);

const taskFields = {
  title: z.string().trim().min(1).max(300),
  notes: z.string().max(5000),
  priority: z.number().int().min(1).max(3),
  estimateMin: z.number().int().min(5).max(24 * 60),
  dueAt: when.nullable(),
  status: z.enum(['todo', 'waiting', 'done']),
  projectId: z.string().nullable(),
  checklist: ChecklistSchema,
  waitingOn: z.string().trim().max(100).nullable(),
  followUpAt: when.nullable(),
};
const TaskCreate = z.object(taskFields).partial().required({ title: true });
const TaskPatch = z.object(taskFields).partial();

const eventFields = {
  title: z.string().trim().min(1).max(300),
  notes: z.string().max(5000),
  startAt: when,
  endAt: when,
  allDay: z.boolean(),
  taskId: z.string().nullable(),
  projectId: z.string().nullable(),
};
const EventCreate = z.object(eventFields).partial().required({ title: true, startAt: true, endAt: true });
const EventPatch = z.object(eventFields).partial().omit({ taskId: true });

export const WindowSchema = z
  .object({ days: z.array(z.number().int().min(1).max(7)).min(1), start: hm, end: hm })
  .refine((w) => w.end > w.start, 'A window must end after it starts');
const projectFields = {
  name: z.string().trim().min(1).max(80),
  tag: z.string().trim().min(1).max(40),
  color: z.enum(PROJECT_COLORS),
  emoji: z.string().max(16),
  archived: z.boolean(),
  sortOrder: z.number().int(),
  windows: z.array(WindowSchema).max(14),
  windowStrict: z.boolean(),
  hostMatch: z.string().trim().max(100).nullable(),
};
const ProjectCreate = z.object(projectFields).partial().required({ name: true });
const ProjectPatch = z.object(projectFields).partial();

const Booking = z
  .object({ taskId: z.string().optional(), taskIds: z.array(z.string()).min(1).max(20).optional(), startAt: when, endAt: when })
  .refine((b) => b.taskId || b.taskIds, 'Each block needs a taskId or taskIds');

const SettingsPatch = z
  .object({
    timezone: z.string().refine((tz) => {
      try {
        new Intl.DateTimeFormat('en', { timeZone: tz });
        return true;
      } catch {
        return false;
      }
    }, 'Unknown timezone'),
    timezoneConfirmed: z.boolean(),
    workStart: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
    workEnd: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
    workDays: z.array(z.number().int().min(1).max(7)),
    maxBlockMin: z.number().int().min(30).max(480),
    horizonDays: z.number().int().min(1).max(60),
    bufferMin: z.number().int().min(0).max(120),
    bufferMinEventMin: z.number().int().min(15).max(24 * 60),
  })
  .partial();

type Handler = (req: Request, res: Response) => unknown | Promise<unknown>;
const h = (fn: Handler) => (req: Request, res: Response, next: NextFunction) => {
  Promise.resolve()
    .then(() => fn(req, res))
    .then((out) => {
      if (!res.headersSent) res.json(out ?? { ok: true });
    })
    .catch(next);
};

export function apiRouter(planner: Planner, auth: Auth): Router {
  const r = Router();

  r.get('/me', h((req) => ({ signedIn: auth.isSignedIn(req), loginRequired: auth.loginRequired })));

  r.post('/login', h((req, res) => {
    const { password } = z.object({ password: z.string() }).parse(req.body);
    const result = auth.login(req, res, password);
    if (result === 'throttled') return res.status(429).json({ error: 'Too many attempts. Try again in 15 minutes.' });
    if (result === 'wrong') return res.status(401).json({ error: 'That password is not right.' });
    return { ok: true };
  }));

  r.post('/logout', h((_req, res) => auth.logout(res)));

  r.use(auth.requireSession);

  const state = (): AppState => ({
    tasks: planner.listTasks(),
    projects: planner.listProjects({ includeArchived: true }),
    // The client keeps a generous window so week-to-week navigation needs no refetch.
    events: planner.listEvents({
      from: new Date(Date.now() - 45 * 86400_000).toISOString(),
      to: new Date(Date.now() + 120 * 86400_000).toISOString(),
    }),
    settings: planner.getSettings(),
    google: planner.google.status(),
  });

  r.get('/state', h(async () => {
    await planner.syncIfStale().catch(() => {});
    planner.resurfaceWaiting();
    return state();
  }));

  r.get('/projects', h(() => planner.listProjects({ includeArchived: true })));
  r.post('/projects', h((req) => planner.createProject(ProjectCreate.parse(req.body))));
  r.patch('/projects/:id', h((req) => planner.updateProject(String(req.params.id), ProjectPatch.parse(req.body))));
  r.delete('/projects/:id', h((req) => planner.removeProject(String(req.params.id))));

  r.post('/tasks', h((req) => planner.createTask(TaskCreate.parse(req.body))));
  r.patch('/tasks/:id', h((req) => planner.updateTask(String(req.params.id), TaskPatch.parse(req.body))));
  r.delete('/tasks/:id', h((req) => planner.deleteTask(String(req.params.id))));

  r.post('/events', h((req) => planner.createEvent(EventCreate.parse(req.body))));
  r.patch('/events/:id', h((req) => planner.updateEvent(String(req.params.id), EventPatch.parse(req.body))));
  r.delete('/events/:id', h((req) => planner.deleteEvent(String(req.params.id))));

  r.post('/capture', h((req) => {
    const { text, preview } = z.object({ text: z.string().trim().min(1).max(500), preview: z.boolean().optional() }).parse(req.body);
    return preview ? { parsed: planner.preview(text) } : planner.capture(text);
  }));

  r.post('/schedule/propose', h(() => planner.propose()));
  r.post('/schedule/apply', h((req) => {
    const { blocks } = z.object({ blocks: z.array(Booking).min(1) }).parse(req.body);
    return planner.apply(blocks);
  }));

  r.put('/device/events', h((req) => syncDevice(planner, DeviceSync.parse(req.body))));

  r.put('/settings', h((req) => planner.setSettings(SettingsPatch.parse(req.body))));

  // ---- Google Calendar

  r.get('/google/connect', (req, res) => {
    if (!planner.google.configured) return void res.status(400).send('Google Calendar is not set up on this server. Add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET.');
    const state = randomToken();
    res.cookie('planner_oauth', state, { httpOnly: true, sameSite: 'lax', maxAge: 10 * 60 * 1000 });
    res.redirect(planner.google.authUrl(state));
  });

  r.get('/google/callback', async (req, res) => {
    const { code, state, error } = req.query as Record<string, string | undefined>;
    res.clearCookie('planner_oauth');
    try {
      if (error) throw new Error(`Google declined the connection (${error}).`);
      if (!code || !state || state !== req.cookies?.planner_oauth) throw new Error('The connection attempt expired. Start again from Settings.');
      await planner.google.exchangeCode(code);
      await planner.sync();
      res.redirect('/');
    } catch (err) {
      planner.store.setValue('google_error', (err as Error).message);
      res.redirect('/');
    }
  });

  r.post('/google/sync', h(async () => {
    await planner.sync();
    return state();
  }));

  r.post('/google/disconnect', h(() => planner.google.disconnect()));

  r.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof z.ZodError) {
      return void res.status(400).json({ error: err.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`).join('; ') });
    }
    if (err instanceof NotFound) return void res.status(404).json({ error: err.message });
    if (err instanceof ReadOnly) return void res.status(409).json({ error: err.message });
    const message = err instanceof Error ? err.message : 'Something went wrong.';
    const expected = /must end after|Invalid date|Google|sync window|already a project|project (needs|tag needs)/.test(message);
    if (!expected) console.error(err);
    res.status(expected ? 400 : 500).json({ error: expected ? message : 'Something went wrong on the server.' });
  });

  return r;
}
