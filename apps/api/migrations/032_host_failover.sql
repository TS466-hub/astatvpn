-- Автоотключение хостов упавших нод. Хосты, выключенные вручную, сюда не попадают и обратно не включаются.
create table host_failover (
  host_uuid     uuid primary key,
  fail_count    integer not null default 0,
  ok_count      integer not null default 0,
  auto_disabled boolean not null default false,
  updated_at    timestamptz not null default now()
);
