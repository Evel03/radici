-- =====================================================================
-- Envío del menú de cada semana y link de la clienta (migración 20261121100000_menu_sends.sql):
--   * chef_menu_send_context: lo necesario para armar el mensaje de una semana.
--   * chef_prepare_menu_send / chef_link_menu_send / chef_complete_menu_send: vista previa (envío
--     sin salir), link del mensaje (al enviar) y envío, con control de versión del menú.
--   * client_link_view / client_link_confirm_menu / client_link_request_changes: lo que ve y
--     contesta la clienta con su link (el hash del token).
--   * Privilegios: la cocina solo lee menu_sends; client_links y las funciones, solo service_role.
--
-- C1 tiene a la clienta A con el pedido R (de la web, en español, con contacto propio) y sus
-- sesiones S1 y S2 (confirmadas) y S3 (cancelada), y S4, una sesión suelta sin pedido. C2 es otra
-- cocinera con su pedido RX y su sesión SX.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(77);

-- ---------------------------------------------------------------------
-- Fixture (como postgres, sin RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('7e6a0000-0000-4000-8000-00000000c001', 'chef1@envios.test'),
  ('7e6a0000-0000-4000-8000-00000000c002', 'chef2@envios.test');
update public.profiles set role = 'chef'
where id in ('7e6a0000-0000-4000-8000-00000000c001', '7e6a0000-0000-4000-8000-00000000c002');

insert into public.chefs (id, profile_id, display_name) values
  ('7e6a1000-0000-4000-8000-000000000001', '7e6a0000-0000-4000-8000-00000000c001', 'Evelyn'),
  ('7e6a1000-0000-4000-8000-000000000002', '7e6a0000-0000-4000-8000-00000000c002', 'Chef Due');
insert into public.chef_settings (chef_id) values
  ('7e6a1000-0000-4000-8000-000000000001'),
  ('7e6a1000-0000-4000-8000-000000000002');

insert into public.clients (id, chef_id, display_name, contact_email, contact_phone, status) values
  ('7e6a2000-0000-4000-8000-00000000000a', '7e6a1000-0000-4000-8000-000000000001', 'Anna Rota', 'vieja@envios.test', '+393330000001', 'trial'),
  ('7e6a2000-0000-4000-8000-00000000000b', '7e6a1000-0000-4000-8000-000000000001', 'Bruno Sala', 'bruno@envios.test', '+393330000002', 'active'),
  ('7e6a2000-0000-4000-8000-00000000000f', '7e6a1000-0000-4000-8000-000000000002', 'Xenia Ferri', null, null, 'active');

insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, source, locale, contact) values
  ('7e6a3000-0000-4000-8000-00000000000a', '7e6a1000-0000-4000-8000-000000000001', '7e6a2000-0000-4000-8000-00000000000a',
   'week', 'accepted', 2, 1, 5, '{lunch,dinner}', 3, 'web', 'es',
   '{"name": "Anna Rota", "email": "anna@envios.test", "phone": "+393339999999", "zone": "Loreto"}'),
  ('7e6a3000-0000-4000-8000-00000000000f', '7e6a1000-0000-4000-8000-000000000002', '7e6a2000-0000-4000-8000-00000000000f',
   'week', 'accepted', 1, 0, 3, '{dinner}', 1, 'app', 'it', null);

