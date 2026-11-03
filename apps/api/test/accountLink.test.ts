import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { closeDb, sql } from '../src/db/index.js';
import { migrate } from '../src/db/migrate.js';
import { signUserToken } from '../src/lib/jwt.js';
import { hashPassword } from '../src/lib/crypto.js';
import { clearSettingsCache, setSettings } from '../src/services/settings.js';
import { extendDays } from '../src/services/subscriptions.js';
import { createPhoneUser, upsertTelegramUser } from '../src/services/users.js';

const M = (globalThis as any).__mocks;
let app: Awaited<ReturnType<typeof buildApp>>;
let tgSerial = 71000;
let phoneSerial = 79005550000;

const inject = (method: 'GET' | 'POST', url: string, opts: { token?: string; tg?: number; body?: object } = {}) => app.inject({
  method, url: `/api/v1${url}`, payload: opts.body,
  headers: {
    ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}),
    ...(opts.tg ? { 'x-internal-key': 'internal-key-for-tests', 'x-tg-user': Buffer.from(JSON.stringify({ id: opts.tg, first_name: 'Руслан' })).toString('base64') } : {}),
  },
});
async function mkSite(balance = 0) {
  const phone = String(phoneSerial++);
  const u = await createPhoneUser(phone, await hashPassword('site-password-1'));
  if (balance) await sql()`update users set balance = ${balance} where id = ${u.id}`;
  return { ...u, phone, token: await signUserToken(u.id) };
}
async function mkTg(balance = 0) {
  const id = tgSerial++;
  const u = await upsertTelegramUser({ id, first_name: 'Руслан' } as any, null);
  if (balance) await sql()`update users set balance = ${balance} where id = ${u.id}`;
  return { ...u, tgId: id };
}
const startLink = async (token: string) => (await inject('POST', '/me/telegram-link', { token })).json() as { token: string; url: string };
const confirm = (token: string, tg: number) => inject('POST', '/internal/tglink/link-confirm', { tg, body: { token } });
const days = (d: Date) => Math.round((d.getTime() - Date.now()) / 86400_000);
const userRow = async (id: string) => (await sql()`select * from users where id = ${id}`)[0];
const subRow = async (id: string) => (await sql()`select * from subscriptions where user_id = ${id}`)[0];

beforeAll(async () => {
  await sql()`drop schema public cascade`;
  await sql()`create schema public`;
  await migrate();
  app = await buildApp({ logger: false });
});
beforeEach(async () => {
  M.rw.state.fail = false;
  await sql()`truncate users, admins, settings, auth_links cascade`;
  clearSettingsCache();
  await setSettings('phone_auth', { enabled: true });
});
afterAll(async () => { await app.close(); await closeDb(); });

