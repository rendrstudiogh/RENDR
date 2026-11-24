-- Expire unpaid reservations (15 days) and send waiting list notices every 5 minutes
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('roomright-release-expired', '*/5 * * * *', $$select public.release_expired()$$);