insert into public.sessions (id, chef_id, client_id, request_id, "date", start_time, cook_minutes, status, cancelled_at) values
  ('7e6a4000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', '7e6a2000-0000-4000-8000-00000000000a',
   '7e6a3000-0000-4000-8000-00000000000a', '2027-03-01', '10:00', 180, 'confirmed', null),
  ('7e6a4000-0000-4000-8000-000000000002', '7e6a1000-0000-4000-8000-000000000001', '7e6a2000-0000-4000-8000-00000000000a',
   '7e6a3000-0000-4000-8000-00000000000a', '2027-03-15', '09:30', 180, 'confirmed', null),
  ('7e6a4000-0000-4000-8000-000000000003', '7e6a1000-0000-4000-8000-000000000001', '7e6a2000-0000-4000-8000-00000000000a',
   '7e6a3000-0000-4000-8000-00000000000a', '2027-03-08', '10:00', 180, 'cancelled', now()),
  ('7e6a4000-0000-4000-8000-000000000004', '7e6a1000-0000-4000-8000-000000000001', '7e6a2000-0000-4000-8000-00000000000b',
   null, '2027-03-02', '10:00', 180, 'confirmed', null),
  ('7e6a4000-0000-4000-8000-00000000000f', '7e6a1000-0000-4000-8000-000000000002', '7e6a2000-0000-4000-8000-00000000000f',
   '7e6a3000-0000-4000-8000-00000000000f', '2027-03-01', '10:00', 180, 'confirmed', null);

insert into public.recipes (id, chef_id, name_it, name_es, description_it, diet) values
  ('7e6a6000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', 'Lasagne', 'Lasaña', 'Al ragù', null),
  ('7e6a6000-0000-4000-8000-000000000002', '7e6a1000-0000-4000-8000-000000000001', 'Minestrone', null, null, 'vegan'),
  ('7e6a6000-0000-4000-8000-00000000000f', '7e6a1000-0000-4000-8000-000000000002', 'Ossobuco', null, null, null);
insert into public.recipe_allergens (recipe_id, chef_id, allergen) values
  ('7e6a6000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', 'milk'),
  ('7e6a6000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', 'gluten');

-- El menú de S1 (versión 1), de S4 y de SX; S2 todavía no tiene. Un menú sin platos para S2 se
-- prueba más abajo.
insert into public.session_menus (session_id, chef_id, note) values
  ('7e6a4000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', 'Tené listos 4 táperes'),
  ('7e6a4000-0000-4000-8000-000000000004', '7e6a1000-0000-4000-8000-000000000001', null),
  ('7e6a4000-0000-4000-8000-00000000000f', '7e6a1000-0000-4000-8000-000000000002', null);
insert into public.session_menu (session_id, recipe_id, chef_id, portions, position) values
  ('7e6a4000-0000-4000-8000-000000000001', '7e6a6000-0000-4000-8000-000000000002', '7e6a1000-0000-4000-8000-000000000001', 6, 1),
  ('7e6a4000-0000-4000-8000-000000000001', '7e6a6000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', 8, 2),
  ('7e6a4000-0000-4000-8000-00000000000f', '7e6a6000-0000-4000-8000-00000000000f', '7e6a1000-0000-4000-8000-000000000002', 2, 1);
insert into public.session_shopping_items (session_id, chef_id, position, name, section, quantity, unit) values
  ('7e6a4000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', 1, 'Zucchine', 'produce', 750, 'g'),
  ('7e6a4000-0000-4000-8000-000000000001', '7e6a1000-0000-4000-8000-000000000001', 2, 'Sale', 'pantry', null, null);

create function pg_temp.error_of(p_sql text) returns text
language plpgsql
as $$
declare
  v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return sqlstate || ': ' || sqlerrm || coalesce(' (' || nullif(v_detail, '') || ')', '');
end
$$;

-- El hash de un token de prueba, como lo calcula la función chef.
create function pg_temp.h(p_token text) returns text
language sql
immutable
as $$ select encode(sha256(convert_to(p_token, 'UTF8')), 'hex') $$;

-- Una vista previa de C1; el token de prueba va en la foto para encontrar el envío.
create function pg_temp.prepare(p_session text, p_version int, p_token text) returns uuid
language sql
as $$
  select (public.chef_prepare_menu_send('7e6a1000-0000-4000-8000-000000000001', p_session::uuid, p_version, 'it',
            jsonb_build_object('v', 1, 'token', p_token), false) ->> 'sendId')::uuid
$$;

-- El envío con ese token en la foto.
create function pg_temp.send_of(p_token text) returns uuid
language sql
stable
as $$ select ms.id from public.menu_sends ms where ms.snapshot ->> 'token' = p_token $$;

