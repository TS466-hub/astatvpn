/** Конфигурация «⚡ Авто» для приложений на Xray JSON: балансировщик выбирает сервер с наименьшей задержкой. */

const AUTO_REMARK = '🇪🇺 Авто';
const PROBE_URL = 'https://www.gstatic.com/generate_204';

type XrayConfig = { remarks?: string; outbounds?: { tag?: string; protocol?: string }[]; routing?: { rules?: unknown[]; balancers?: unknown[] }; [k: string]: unknown };

/** Добавляет «⚡ Авто» первым пунктом. Если ответ панели не похож на список конфигураций, возвращает null и ответ отдаётся как есть. */
export function withAutoConfig(body: unknown, exclude: string[] = []): XrayConfig[] | null {
  if (!Array.isArray(body) || body.length < 2) return null;
  const configs = body as XrayConfig[];
  if (configs.some((c) => c?.remarks === AUTO_REMARK)) return configs;
  const proxies = configs.map((c) => c?.outbounds?.find((o) => o?.tag === 'proxy'));
  if (proxies.some((p) => !p)) return null;

  // серверы из списка исключений доступны вручную, но не участвуют в автовыборе; если исключены все, берём все
  const skip = new Set(exclude.map((x) => x.trim().toLowerCase()).filter(Boolean));
  const addressOf = (p: any) => String(p?.settings?.vnext?.[0]?.address ?? p?.settings?.servers?.[0]?.address ?? '').toLowerCase();
  const kept = proxies.filter((p, i) => !skip.has(addressOf(p)) && !skip.has(String(configs[i]?.remarks ?? '').toLowerCase()));
  const pool = kept.length ? kept : proxies;
  const base = structuredClone(configs[0]!);
  const tags = pool.map((_, i) => `proxy-${i}`);
  const others = (base.outbounds ?? []).filter((o) => o.tag !== 'proxy');
  const auto: XrayConfig = {
    ...base,
    remarks: AUTO_REMARK,
    outbounds: [...pool.map((p, i) => ({ ...structuredClone(p!), tag: tags[i] })), ...others],
    routing: {
      ...base.routing,
      // правила для российских сайтов и прочие остаются, всё остальное уходит в балансировщик
      rules: [...(base.routing?.rules ?? []), { type: 'field', network: 'tcp,udp', balancerTag: 'auto' }],
      balancers: [{ tag: 'auto', selector: ['proxy-'], strategy: { type: 'leastPing' }, fallbackTag: tags[0] }],
    },
    observatory: { subjectSelector: ['proxy-'], probeUrl: PROBE_URL, probeInterval: '1m', enableConcurrency: true },
  };
  return [auto, ...configs];
}
