import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';

const COOKIE = 'planner_session';
const MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

function safeEqual(a: string, b: string): boolean {
  const ha = createHmac('sha256', 'cmp').update(a).digest();
  const hb = createHmac('sha256', 'cmp').update(b).digest();
  return timingSafeEqual(ha, hb);
}

export interface AuthConfig {
  /** Password for the web app. Unset = no login (local development only). */
  password?: string;
  /** Bearer token agents send to /mcp. Unset = open (local development only). */
  mcpToken?: string;
  /** Bearer token the iOS and macOS apps send to /api. Unset = the apps can't sign in. */
  deviceToken?: string;
  secret: string;
  secureCookies: boolean;
}

export class Auth {
  private attempts = new Map<string, { count: number; resetAt: number }>();

  constructor(private config: AuthConfig) {}

  get loginRequired(): boolean {
    return !!this.config.password;
  }

  private sign(expires: number): string {
    return createHmac('sha256', this.config.secret).update(`session:${expires}`).digest('base64url');
  }

  isSignedIn(req: Request): boolean {
    if (!this.loginRequired) return true;
    const header = req.headers.authorization ?? '';
    if (header.startsWith('Bearer ')) {
      return !!this.config.deviceToken && safeEqual(header.slice(7), this.config.deviceToken);
    }
    const [expires, sig] = String(req.cookies?.[COOKIE] ?? '').split('.');
    const exp = Number(expires);
    return !!sig && Number.isFinite(exp) && exp > Date.now() && safeEqual(sig, this.sign(exp));
  }

  /** Returns false when the password is wrong or the caller is being throttled. */
  login(req: Request, res: Response, password: string): 'ok' | 'wrong' | 'throttled' {
    const key = req.ip ?? 'unknown';
    const now = Date.now();
    const entry = this.attempts.get(key);
    if (entry && entry.resetAt > now && entry.count >= 10) return 'throttled';
    if (!this.config.password || !safeEqual(password, this.config.password)) {
      this.attempts.set(key, entry && entry.resetAt > now ? { ...entry, count: entry.count + 1 } : { count: 1, resetAt: now + 15 * 60 * 1000 });
      return 'wrong';
    }
    this.attempts.delete(key);
    const expires = now + MAX_AGE_MS;
    res.cookie(COOKIE, `${expires}.${this.sign(expires)}`, {
      httpOnly: true,
      sameSite: 'lax',
      secure: this.config.secureCookies,
      maxAge: MAX_AGE_MS,
    });
    return 'ok';
  }

  logout(res: Response): void {
    res.clearCookie(COOKIE);
  }

  requireSession = (req: Request, res: Response, next: NextFunction): void => {
    if (this.isSignedIn(req)) return next();
    res.status(401).json({ error: 'Sign in to continue.' });
  };

  requireMcpToken = (req: Request, res: Response, next: NextFunction): void => {
    const token = this.config.mcpToken;
    if (!token) return next();
    const header = req.headers.authorization ?? '';
    const given = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (given && safeEqual(given, token)) return next();
    res.status(401).set('WWW-Authenticate', 'Bearer').json({ jsonrpc: '2.0', error: { code: -32001, message: 'Missing or invalid bearer token.' }, id: null });
  };
}

export function randomToken(): string {
  return randomBytes(24).toString('base64url');
}
