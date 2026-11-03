import { config } from '../config.js';
import { sql, type TxSql } from '../db/index.js';
import type { SubscriptionRow, UserRow } from '../db/types.js';
import { randomToken } from '../lib/crypto.js';
import { conflict, forbidden, notFound } from '../lib/errors.js';
import { alertAdminsThrottled } from './alerts.js';
import { remnawave } from './remnawave.js';
import { pushMergedAccess } from './subscriptions.js';

const LINK_TTL_MIN = 10;
/** user_id без внешнего ключа: для них миграция внешних ключей не сработает. */
const EXTRA_REFS: [string, string][] = [['trial_activations', 'user_id'], ['bot_activity_events', 'user_id']];

const maskPhone = (p: string | null) => (p ? `+${p.slice(0, -7)}•••${p.slice(-4)}` : '');
const daysLeft = (s: SubscriptionRow | undefined) => (s && s.expires_at > new Date() ? Math.ceil((s.expires_at.getTime() - Date.now()) / 86400_000) : 0);
const quoteIdent = (s: string) => `"${s.replace(/"/g, '""')}"`;

export async function startTelegramLink(user: UserRow) {
  if (user.tg_id) throw conflict('Этот аккаунт уже связан с Telegram', 'already_linked');
  const bot = config().BOT_USERNAME;
  if (!bot) throw conflict('Бот не настроен', 'bot_missing');
  const token = randomToken(18);
  await sql()`delete from auth_links where expires_at < now()`;
  await sql()`insert into auth_links (token, link_user_id, expires_at) values (${token}, ${user.id}, now() + make_interval(mins => ${LINK_TTL_MIN}))`;
  return { token, url: `https://t.me/${bot}?start=link_${token}`, expiresInSec: LINK_TTL_MIN * 60 };
}

async function pendingLink(token: string) {
  const [l] = await sql()`select link_user_id from auth_links where token = ${token} and expires_at > now() and user_id is null and link_user_id is not null`;
  if (!l) throw notFound('Ссылка устарела. Нажмите «Связать с Telegram» на сайте ещё раз.');
  return l.link_user_id as string;
}

/** Что увидит человек в боте перед объединением. */
export async function previewTelegramLink(token: string, tgUser: UserRow) {
  const siteId = await pendingLink(token);
  const [site] = await sql()<UserRow[]>`select * from users where id = ${siteId}`;
  if (!site) throw notFound('Ссылка устарела. Нажмите «Связать с Telegram» на сайте ещё раз.');
  const subs = await sql()<SubscriptionRow[]>`select * from subscriptions where user_id in (${site.id}, ${tgUser.id})`;
  return {
    phone: maskPhone(site.phone),
    alreadyLinked: tgUser.phone !== null || site.tg_id !== null,
    balance: Number(site.balance) + Number(tgUser.balance),
    days: subs.reduce((sum, s) => sum + daysLeft(s), 0),
  };
}

/** Переносит все ссылки на пользователя from → to. Строки, конфликтующие с уникальным ключом, остаются у from и удалятся вместе с ним. */
async function moveReferences(tx: TxSql, from: string, to: string) {
  const fks = await tx<{ tbl: string; col: string }[]>`
    select c.conrelid::regclass::text as tbl, a.attname as col from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    where c.contype = 'f' and c.confrelid = 'users'::regclass and c.conrelid <> 'subscriptions'::regclass`;
  for (const { tbl, col } of [...fks, ...EXTRA_REFS.map(([t, c]) => ({ tbl: t, col: c }))]) {
    const indexes = await tx<{ cols: string[] }[]>`
      select array(select attname::text from pg_attribute where attrelid = i.indrelid and attnum = any(i.indkey)) as cols
      from pg_index i where i.indrelid = ${tbl}::regclass and i.indisunique`;
    const c = quoteIdent(col);
    const conflicts = indexes.filter((i) => i.cols.includes(col)).map((i) => {
      const others = i.cols.filter((k) => k !== col).map((k) => ` and x.${quoteIdent(k)} = o.${quoteIdent(k)}`).join('');
      return ` and not exists (select 1 from ${tbl} x where x.${c} = $2${others})`;
    }).join('');
    await tx.unsafe(`update ${tbl} o set ${c} = $2 where o.${c} = $1${conflicts}`, [from, to]);
  }
}

/**
 * Объединяет аккаунт сайта с аккаунтом Telegram. Остаётся строка Telegram: бот находит пользователя по tg_id.
 * Панель обновляется внутри транзакции: при её сбое база откатывается и оба аккаунта остаются как были.
 */
