import { mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createApp } from './app.js';
import { randomToken } from './auth.js';

const env = process.env;
const production = env.NODE_ENV === 'production';
const port = Number(env.PORT ?? 8787);
// Unset listens on every interface. Behind a local proxy (tailscale serve), set HOST=127.0.0.1.
const host = env.HOST || undefined;
const publicUrl = (env.PUBLIC_URL ?? `http://localhost:${port}`).replace(/\/$/, '');
const dbPath = resolve(env.DATABASE_PATH ?? './data/planner.db');

if (production) {
  const missing = ['APP_PASSWORD', 'MCP_TOKEN', 'SESSION_SECRET'].filter((k) => !env[k]);
  if (missing.length) {
    console.error(`Refusing to start in production without ${missing.join(', ')}. A hosted Planner with no password would expose your calendar.`);
    process.exit(1);
  }
}

mkdirSync(dirname(dbPath), { recursive: true });

const { app, watcher } = createApp({
  dbPath,
  auth: {
    password: env.APP_PASSWORD,
    mcpToken: env.MCP_TOKEN,
    deviceToken: env.DEVICE_TOKEN,
    secret: env.SESSION_SECRET ?? randomToken(),
    secureCookies: publicUrl.startsWith('https://'),
  },
  google: {
    clientId: env.GOOGLE_CLIENT_ID,
    clientSecret: env.GOOGLE_CLIENT_SECRET,
    redirectUri: `${publicUrl}/api/google/callback`,
  },
  staticDir: join(import.meta.dirname, '../web'),
  webhook: env.WEBHOOK_URL ? { url: env.WEBHOOK_URL, secret: env.WEBHOOK_SECRET } : undefined,
});
watcher?.start();

const onListening = () => {
  console.log(`Planner running at ${publicUrl} (listening on ${host ?? 'all interfaces'}:${port})`);
  console.log(`MCP endpoint: ${publicUrl}/mcp`);
  if (watcher) console.log('Sending block.started to WEBHOOK_URL as task blocks begin.');
  if (!env.APP_PASSWORD) console.log('No APP_PASSWORD set: the app is open to anyone who can reach this port.');
};

if (host) app.listen(port, host, onListening);
else app.listen(port, onListening);
