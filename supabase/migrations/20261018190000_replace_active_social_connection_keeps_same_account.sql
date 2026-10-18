-- A reconnect of the account a workspace already holds is an upsert on
-- (user_id, provider, provider_user_id). The replace-previous-account trigger
-- ran BEFORE INSERT with a fresh new.id, so it revoked that very row, and the
-- ON CONFLICT update then failed with "cannot affect row a second time". Leave
-- the same provider account alone; only other accounts are replaced.
create or replace function private.replace_active_social_connection()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'active' then
    update public.social_connections
    set status = 'revoked',
        connection_health = 'action_required',
        reauth_required = true,
        last_error = 'Replaced by a new provider account.',
        updated_at = now()
    where user_id = new.user_id
      and provider = new.provider
      and provider_user_id <> new.provider_user_id
      and id <> new.id
      and status = 'active';
  end if;
  return new;
end
$$;