-- Enviar como la función chef: el link con el hash del token y después marcarlo enviado.
create function pg_temp.deliver(p_chef text, p_send uuid, p_token text, p_via text[]) returns timestamptz
language sql
as $$
  select public.chef_link_menu_send(p_chef::uuid, p_send, pg_temp.h(p_token));
  select (public.chef_complete_menu_send(p_chef::uuid, p_send, p_via) ->> 'sentAt')::timestamptz;
$$;

-- ---------------------------------------------------------------------
-- 1. Privilegios
-- ---------------------------------------------------------------------
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c
   where c.oid in ('public.menu_sends'::regclass, 'public.client_links'::regclass)),
  'RLS habilitado en menu_sends y client_links');
select ok(has_table_privilege('authenticated', 'public.menu_sends', 'SELECT')
          and not has_table_privilege('authenticated', 'public.menu_sends', 'INSERT,UPDATE,DELETE'),
  'authenticated solo lee menu_sends');
select ok(not has_table_privilege('authenticated', 'public.client_links', 'SELECT,INSERT,UPDATE,DELETE')
          and not has_table_privilege('anon', 'public.client_links', 'SELECT,INSERT,UPDATE,DELETE')
          and not has_table_privilege('anon', 'public.menu_sends', 'SELECT,INSERT,UPDATE,DELETE'),
  'client_links no la toca nadie fuera de la service role; anon tampoco menu_sends');
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('chef_menu_send_context', 'chef_prepare_menu_send', 'chef_link_menu_send', 'chef_complete_menu_send',
                       'client_link_view', 'client_link_confirm_menu', 'client_link_request_changes')
     and p.prosecdef
     and has_function_privilege('service_role', p.oid, 'EXECUTE')
     and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not has_function_privilege('public', p.oid, 'EXECUTE')),
  array['chef_complete_menu_send', 'chef_link_menu_send', 'chef_menu_send_context', 'chef_prepare_menu_send',
        'client_link_confirm_menu', 'client_link_request_changes', 'client_link_view'],
  'las siete funciones: security definer y solo service_role');

-- ---------------------------------------------------------------------
-- 2. chef_menu_send_context
-- ---------------------------------------------------------------------
set local role service_role;

select is(
  public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'session',
  '{"id": "7e6a4000-0000-4000-8000-000000000001", "date": "2027-03-01", "start": "10:00", "status": "confirmed",
    "requestId": "7e6a3000-0000-4000-8000-00000000000a", "week": 1, "weeks": 2}'::jsonb,
  'session: fecha, hora y «Semana 1 de 2» (la cancelada no cuenta)');
select is(
  public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'weeks',
  '[{"sessionId": "7e6a4000-0000-4000-8000-000000000001", "date": "2027-03-01", "start": "10:00"},
    {"sessionId": "7e6a4000-0000-4000-8000-000000000002", "date": "2027-03-15", "start": "09:30"}]'::jsonb,
  'weeks: las semanas vivas de la reserva, por fecha');
select is(
  public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'request',
  '{"id": "7e6a3000-0000-4000-8000-00000000000a", "type": "week", "locale": "es", "adults": 2, "kids": 1,
    "days": 5, "meals": ["lunch", "dinner"]}'::jsonb,
  'request: idioma y hogar');
select is(
  public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'contact',
  '{"name": "Anna Rota", "email": "anna@envios.test", "phone": "+393339999999"}'::jsonb,
  'contact: el del pedido de la web, no el viejo de la ficha');
