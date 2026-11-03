-- Вход на сайт по номеру телефона и паролю: номер подтверждается звонком uCaller.
alter table users add column phone text unique;
alter table users add column password_hash text;
alter table users add column password_changed_at timestamptz;
alter table users add column login_failed integer not null default 0;
alter table users add column login_locked_until timestamptz;

create table phone_verifications (
  id          uuid primary key default gen_random_uuid(),
  phone       text not null,
  purpose     text not null check (purpose in ('register','reset')),
  code_hash   text,
  ucaller_id  bigint,
  ip          text not null,
  attempts    integer not null default 0,
  expires_at  timestamptz not null,
  consumed_at timestamptz,
  created_at  timestamptz not null default now()
);
create index phone_verifications_phone_idx on phone_verifications (phone, created_at);
create index phone_verifications_ip_idx on phone_verifications (ip, created_at);
create index phone_verifications_created_idx on phone_verifications (created_at);
