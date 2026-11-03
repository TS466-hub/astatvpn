-- Связка аккаунта сайта с Telegram: ссылка принадлежит аккаунту, который её запросил.
alter table auth_links add column link_user_id uuid references users(id) on delete set null;