select is(
  public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'menu',
  '{"version": 1, "note": "Tené listos 4 táperes", "allergensConfirmed": false,
    "dishes": [
      {"recipeId": "7e6a6000-0000-4000-8000-000000000002", "portions": 6, "nameIt": "Minestrone", "nameEs": null, "nameEn": null,
       "descriptionIt": null, "descriptionEs": null, "descriptionEn": null, "diet": "vegan", "photoId": null, "allergens": []},
      {"recipeId": "7e6a6000-0000-4000-8000-000000000001", "portions": 8, "nameIt": "Lasagne", "nameEs": "Lasaña", "nameEn": null,
       "descriptionIt": "Al ragù", "descriptionEs": null, "descriptionEn": null, "diet": null, "photoId": null,
       "allergens": ["gluten", "milk"]}],
    "items": [
      {"name": "Zucchine", "section": "produce", "quantity": 750, "unit": "g"},
      {"name": "Sale", "section": "pantry", "quantity": null, "unit": null}]}'::jsonb,
  'menu: platos en orden con nombres, descripciones, alérgenos y dieta; lista en orden; nota y versión');
select is(
  public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'lastSend',
  'null'::jsonb, 'lastSend: null mientras no salió nada');
select is(
  public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'chef',
  '{"displayName": "Evelyn"}'::jsonb, 'chef: el nombre de la cocinera');

