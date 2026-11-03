import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { closeDb, sql } from '../src/db/index.js';
import { migrate } from '../src/db/migrate.js';
import { hostFailoverTick } from '../src/services/hostFailover.js';
import { clearSettingsCache, setSettings } from '../src/services/settings.js';

const M = (globalThis as any).__mocks;
const rw = () => M.rw.state;
let nodeA: string; let nodeB: string; let hostA: any; let hostB: any;

beforeAll(async () => {
  await sql()`drop schema public cascade`;
  await sql()`create schema public`;
  await migrate();
});
beforeEach(async () => {
  await sql()`truncate settings, host_failover`;
  clearSettingsCache();
  rw().fail = false;
  nodeA = randomUUID(); nodeB = randomUUID();
  rw().nodes = [
    { uuid: nodeA, id: 1, name: 'A', address: '1.1.1.1', port: 2222, countryCode: 'FI', isConnected: true, isDisabled: false },
    { uuid: nodeB, id: 2, name: 'B', address: '2.2.2.2', port: 2222, countryCode: 'NL', isConnected: true, isDisabled: false },
  ];
  hostA = { uuid: randomUUID(), remark: 'A', address: '1.1.1.1', isDisabled: false, nodes: [nodeA] };
  hostB = { uuid: randomUUID(), remark: 'B', address: '2.2.2.2', isDisabled: false, nodes: [nodeB] };
  rw().hosts = [hostA, hostB];
});
afterAll(async () => { await closeDb(); });

const down = (uuid: string, v = false) => { rw().nodes.find((n: any) => n.uuid === uuid).isConnected = v; };
const ticks = async (n: number) => { for (let i = 0; i < n; i++) await hostFailoverTick(); };

describe('автоотключение упавших серверов', () => {
  it('убирает сервер после трёх неудач подряд и возвращает после восстановления', async () => {
    down(nodeA);
    await ticks(2);
    expect(hostA.isDisabled).toBe(false);
    await ticks(1);
    expect(hostA.isDisabled).toBe(true);
    expect(hostB.isDisabled).toBe(false);
    down(nodeA, true);
    await ticks(1);
    expect(hostA.isDisabled).toBe(true);
    await ticks(1);
    expect(hostA.isDisabled).toBe(false);
  });
  it('кратковременный сбой не отключает сервер', async () => {
    down(nodeA); await ticks(2);
    down(nodeA, true); await ticks(1);
    down(nodeA); await ticks(2);
    expect(hostA.isDisabled).toBe(false);
  });
  it('выключенный вручную хост остаётся выключенным', async () => {
    hostA.isDisabled = true;
    await ticks(5);
    expect(hostA.isDisabled).toBe(true);
  });
  it('если упали все ноды, последний сервер остаётся в подписке', async () => {
    down(nodeA); down(nodeB);
    await ticks(5);
    expect([hostA.isDisabled, hostB.isDisabled]).toEqual([false, false]);
  });
  it('второй сервер не отключается вслед за первым, пока первый выключен', async () => {
    down(nodeA); await ticks(3);
    expect(hostA.isDisabled).toBe(true);
    down(nodeB); await ticks(5);
    expect(hostB.isDisabled).toBe(false);
  });
  it('выключенная настройка ничего не делает', async () => {
    await setSettings('monitoring', { host_failover: false });
    down(nodeA); await ticks(5);
    expect(hostA.isDisabled).toBe(false);
  });
  it('сбой панели не меняет состояние и не отключает серверы', async () => {
    down(nodeA); await ticks(2);
    rw().fail = true;
    await expect(hostFailoverTick()).rejects.toBeTruthy();
    rw().fail = false;
    expect(hostA.isDisabled).toBe(false);
  });
});
