import { sql } from '../db/index.js';
import { alertAdminsThrottled } from './alerts.js';
import { remnawave } from './remnawave.js';
import { getSettings } from './settings.js';

const FAILS_TO_DISABLE = 3;
const OKS_TO_ENABLE = 2;

/**
 * Раз в минуту убирает из подписки серверы упавших нод и возвращает их после восстановления.
 * Последний работающий сервер не трогаем: если панель видит упавшими все ноды, причина скорее в ней самой.
 */
export async function hostFailoverTick(): Promise<{ disabled: number; enabled: number }> {
  const result = { disabled: 0, enabled: 0 };
  if (!(await getSettings('monitoring')).host_failover) return result;
  const [nodes, hosts] = await Promise.all([remnawave.listNodes(), remnawave.listHosts()]);
  const connected = new Set(nodes.filter((n) => n.isConnected && !n.isDisabled).map((n) => n.uuid));
  const rows = await sql()<{ host_uuid: string; fail_count: number; ok_count: number; auto_disabled: boolean }[]>`select * from host_failover`;
  const state = new Map(rows.map((r) => [r.host_uuid, r]));
  const healthy = (nodeIds: string[]) => nodeIds.some((id) => connected.has(id));
  let liveHosts = hosts.filter((h) => !h.isDisabled && healthy(h.nodes ?? [])).length;

  for (const host of hosts) {
    const bound = host.nodes ?? [];
    if (!bound.length) continue; // хост без привязки: состояние неизвестно
    const prev = state.get(host.uuid) ?? { fail_count: 0, ok_count: 0, auto_disabled: false };
    if (host.isDisabled && !prev.auto_disabled) continue; // выключен вручную
    const up = healthy(bound);
    const fails = up ? 0 : prev.fail_count + 1;
    const oks = up ? prev.ok_count + 1 : 0;
    let autoDisabled = prev.auto_disabled;

    if (!up && !host.isDisabled && fails >= FAILS_TO_DISABLE) {
      if (liveHosts > 0) {
        await remnawave.setHostDisabled(host.uuid, true);
        autoDisabled = true;
        result.disabled++;
        void alertAdminsThrottled(`host_down:${host.uuid}`, `Сервер «${host.remark ?? host.address}» недоступен и убран из подписки. Он вернётся сам, когда нода восстановится.`, 600);
      } else {
        void alertAdminsThrottled('all_hosts_down', 'Все ноды недоступны. Серверы оставлены в подписке: проверьте панель и ноды.', 1800);
      }
    } else if (up && prev.auto_disabled && oks >= OKS_TO_ENABLE) {
      await remnawave.setHostDisabled(host.uuid, false);
      autoDisabled = false;
      result.enabled++;
      liveHosts++;
      void alertAdminsThrottled(`host_up:${host.uuid}`, `Сервер «${host.remark ?? host.address}» снова работает и возвращён в подписку.`, 600);
    }
    await sql()`insert into host_failover (host_uuid, fail_count, ok_count, auto_disabled) values (${host.uuid}, ${fails}, ${oks}, ${autoDisabled})
      on conflict (host_uuid) do update set fail_count = excluded.fail_count, ok_count = excluded.ok_count, auto_disabled = excluded.auto_disabled, updated_at = now()`;
  }
  return result;
}