describe('связка аккаунта сайта с Telegram', () => {
  it('складывает баланс и дни, история и номер переходят, сайт получает новый токен', async () => {
    const site = await mkSite(5000);
    const tg = await mkTg(7000);
    await extendDays(site.id, 10);
    await extendDays(tg.id, 30);
    await sql()`insert into transactions (user_id, type, amount, balance_after, note) values (${site.id}, 'manual', 5000, 5000, 'с сайта')`;
    const link = await startLink(site.token);
    expect(link.url).toContain(`start=link_${link.token}`);

    const preview = (await inject('POST', '/internal/tglink/link-preview', { tg: tg.tgId, body: { token: link.token } })).json();
    expect(preview).toMatchObject({ alreadyLinked: false, balance: 12000 });
    expect(preview.phone).toContain('•••');
    expect(preview.phone).not.toContain(site.phone.slice(1, 5));

    expect((await inject('GET', `/auth/tglink/${link.token}`)).json().status).toBe('pending');
    expect((await confirm(link.token, tg.tgId)).statusCode).toBe(200);

    expect(await userRow(site.id)).toBeUndefined();
    const merged = (await userRow(tg.id))!;
    expect(Number(merged.balance)).toBe(12000);
    expect(merged.phone).toBe(site.phone);
    expect(days((await subRow(tg.id))!.expires_at)).toBe(40);
    expect(await sql()`select 1 from subscriptions`).toHaveLength(1);
    expect(await sql()`select 1 from transactions where user_id = ${tg.id} and note = 'с сайта'`).toHaveLength(1);

    const poll = (await inject('GET', `/auth/tglink/${link.token}`)).json();
    expect(poll.status).toBe('ok');
    const me = await inject('GET', '/me', { token: poll.accessToken });
    expect(me.json().tgId).toBe(tg.tgId);
    expect(Number(me.json().balance)).toBe(12000);
    expect((await inject('GET', '/me', { token: site.token })).statusCode).toBe(401);
    expect((await inject('POST', '/auth/phone/login', { body: { phone: site.phone, password: 'site-password-1' } })).statusCode).toBe(200);
  });

  it('оставляет более долгую подписку с её ссылкой, в панели удаляется второй пользователь и срок сходится', async () => {
    const site = await mkSite();
    const tg = await mkTg();
    await extendDays(site.id, 60);
    await extendDays(tg.id, 5);
    const keep = (await userRow(site.id))!;
    const drop = (await userRow(tg.id))!;
    await confirm((await startLink(site.token)).token, tg.tgId);
    const merged = (await userRow(tg.id))!;
    expect(merged.rw_id).toBe(keep.rw_id);
    expect(merged.rw_short_uuid).toBe(keep.rw_short_uuid);
    expect(days((await subRow(tg.id))!.expires_at)).toBe(65);
    const panel = M.rw.state.calls as string[];
    expect(panel).toContain(`DELETE /api/users/${drop.rw_id}`);
    expect(panel).not.toContain(`DELETE /api/users/${keep.rw_id}`);
  });

  it('пустой Telegram получает всё с сайта', async () => {
    const site = await mkSite(100);
    await extendDays(site.id, 7);
    const tg = await mkTg();
    await confirm((await startLink(site.token)).token, tg.tgId);
    expect(days((await subRow(tg.id))!.expires_at)).toBe(7);
    expect(Number((await userRow(tg.id))!.balance)).toBe(100);
  });

  it('сбой панели откатывает всё: оба аккаунта целы, ссылку можно повторить', async () => {
    const site = await mkSite(500);
    const tg = await mkTg(700);
    await extendDays(site.id, 10);
    const link = await startLink(site.token);
    M.rw.state.fail = true;
    expect((await confirm(link.token, tg.tgId)).statusCode).toBeGreaterThanOrEqual(500);
    M.rw.state.fail = false;
    expect(await userRow(site.id)).toBeTruthy();
    expect(Number((await userRow(site.id))!.balance)).toBe(500);
    expect(Number((await userRow(tg.id))!.balance)).toBe(700);
    expect((await userRow(tg.id))!.phone).toBeNull();
    expect((await confirm(link.token, tg.tgId)).statusCode).toBe(200);
  });

  it('ссылка одноразовая и не работает как вход', async () => {
    const site = await mkSite();
    const tg = await mkTg();
    const other = await mkTg();
    const link = await startLink(site.token);
    expect((await inject('POST', '/internal/tglink/confirm', { tg: other.tgId, body: { token: link.token } })).statusCode).toBe(404);
    expect((await inject('GET', `/auth/tglink/${link.token}`)).json().status).toBe('pending');
    expect((await confirm(link.token, tg.tgId)).statusCode).toBe(200);
    expect((await confirm(link.token, other.tgId)).statusCode).toBe(404);
    expect(await userRow(other.id)).toBeTruthy();
  });

  it('второй номер к тому же Telegram не привязывается, связанный аккаунт новую ссылку не получает', async () => {
    const a = await mkSite();
    const b = await mkSite();
    const tg = await mkTg();
    const second = await startLink(b.token);
    expect((await confirm((await startLink(a.token)).token, tg.tgId)).statusCode).toBe(200);
    expect((await confirm(second.token, tg.tgId)).statusCode).toBe(409);
    expect(await userRow(b.id)).toBeTruthy();
    expect((await inject('POST', '/me/telegram-link', { token: await signUserToken(tg.id) })).statusCode).toBe(409);
  });

  it('заблокированные не объединяются', async () => {
    const site = await mkSite();
    const tg = await mkTg();
    const link = await startLink(site.token);
    await sql()`update users set status = 'banned' where id = ${site.id}`;
    const r = await inject('POST', '/internal/tglink/link-confirm', { tg: tg.tgId, body: { token: link.token } });
    expect(r.statusCode).toBe(403);
    expect(await userRow(site.id)).toBeTruthy();
  });

  it('запрос подтверждения без внутреннего ключа отклоняется', async () => {
    const site = await mkSite();
    const link = await startLink(site.token);
    expect((await inject('POST', '/internal/tglink/link-confirm', { token: site.token, body: { token: link.token } })).statusCode).toBe(401);
  });
});
