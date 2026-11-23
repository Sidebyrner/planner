import cookieParser from 'cookie-parser';
import express, { type Express } from 'express';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { apiRouter } from './api.js';
import { Auth, type AuthConfig } from './auth.js';
import { GoogleCalendar, type GoogleConfig } from './google.js';
import { mcpHandler } from './mcp.js';
import { Planner } from './planner.js';
import { Store } from './store.js';

export interface AppConfig {
  dbPath: string;
  auth: AuthConfig;
  google: GoogleConfig;
  /** Folder holding the built web app, if any. */
  staticDir?: string;
  fetchFn?: typeof fetch;
}

export function createApp(config: AppConfig): { app: Express; planner: Planner } {
  const store = new Store(config.dbPath);
  const google = new GoogleCalendar(store, config.google, config.fetchFn);
  const planner = new Planner(store, google);
  const auth = new Auth(config.auth);

  const app = express();
  app.set('trust proxy', 1);
  app.disable('x-powered-by');
  // A device sync can carry a few thousand calendar events.
  app.use(express.json({ limit: '5mb' }));
  app.use(cookieParser());

  app.get('/healthz', (_req, res) => void res.json({ ok: true }));
  app.all('/mcp', auth.requireMcpToken, mcpHandler(planner));
  app.use('/api', apiRouter(planner, auth));

  if (config.staticDir && existsSync(config.staticDir)) {
    app.use(express.static(config.staticDir));
    app.get(/^(?!\/(api|mcp)\b).*/, (_req, res) => res.sendFile(join(config.staticDir!, 'index.html')));
  }

  return { app, planner };
}