select is(pg_temp.error_of($$ select public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-00000000000f') $$),
  'P0002: session_not_found', 'la sesión de otra cocina: session_not_found');
select is(pg_temp.error_of($$ select public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000002') $$),
  'P0002: menu_not_found', 'una semana sin menú: menu_not_found');
select is(pg_temp.error_of($$ select public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000004') $$),
  '55000: session_without_request', 'una sesión sin pedido: session_without_request');

-- ---------------------------------------------------------------------
-- 3. Vista previa, link y envío
-- ---------------------------------------------------------------------
select ok(pg_temp.prepare('7e6a4000-0000-4000-8000-000000000001', 1, 'token-a') is not null, 'la vista previa devuelve sendId');
select is(
  (select concat_ws(' ', ms.menu_version, ms.locale, ms.translated, ms.sent_at is null, ms.sent_via is null, ms.request_id)
   from public.menu_sends ms where ms.id = pg_temp.send_of('token-a')),
  '1 it f t t 7e6a3000-0000-4000-8000-00000000000a',
  'el envío queda sin salir, con la versión, el idioma y el pedido');
select is((select count(*)::int from public.client_links), 0, 'la vista previa no crea ningún link');

select is(
  array[
    pg_temp.error_of($$ select pg_temp.prepare('7e6a4000-0000-4000-8000-000000000001', 2, 'token-x1') $$),
    pg_temp.error_of($$ select public.chef_prepare_menu_send('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001', 1, 'fr', '{}', false) $$),
    pg_temp.error_of($$ select public.chef_prepare_menu_send('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001', 1, 'it', '[]', false) $$),
    pg_temp.error_of($$ select pg_temp.prepare('7e6a4000-0000-4000-8000-000000000003', 1, 'token-x2') $$),
    pg_temp.error_of($$ select pg_temp.prepare('7e6a4000-0000-4000-8000-000000000002', 1, 'token-x3') $$),
    pg_temp.error_of($$ select pg_temp.prepare('7e6a4000-0000-4000-8000-000000000004', 1, 'token-x4') $$),
    pg_temp.error_of($$ select pg_temp.prepare('7e6a4000-0000-4000-8000-00000000000f', 1, 'token-x5') $$)
  ]::text[],
  array['40001: menu_changed', '22023: invalid_locale', '22023: invalid_snapshot',
        '55000: session_not_editable (cancelled)', 'P0002: menu_not_found', '55000: session_without_request',
        'P0002: session_not_found'],
  'vista previa: versión vieja, idioma, foto, sesión cancelada, sin menú, sin pedido y de otra cocina');

-- Un menú sin platos no se manda.
reset role;
insert into public.session_menus (session_id, chef_id) values ('7e6a4000-0000-4000-8000-000000000002', '7e6a1000-0000-4000-8000-000000000001');
set local role service_role;
select is(pg_temp.error_of($$ select pg_temp.prepare('7e6a4000-0000-4000-8000-000000000002', 1, 'token-x6') $$),
  '22023: menu_empty', 'un menú sin platos: menu_empty');

-- Al enviar: el link y lo necesario para armar el mensaje.
select is(
  public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-a'), pg_temp.h('token-a')) - 'sendId',
  '{"sessionId": "7e6a4000-0000-4000-8000-000000000001", "requestId": "7e6a3000-0000-4000-8000-00000000000a",
    "locale": "it", "snapshot": {"v": 1, "token": "token-a"},
    "contact": {"name": "Anna Rota", "email": "anna@envios.test", "phone": "+393339999999"}, "chefName": "Evelyn"}'::jsonb,
  'al enviar: la foto, el idioma, el contacto de ahora y la cocinera');
select is(
  (select concat_ws(' ', l.request_id, l.chef_id, l.expires_at = l.created_at + interval '120 days')
   from public.client_links l where l.token_hash = pg_temp.h('token-a')),
  '7e6a3000-0000-4000-8000-00000000000a 7e6a1000-0000-4000-8000-000000000001 t',
  'y el link (el hash), del pedido, por 120 días');
select is((select count(*)::int from public.client_links where token_hash = 'token-a'), 0, 'el token no se guarda, solo el hash');
select is(
  array[
    pg_temp.error_of($$ select public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-a'), 'token-a') $$),
    pg_temp.error_of($$ select public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000002', pg_temp.send_of('token-a'), pg_temp.h('otro')) $$),
    (pg_temp.error_of($$ select public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-a'), pg_temp.h('token-a')) $$) like '23505:%')::text
  ]::text[],
  array['22023: invalid_token', 'P0002: send_not_found', 'true'],
  'link: sin hashear, de otra cocina o un token repetido');

select is(
  public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-a'), array['whatsapp', 'email']) -> 'sentVia',
  '["email", "whatsapp"]'::jsonb, 'el envío sale por los dos canales (en orden)');
select is((select sent_at from public.menu_sends where id = pg_temp.send_of('token-a')), now(), 'sent_at es ahora');
select is(
  public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-a'), array['email']) -> 'sentVia',
  '["email", "whatsapp"]'::jsonb, 'un reintento no cambia nada');
select is(pg_temp.error_of($$ select public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-a'), pg_temp.h('token-a2')) $$),
  '55000: already_sent', 'un envío que salió no se vuelve a mandar');

-- Dentro de la transacción del test now() no cambia: el envío a sale una hora antes, así los que
-- salen después son más nuevos.
reset role;
update public.menu_sends set sent_at = now() - interval '1 hour' where id = pg_temp.send_of('token-a');
set local role service_role;

-- Vistas previas que no salen: b, c, d y e. b y c llegan a tener link (como un email que falló).
select ok(pg_temp.prepare('7e6a4000-0000-4000-8000-000000000001', 1, 'token-' || t) is not null,
  format('vista previa %s (no sale)', t))
from unnest(array['b', 'c', 'd', 'e']) as t;
select ok(public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-' || t), pg_temp.h('token-' || t)) is not null,
  format('link %s', t))
from unnest(array['b', 'c']) as t;
select is(
  array[
    pg_temp.error_of($$ select public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000002', pg_temp.send_of('token-a'), array['email']) $$),
    pg_temp.error_of($$ select public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-b'), array['sms']) $$),
    pg_temp.error_of($$ select public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-c'), array[]::text[]) $$),
    pg_temp.error_of($$ select public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-d'), array['email', 'email']) $$),
    pg_temp.error_of($$ select public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-e'), null) $$)
  ]::text[],
  array['P0002: send_not_found', '22023: invalid_via', '22023: invalid_via', '22023: invalid_via', '22023: invalid_via'],
  'enviar: de otra cocina, o canales inválidos');

-- Una vista previa que queda vieja porque Evelyn guardó otra versión del menú.
select ok(pg_temp.prepare('7e6a4000-0000-4000-8000-000000000001', 1, 'token-f') is not null, 'vista previa f');
select ok(public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-f'), pg_temp.h('token-f')) is not null, 'link f');
reset role;
update public.session_menus set version = 2 where session_id = '7e6a4000-0000-4000-8000-000000000001';
set local role service_role;
select is(
  array[
    pg_temp.error_of($$ select public.chef_complete_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-f'), array['whatsapp']) $$),
    pg_temp.error_of($$ select public.chef_link_menu_send('7e6a1000-0000-4000-8000-000000000001', pg_temp.send_of('token-d'), pg_temp.h('token-d')) $$)
  ]::text[],
  array['40001: menu_changed', '40001: menu_changed'],
  'enviar o crear el link de una vista previa de una versión vieja: menu_changed');
select is((select sent_at from public.menu_sends where id = pg_temp.send_of('token-f')), null, 'y no sale');

select is(
  (public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') -> 'lastSend') - 'id' - 'sentAt',
  '{"menuVersion": 1, "sentVia": ["email", "whatsapp"], "confirmedAt": null, "changesRequestedAt": null}'::jsonb,
  'lastSend: el envío que salió (las vistas previas no cuentan)');

-- ---------------------------------------------------------------------
-- 4. client_link_view
-- ---------------------------------------------------------------------
select is(public.client_link_view('token-a'), null, 'un token sin hashear no abre nada');
select is(public.client_link_view(pg_temp.h('no-existe')), null, 'un hash que no existe tampoco');
select is(public.client_link_view(null), null, 'null tampoco');
select is(public.client_link_view(pg_temp.h('token-a')) - 'weeks' - 'quote',
  '{"requestId": "7e6a3000-0000-4000-8000-00000000000a", "locale": "es", "chefName": "Evelyn", "clientName": "Anna Rota"}'::jsonb,
  'el link abre la reserva: idioma, cocinera y nombre de la ficha');
select is(
  (select jsonb_agg(w - 'send') from jsonb_array_elements(public.client_link_view(pg_temp.h('token-a')) -> 'weeks') as w),
  '[{"sessionId": "7e6a4000-0000-4000-8000-000000000001", "date": "2027-03-01", "start": "10:00", "status": "confirmed", "week": 1, "weeks": 2},
    {"sessionId": "7e6a4000-0000-4000-8000-000000000002", "date": "2027-03-15", "start": "09:30", "status": "confirmed", "week": 2, "weeks": 2}]'::jsonb,
  'las semanas vivas, por fecha');
select is(
  (public.client_link_view(pg_temp.h('token-a')) #> '{weeks,0,send}') - 'id' - 'sentAt' - 'quoteId',
  '{"snapshot": {"v": 1, "token": "token-a"}, "confirmedAt": null, "changesRequestedAt": null}'::jsonb,
  'la semana 1 muestra la foto del envío que salió, no las vistas previas');
select is(public.client_link_view(pg_temp.h('token-a')) #> '{weeks,1,send}', 'null'::jsonb, 'la semana 2 todavía no tiene envío');
select ok(public.client_link_view(pg_temp.h('token-f')) is not null, 'el link de un envío que no llegó a salir abre la reserva igual');
select ok(public.client_link_view(pg_temp.h('token-a'))::text !~ 'anna@|\+39|Loreto|vieja@',
  'la vista no trae contacto ni zona');

reset role;
update public.client_links set expires_at = now() - interval '1 second', created_at = now() - interval '121 days'
where token_hash = pg_temp.h('token-b');
set local role service_role;
select is(public.client_link_view(pg_temp.h('token-b')), null, 'un link vencido no abre nada');

-- ---------------------------------------------------------------------
-- 5. La clienta contesta
-- ---------------------------------------------------------------------
select is(
  public.client_link_confirm_menu(pg_temp.h('token-c'), pg_temp.send_of('token-a'))
    - 'sendId' - 'confirmedAt',
  '{"sessionId": "7e6a4000-0000-4000-8000-000000000001", "requestId": "7e6a3000-0000-4000-8000-00000000000a",
    "chefId": "7e6a1000-0000-4000-8000-000000000001", "already": false, "changesRequestedAt": null,
    "date": "2027-03-01", "start": "10:00", "week": 1, "weeks": 2, "clientName": "Anna Rota", "locale": "it"}'::jsonb,
  'la clienta confirma con cualquier link de la reserva; vuelve lo necesario para avisarle a Evelyn');
select is((select client_confirmed_at from public.menu_sends where id = pg_temp.send_of('token-a')), now(), 'queda confirmado');
select is(
  public.client_link_confirm_menu(pg_temp.h('token-a'), pg_temp.send_of('token-a')) -> 'already',
  'true'::jsonb, 'confirmar de nuevo no hace nada (already)');
select is(pg_temp.error_of($$ select public.client_link_request_changes(pg_temp.h('token-a'),
    pg_temp.send_of('token-a'), 'Sin cebolla') $$),
  '55000: already_confirmed', 'después de confirmar no se piden cambios por el link');

select is(
  array[
    pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('token-b'), pg_temp.send_of('token-a')) $$),
    pg_temp.error_of($$ select public.client_link_confirm_menu('token-a', pg_temp.send_of('token-a')) $$),
    pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('token-a'), pg_temp.send_of('token-f')) $$),
    pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('token-a'), '7e6a9000-0000-4000-8000-000000000000') $$)
  ]::text[],
  array['P0002: link_not_found', 'P0002: link_not_found', 'P0002: send_not_found', 'P0002: send_not_found'],
  'link vencido o sin hashear, un envío que no salió y uno que no existe');

-- El envío de C2, con su propio link: el link de C1 no lo contesta.
select ok(pg_temp.deliver('7e6a1000-0000-4000-8000-000000000002',
  (public.chef_prepare_menu_send('7e6a1000-0000-4000-8000-000000000002', '7e6a4000-0000-4000-8000-00000000000f', 1, 'it',
     '{"v": 1, "token": "token-x"}', false) ->> 'sendId')::uuid, 'token-x', array['whatsapp']) is not null,
  'C2 manda el menú de SX');
select is(pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('token-a'),
    pg_temp.send_of('token-x')) $$),
  'P0002: send_not_found', 'el link de una reserva no contesta el envío de otra');
select is((public.client_link_view(pg_temp.h('token-x')) -> 'weeks') -> 0 ->> 'sessionId',
  '7e6a4000-0000-4000-8000-00000000000f', 'y cada link abre solo su reserva');

-- Evelyn manda otra versión de la semana 1: el envío viejo ya no se contesta.
select ok(pg_temp.deliver('7e6a1000-0000-4000-8000-000000000001',
  pg_temp.prepare('7e6a4000-0000-4000-8000-000000000001', 2, 'token-g'), 'token-g', array['email']) is not null,
  'Evelyn manda la versión 2 de la semana 1');
select is(pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('token-a'),
    pg_temp.send_of('token-a')) $$),
  '55000: menu_outdated', 'el envío viejo, con uno más nuevo: menu_outdated');
select is((public.client_link_view(pg_temp.h('token-a')) #> '{weeks,0,send,snapshot,token}'), '"token-g"'::jsonb,
  'la página muestra el envío nuevo, sin confirmar');

select is(
  array[
    pg_temp.error_of($$ select public.client_link_request_changes(pg_temp.h('token-a'), pg_temp.send_of('token-g'), '') $$),
    pg_temp.error_of($$ select public.client_link_request_changes(pg_temp.h('token-a'), pg_temp.send_of('token-g'), '   ') $$),
    pg_temp.error_of($$ select public.client_link_request_changes(pg_temp.h('token-a'), pg_temp.send_of('token-g'), repeat('x', 1001)) $$),
    pg_temp.error_of($$ select public.client_link_request_changes(pg_temp.h('token-a'), pg_temp.send_of('token-g'), E'hola\tchau') $$),
    pg_temp.error_of($$ select public.client_link_request_changes(pg_temp.h('token-a'), pg_temp.send_of('token-g'), null) $$)
  ]::text[],
  array['22023: invalid_text', '22023: invalid_text', '22023: invalid_text', '22023: invalid_text', '22023: invalid_text'],
  'el mensaje de cambios: vacío, solo espacios, largo, con control o null');
select is(
  public.client_link_request_changes(pg_temp.h('token-a'), pg_temp.send_of('token-g'),
    E'  Sin cebolla,\r\npor favor  ') -> 'already',
  'false'::jsonb, 'la clienta pide cambios');
select is((select changes_text from public.menu_sends where id = pg_temp.send_of('token-g')), E'Sin cebolla,\npor favor',
  'el mensaje queda recortado y con \n');
select is(pg_temp.error_of($$ select public.client_link_confirm_menu(pg_temp.h('token-a'),
    pg_temp.send_of('token-g')) $$),
  '55000: changes_requested', 'después de pedir cambios no confirma ese envío');
select ok(
  (public.client_link_request_changes(pg_temp.h('token-a'), pg_temp.send_of('token-g'),
     'Mejor sin ajo') ->> 'changesRequestedAt') is not null,
  'un mensaje nuevo reemplaza al anterior');
select is((select changes_text from public.menu_sends where id = pg_temp.send_of('token-g')), 'Mejor sin ajo', 'queda el último');
select is(
  (public.client_link_view(pg_temp.h('token-a')) #> '{weeks,0,send}') ? 'changesRequestedAt'
  and (public.client_link_view(pg_temp.h('token-a')) #>> '{weeks,0,send,changesRequestedAt}') is not null,
  true, 'la página sabe que pidió cambios');
select ok(public.client_link_view(pg_temp.h('token-a'))::text !~ 'Mejor sin ajo',
  'la página no vuelve a mostrar el mensaje (es para Evelyn)');

-- ---------------------------------------------------------------------
-- 6. Lo que ve la cocina por la API
-- ---------------------------------------------------------------------
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"7e6a0000-0000-4000-8000-00000000c001","role":"authenticated"}';
select is((select count(*)::int from public.menu_sends where sent_at is not null), 2, 'C1 lee sus envíos que salieron');
select is((select count(*)::int from public.menu_sends where chef_id = '7e6a1000-0000-4000-8000-000000000002'), 0, 'no los de C2');
select is((select changes_text from public.menu_sends where id = pg_temp.send_of('token-g')), 'Mejor sin ajo', 'C1 lee el pedido de cambios');
select is(pg_temp.error_of($$ update public.menu_sends set client_confirmed_at = now() $$),
  '42501: permission denied for table menu_sends', 'la cocina no marca confirmaciones');
select is(pg_temp.error_of($$ select count(*) from public.client_links $$),
  '42501: permission denied for table client_links', 'la cocina no lee los links');
select is(pg_temp.error_of($$ select public.client_link_view(repeat('a', 64)) $$),
  '42501: permission denied for function client_link_view', 'ni ejecuta las funciones del link');
select is(pg_temp.error_of($$ select public.chef_menu_send_context('7e6a1000-0000-4000-8000-000000000001', '7e6a4000-0000-4000-8000-000000000001') $$),
  '42501: permission denied for function chef_menu_send_context', 'ni las de la función chef');

reset role;
set local role anon;
select is(pg_temp.error_of($$ select public.client_link_view(repeat('a', 64)) $$),
  '42501: permission denied for function client_link_view', 'anon no ejecuta client_link_view (va por la función client-link)');
reset role;

-- ---------------------------------------------------------------------
-- 7. Al borrar el pedido se van sus envíos y sus links
-- ---------------------------------------------------------------------
delete from public.sessions where request_id = '7e6a3000-0000-4000-8000-00000000000a';
delete from public.requests where id = '7e6a3000-0000-4000-8000-00000000000a';
select is((select count(*)::int from public.menu_sends where request_id = '7e6a3000-0000-4000-8000-00000000000a')
        + (select count(*)::int from public.client_links where request_id = '7e6a3000-0000-4000-8000-00000000000a'),
  0, 'borrar el pedido borra sus envíos y sus links');

select * from finish();
rollback;
