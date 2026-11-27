-- =====================================================================
-- PR19 (docs/contracts/auth.md §16): las reglas del hook de envío de emails de Auth.
--
-- Cuando el Send Email Hook esté prendido (PR20), GoTrue no manda los emails de Auth: le pasa cada uno a
-- la Edge Function auth-email, que verifica la firma y le pregunta a public.auth_email_gate si sale. Esta
-- migración trae esa decisión y su registro; la función no la usa nadie hasta PR20.
--
-- public.auth_email_gate(p_user_id, p_kind, p_recipient_hash) → 'send' | 'skip' | 'reject' | 'limited':
--   * reject: email_change, invite y reauthentication (y cualquier tipo desconocido). Radici no los usa, y
--     cortar el cambio de email ANTES de mandar nada es lo que cierra el secuestro por cambio de email
--     (auth.md §4): con el hook prendido, PUT /user {email} falla y no queda ningún cambio pendiente.
--   * skip (la función contesta 200 sin mandar nada, así no delata qué emails son de la cocina):
--       - magic_link (el código) a una cuenta que no es de la cocina: las clientas entran con contraseña;
--       - recovery y confirmation a una cuenta de la cocina: entra solo con el código, y un link de
--         recuperación le abriría una sesión (amr otp) igual que el código.
--   * limited: pasó un tope (la función contesta 429). Topes en las últimas horas, por carril:
--       - la cocina (la cocinera y sus colaboradores): 10 por hora por destinatario. Va aparte: nunca la
--         frena lo que manden las clientas;
--       - las demás cuentas: 3 por hora y 10 por día por destinatario, 3 por hora por cuenta, y 60 por día
--         entre todas (el plan gratis de Resend son 100 por día, compartidos con los emails de los pedidos).
--     GoTrue además manda uno por minuto como mucho a cada dirección (smtp_max_frequency, auth.md §9).
--   * send: queda anotado en private.auth_email_log y la función lo manda.
--
-- El registro guarda solo el tipo, el carril, la cuenta y el destinatario como hash (HMAC con IP_HASH_SALT,
-- lo calcula la función: el email nunca llega a la base), y se borra a los 2 días (pg_cron, 03:50 UTC).
-- Solo service_role ejecuta la función (la Edge Function con la clave secreta); nadie lee la tabla por la
-- API. Tests: pgTAP 30_auth_email_log.
-- =====================================================================
create table private.auth_email_log (
  id             bigint generated always as identity primary key,
  sent_at        timestamptz not null default now(),
  kind           text not null check (kind in ('magic_link', 'confirmation', 'recovery')),
  kitchen        boolean not null,
  user_id        uuid not null,
  recipient_hash text not null check (recipient_hash ~ '^[0-9a-f]{64}$')
);
comment on table private.auth_email_log is
  'Emails de Auth que el hook de envío dejó salir (auth.md §16): tipo, carril, cuenta y hash del destinatario, nunca el email. Se borran a los 2 días.';

create index auth_email_log_recipient on private.auth_email_log (recipient_hash, sent_at);
create index auth_email_log_user on private.auth_email_log (user_id, sent_at);
create index auth_email_log_lane on private.auth_email_log (kitchen, sent_at);

revoke all on table private.auth_email_log from public, anon, authenticated, service_role;

create function public.auth_email_gate(p_user_id uuid, p_kind text, p_recipient_hash text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_kitchen boolean;
  v_hour    timestamptz := now() - interval '1 hour';
  v_day     timestamptz := now() - interval '24 hours';
begin
  if p_user_id is null or p_recipient_hash is null or p_recipient_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_auth_email' using errcode = '22023';
  end if;

  -- Radici no cambia emails, no invita y no pide reautenticación; un tipo desconocido, tampoco sale.
  if p_kind is null or p_kind not in ('magic_link', 'confirmation', 'recovery') then
    return 'reject';
  end if;

  v_kitchen := exists (select 1 from public.chefs c where c.profile_id = p_user_id)
            or exists (select 1 from public.chef_members m where m.profile_id = p_user_id);

  if (p_kind = 'magic_link') <> v_kitchen then
    return 'skip';
  end if;

  -- Dos pedidos al mismo destinatario, de a uno (si no, los dos verían el tope sin el otro).
  perform pg_advisory_xact_lock(hashtextextended('auth_email:' || p_recipient_hash, 0));

  if v_kitchen then
    if (select count(*) from private.auth_email_log l
        where l.recipient_hash = p_recipient_hash and l.sent_at > v_hour) >= 10 then
      return 'limited';
    end if;
  else
    if (select count(*) from private.auth_email_log l
        where l.recipient_hash = p_recipient_hash and l.sent_at > v_hour) >= 3
       or (select count(*) from private.auth_email_log l
           where l.recipient_hash = p_recipient_hash and l.sent_at > v_day) >= 10
       or (select count(*) from private.auth_email_log l
           where l.user_id = p_user_id and l.sent_at > v_hour) >= 3
       or (select count(*) from private.auth_email_log l
           where not l.kitchen and l.sent_at > v_day) >= 60 then
      return 'limited';
    end if;
  end if;

  insert into private.auth_email_log (kind, kitchen, user_id, recipient_hash)
  values (p_kind, v_kitchen, p_user_id, p_recipient_hash);
  return 'send';
end
$$;
comment on function public.auth_email_gate(uuid, text, text) is
  'Hook de envío de Auth (auth.md §16): si un email de Auth sale (send), no sale sin avisar (skip), se rechaza (reject: cambio de email, invitación, reautenticación) o pasó un tope (limited). Solo service_role.';
revoke all on function public.auth_email_gate(uuid, text, text) from public, anon, authenticated;
grant execute on function public.auth_email_gate(uuid, text, text) to service_role;

-- Retención: 2 días (los topes miran 24 horas).
create function private.purge_auth_email_log()
returns integer
language sql
security definer
set search_path = ''
as $$
  with gone as (
    delete from private.auth_email_log where sent_at < now() - interval '2 days' returning 1
  )
  select count(*)::integer from gone;
$$;
revoke all on function private.purge_auth_email_log() from public, anon, authenticated, service_role;

-- 03:50 UTC, después de la de los contactos de ofertas (03:45).
select cron.schedule(
  'radici-purge-auth-email-log',
  '50 3 * * *',
  'select private.purge_auth_email_log()'
);
