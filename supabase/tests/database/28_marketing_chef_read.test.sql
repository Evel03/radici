-- =====================================================================
-- La lista de ofertas para la cocina (migración 20261127110000_marketing_contacts_chef_read.sql):
-- la cocinera y sus colaboradores leen los contactos de su cocina, sin el hash del token; nadie
-- más lee nada y nadie escribe desde la API.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(17);

insert into auth.users (id, email) values
  ('a0280000-0000-4000-8000-000000000001', 'cocinera@lista.test'),
  ('a0280000-0000-4000-8000-000000000002', 'colaborador@lista.test'),
  ('a0280000-0000-4000-8000-000000000003', 'otra@lista.test'),
  ('a0280000-0000-4000-8000-000000000004', 'clienta@lista.test');
insert into public.chefs (id, profile_id, display_name) values
  ('cef28000-0000-4000-8000-000000000001', 'a0280000-0000-4000-8000-000000000001', 'Cocina de la lista'),
  ('cef28000-0000-4000-8000-000000000002', 'a0280000-0000-4000-8000-000000000003', 'Otra cocina');
insert into public.chef_members (chef_id, profile_id) values
  ('cef28000-0000-4000-8000-000000000001', 'a0280000-0000-4000-8000-000000000002');

create function pg_temp.sub(p_chef uuid, p_email text, p_token text) returns jsonb language sql as $$
  select public.marketing_subscribe(jsonb_build_object(
    'chef_id', p_chef, 'email', p_email, 'first_name', 'Giulia', 'locale', 'it', 'source', 'web',
    'text_version', '2026-11-27', 'token_hash', encode(extensions.digest(p_token, 'sha256'), 'hex')));
$$;
select pg_temp.sub('cef28000-0000-4000-8000-000000000001', 'una@example.it', 'a');
select pg_temp.sub('cef28000-0000-4000-8000-000000000001', 'dos@example.it', 'b');
select public.marketing_set(encode(extensions.digest('a', 'sha256'), 'hex'), 'confirm');
select pg_temp.sub('cef28000-0000-4000-8000-000000000002', 'ajena@example.it', 'c');

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- La cocinera: los de su cocina, con su estado.
select pg_temp.as_user('a0280000-0000-4000-8000-000000000001');
set local role authenticated;
select is(
  (select array_agg(email || ':' || status order by email) from public.marketing_contacts),
  array['dos@example.it:pending', 'una@example.it:confirmed'],
  'la cocinera lee los contactos de su cocina (no los de otra)'
);
select is((select first_name from public.marketing_contacts where email = 'una@example.it'), 'Giulia', 'con el nombre de pila');
select throws_ok($$select token_hash from public.marketing_contacts$$, '42501', null, 'nunca el hash del token');
select throws_ok($$select request_id from public.marketing_contacts$$, '42501', null, 'ni el pedido de origen');
select throws_ok($$update public.marketing_contacts set status = 'confirmed'$$, '42501', null, 'no cambia nada');
select throws_ok($$delete from public.marketing_contacts$$, '42501', null, 'no borra nada');
select throws_ok(
  $$insert into public.marketing_contacts (chef_id, email, locale, source, text_version, token_hash)
    values ('cef28000-0000-4000-8000-000000000001', 'x@y.it', 'it', 'web', 'v', repeat('a', 64))$$,
  '42501', null, 'ni agrega contactos'
);
reset role;

-- La cocinera da de baja un contacto que se lo pidió: queda de baja y sin el nombre; uno de otra cocina, no.
select pg_temp.as_user('a0280000-0000-4000-8000-000000000001');
set local role authenticated;
select is(public.chef_marketing_withdraw(' Una@Example.it '), true, 'la cocina da de baja un contacto suyo');
select is(public.chef_marketing_withdraw('una@example.it'), false, 'otra vez: ya estaba de baja');
select is(public.chef_marketing_withdraw('ajena@example.it'), false, 'uno de otra cocina, no');
reset role;
select is((select status || ':' || coalesce(first_name, '-') from public.marketing_contacts where email = 'una@example.it'), 'withdrawn:-', 'de baja y sin el nombre');
select pg_temp.as_user('a0280000-0000-4000-8000-000000000004');
set local role authenticated;
select throws_ok($$select public.chef_marketing_withdraw('dos@example.it')$$, '42501', null, 'una cuenta sin cocina no da de baja a nadie');
reset role;

-- El colaborador: lo mismo que la cocinera.
select pg_temp.as_user('a0280000-0000-4000-8000-000000000002');
set local role authenticated;
select is((select count(*)::int from public.marketing_contacts where status <> 'withdrawn'), 1, 'el colaborador ve los de la cocina de Evelyn (la de baja también, con su estado)');
reset role;

-- La otra cocina: solo los suyos.
select pg_temp.as_user('a0280000-0000-4000-8000-000000000003');
set local role authenticated;
select is((select array_agg(email) from public.marketing_contacts), array['ajena@example.it'], 'otra cocina, solo los suyos');
reset role;

-- Una cuenta sin cocina: nada.
select pg_temp.as_user('a0280000-0000-4000-8000-000000000004');
set local role authenticated;
select is((select count(*)::int from public.marketing_contacts), 0, 'una cuenta sin cocina no ve ninguno');
reset role;

-- anon: ni la tabla.
set local role anon;
select throws_ok($$select email from public.marketing_contacts$$, '42501', null, 'anon no la lee');
reset role;

select ok(
  exists (select 1 from pg_policies where tablename = 'marketing_contacts' and cmd = 'SELECT' and roles = '{authenticated}'),
  'una sola política: lectura para authenticated'
);

select * from finish();
rollback;
