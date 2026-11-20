import { mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createApp } from './app.js';
import { randomToken } from './auth.js';

const env = process.env;
const production = env.NODE_ENV === 'production';
const port = Number(env.PORT ?? 8787);
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

const { app } = createApp({
  dbPath,
  auth: {
    password: env.APP_PASSWORD,
    mcpToken: env.MCP_TOKEN,
    secret: env.SESSION_SECRET ?? randomToken(),
    secureCookies: publicUrl.startsWith('https://'),
  },
  google: {
    clientId: env.GOOGLE_CLIENT_ID,
    clientSecret: env.GOOGLE_CLIENT_SECRET,
    redirectUri: `${publicUrl}/api/google/callback`,
  },
  staticDir: join(import.meta.dirname, '../web'),
});

app.listen(port, () => {
  console.log(`Planner running at ${publicUrl}`);
  console.log(`MCP endpoint: ${publicUrl}/mcp`);
  if (!env.APP_PASSWORD) console.log('No APP_PASSWORD set: the app is open to anyone who can reach this port.');
});