export async function mergeTelegramLink(token: string, tgUserId: string): Promise<UserRow> {
  const { merged, dropRwId } = await sql().begin(async (tx) => {
    const [link] = await tx`select link_user_id from auth_links where token = ${token} and expires_at > now() and user_id is null and link_user_id is not null for update`;
    if (!link) throw notFound('Ссылка устарела. Нажмите «Связать с Telegram» на сайте ещё раз.');
    const siteId = link.link_user_id as string;
    if (siteId === tgUserId) throw conflict('Этот аккаунт уже связан с Telegram', 'already_linked');
    const rows = await tx<UserRow[]>`select * from users where id in (${siteId}, ${tgUserId}) order by id for update`;
    const site = rows.find((u) => u.id === siteId);
    const tg = rows.find((u) => u.id === tgUserId);
    if (!site || !tg) throw notFound('Аккаунт не найден');
    if (site.tg_id) throw conflict('Этот аккаунт уже связан с другим Telegram', 'already_linked');
    if (tg.phone) throw conflict('Этот Telegram уже связан с другим номером', 'already_linked');
    if (site.status === 'banned' || tg.status === 'banned') throw forbidden('Аккаунт заблокирован');

    const subs = await tx<SubscriptionRow[]>`select * from subscriptions where user_id in (${site.id}, ${tg.id}) for update`;
    const siteSub = subs.find((s) => s.user_id === site.id);
    const tgSub = subs.find((s) => s.user_id === tg.id);
    const now = new Date();
    const rank = (s: SubscriptionRow) => [s.expires_at > now && !s.is_trial ? 1 : 0, s.expires_at.getTime()] as const;
    // База: платная активная, затем самая долгая. Её ссылка VPN продолжит работать.
    const baseIsSite = Boolean(siteSub) && (!tgSub || rank(siteSub!)[0] > rank(tgSub)[0] || (rank(siteSub!)[0] === rank(tgSub)[0] && rank(siteSub!)[1] > rank(tgSub)[1]));
    const base = baseIsSite ? siteSub : tgSub;
    const other = baseIsSite ? tgSub : siteSub;
    const rwOwner = base ? (baseIsSite ? site : tg) : tg.rw_id ? tg : site;
    const rwLoser = rwOwner === site ? tg : site;

    await moveReferences(tx, site.id, tg.id);

    await tx`update users set tg_id = null, phone = null, email = null, rw_id = null, rw_short_uuid = null, rw_username = null where id = ${site.id}`;
    if (tg.id !== rwOwner.id) await tx`update users set rw_id = null, rw_short_uuid = null, rw_username = null where id = ${tg.id}`;
    const [merged] = await tx<UserRow[]>`update users set
      phone = ${site.phone}, password_hash = ${site.password_hash}, email = coalesce(email, ${site.email}),
      balance = balance + ${site.balance}, ref_balance = ref_balance + ${site.ref_balance},
      trial_used = trial_used or ${site.trial_used}, signup_bonus_done = signup_bonus_done or ${site.signup_bonus_done},
      discount_pct = greatest(discount_pct, ${site.discount_pct}),
      referrer_id = nullif(coalesce(referrer_id, ${site.referrer_id}), id), partner_link_id = coalesce(partner_link_id, ${site.partner_link_id}),
      auto_renew = ${base ? (baseIsSite ? site.auto_renew : tg.auto_renew) : tg.auto_renew},
      rw_id = ${rwOwner.rw_id}, rw_short_uuid = ${rwOwner.rw_short_uuid}, rw_username = ${rwOwner.rw_username}
      where id = ${tg.id} returning *`;
    if (Number(site.balance) > 0) {
      await tx`insert into transactions (user_id, type, amount, balance_after, note) values (${tg.id}, 'manual', ${site.balance}, ${merged!.balance}, 'Объединение с аккаунтом сайта')`;
    }

    if (base) {
      const otherActive = other && other.expires_at > now;
      const extraMs = otherActive ? other.expires_at.getTime() - now.getTime() : 0;
      const baseStart = base.expires_at > now ? base.expires_at : now;
      const expires = base.expires_at > now || otherActive ? new Date(baseStart.getTime() + extraMs) : base.expires_at;
      // В лимитах уже учтены докупки: складываем докупки, а базовый лимит берём больший. 0 означает «без ограничений».
      const combine = (a: number, aExtra: number, b: number, bExtra: number) => (a === 0 || b === 0 ? 0 : Math.max(a - aExtra, b - bExtra) + aExtra + bExtra);
      const traffic = otherActive ? combine(Number(base.traffic_limit_bytes), Number(base.extra_traffic_bytes), Number(other.traffic_limit_bytes), Number(other.extra_traffic_bytes)) : Number(base.traffic_limit_bytes);
      const devices = otherActive ? combine(base.device_limit, base.extra_devices, other.device_limit, other.extra_devices) : base.device_limit;
      if (other) await tx`delete from subscriptions where id = ${other.id}`;
      await tx`update subscriptions set user_id = ${tg.id}, expires_at = ${expires},
        is_trial = ${base.is_trial && !(otherActive && !other.is_trial)},
        traffic_limit_bytes = ${traffic}, device_limit = ${devices},
        extra_devices = ${base.extra_devices + (otherActive ? other.extra_devices : 0)},
        extra_traffic_bytes = ${Number(base.extra_traffic_bytes) + (otherActive ? Number(other.extra_traffic_bytes) : 0)},
        updated_at = now() where id = ${base.id}`;
    }
    await tx`update auth_links set user_id = ${tg.id}, link_user_id = null where token = ${token}`;
    await tx`delete from users where id = ${site.id}`;
    await pushMergedAccess(tx, merged!);
    return { merged: merged!, dropRwId: rwLoser.rw_id };
  });
  if (dropRwId) {
    await remnawave.deleteUser(dropRwId).catch((e) => alertAdminsThrottled('merge_rw_delete', `После объединения аккаунтов не удалось удалить пользователя панели ${dropRwId}: ${(e as Error).message}`, 60));
  }
  return merged;
}
