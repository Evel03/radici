-- =====================================================================
-- Los datos de la cuenta de una clienta (migración 20261127140000_account_details.sql, auth.md §18).
--
--   1. Privilegios: nadie escribe la tabla por la API; la función, solo authenticated.
--   2. save_account_details: guarda, corrige, copia nombre y teléfono al perfil; valida cada campo (18 años o más).
--   3. Quién lee: la cuenta, la suya; la cocina, todas; otra clienta y anon, nada.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(35);

-- La cocinera C, su colaborador M y dos clientas A y B.
insert into auth.users (id, email, email_confirmed_at) values
  ('31a00000-0000-4000-8000-0000000000c1', 'cocina@cuenta.test', now()),
  ('31a00000-0000-4000-8000-0000000000a1', 'socio@cuenta.test',  now()),
  ('31a00000-0000-4000-8000-00000000000a', 'a@cuenta.test',      now()),
  ('31a00000-0000-4000-8000-00000000000b', 'b@cuenta.test',      now());
update public.profiles set role = 'chef'
where id in ('31a00000-0000-4000-8000-0000000000c1', '31a00000-0000-4000-8000-0000000000a1');
insert into public.chefs (id, profile_id, display_name, whatsapp) values
  ('31a10000-0000-4000-8000-000000000001', '31a00000-0000-4000-8000-0000000000c1', 'Chef Cuenta', '+393330000031');
insert into public.chef_members (chef_id, profile_id) values
  ('31a10000-0000-4000-8000-000000000001', '31a00000-0000-4000-8000-0000000000a1');

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

/** Un pedido válido de A, con [extra] encima. */
create function pg_temp.body(extra jsonb default '{}') returns jsonb language sql as $$
  select '{"first_name": " Anna ", "last_name": "Rota", "phone": "+393401234567", "birth_date": "1990-05-17",
           "address_street": "Via Pignolo 12", "address_city": "Bergamo", "address_postal_code": "24121",
           "address_notes": "Citofono Rota", "favorite_season": "autumn", "heard_from": "instagram",
           "interests": ["weekly", "dinners", "weekly"], "preferred_days": [3, 1], "household_size": "3-4",
           "privacy_version": "2026-11-27"}'::jsonb || extra
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.body(jsonb) to authenticated;

-- =====================================================================
-- 1. Privilegios
-- =====================================================================
select has_table('public'::name, 'account_details'::name, 'existe public.account_details');
select is(
  (select array_agg(format('%s %s', r, p) order by 1)
   from unnest(array['anon', 'authenticated']) as r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) as p
   where has_table_privilege(r, 'public.account_details', p)),
  array['authenticated SELECT'],
  'authenticated solo lee (con RLS); nadie escribe por la API ni anon toca nada'
);
select ok((select relrowsecurity from pg_class where oid = 'public.account_details'::regclass), 'con RLS');
select ok(has_function_privilege('authenticated', 'public.save_account_details(jsonb)', 'EXECUTE'), 'authenticated ejecuta save_account_details');
select ok(not has_function_privilege('anon', 'public.save_account_details(jsonb)', 'EXECUTE'), 'anon no');
select is(
  (select array_agg(conname::text order by 1) from pg_constraint
   where conrelid = 'public.account_details'::regclass and contype = 'f'),
  array['account_details_profile_id_fkey'],
  'una sola referencia: el perfil'
);
select is(
  (select confdeltype::text from pg_constraint where conname = 'account_details_profile_id_fkey'),
  'c', 'sin perfil (cuenta borrada) no quedan sus datos');

-- =====================================================================
-- 2. save_account_details
-- =====================================================================
set local role authenticated;
select pg_temp.as_user('31a00000-0000-4000-8000-00000000000a');
select is(public.save_account_details(pg_temp.body()), '{"ok": true}'::jsonb, 'A guarda sus datos');
reset role;

select results_eq(
  $$ select first_name, last_name, phone, birth_date::text, address_city, address_postal_code, favorite_season,
            heard_from, interests, preferred_days, household_size, privacy_version
     from public.account_details where profile_id = '31a00000-0000-4000-8000-00000000000a' $$,
  $$ values ('Anna', 'Rota', '+393401234567', '1990-05-17', 'Bergamo', '24121', 'autumn',
             'instagram', array['dinners', 'weekly'], array[1, 3]::smallint[], '3-4', '2026-11-27') $$,
  'sin espacios de más, las listas sin repetidos y ordenadas');
select is(
  (select full_name || ' / ' || phone from public.profiles where id = '31a00000-0000-4000-8000-00000000000a'),
  'Anna Rota / +393401234567',
  'el nombre completo y el teléfono pasan al perfil');

-- Corrige: la dirección se puede sacar; la aceptación de la privacy no cambia con la misma versión.
update public.account_details set privacy_accepted_at = now() - interval '1 day', created_at = now() - interval '1 day'
where profile_id = '31a00000-0000-4000-8000-00000000000a';
set local role authenticated;
select pg_temp.as_user('31a00000-0000-4000-8000-00000000000a');
select is(
  public.save_account_details(pg_temp.body('{"address_street": "", "address_city": "", "address_postal_code": "", "address_notes": "", "interests": null}')),
  '{"ok": true}'::jsonb, 'A corrige sus datos');
reset role;
select is(
  (select row(address_street, address_city, address_postal_code, address_notes, interests)::text
   from public.account_details where profile_id = '31a00000-0000-4000-8000-00000000000a'),
  '(,,,,)', 'sin dirección ni intereses: quedan vacíos');
select ok(
  (select privacy_accepted_at < now() - interval '23 hours' and created_at < now() - interval '23 hours' and updated_at >= now() - interval '1 minute'
   from public.account_details where profile_id = '31a00000-0000-4000-8000-00000000000a'),
  'con la misma privacy, la aceptación queda la de antes; cambia solo updated_at');
set local role authenticated;
select pg_temp.as_user('31a00000-0000-4000-8000-00000000000a');
select public.save_account_details(pg_temp.body('{"privacy_version": "2026-12-01"}'));
reset role;
select ok(
  (select privacy_accepted_at >= now() - interval '1 minute' from public.account_details where profile_id = '31a00000-0000-4000-8000-00000000000a'),
  'con otra versión de la privacy, la aceptación es de ahora');

-- Lo que corta: cada campo inválido, con su nombre en el detalle (nunca el valor).
create function pg_temp.errors(extra jsonb) returns text language plpgsql as $$
declare
  v_detail text;
begin
  perform public.save_account_details(pg_temp.body(extra));
  return 'sin error';
exception when sqlstate '22023' then
  get stacked diagnostics v_detail = pg_exception_detail;
  return (select string_agg(x, ',' order by x) from unnest(string_to_array(v_detail, ',')) x);
end
$$;
grant execute on function pg_temp.errors(jsonb) to authenticated;

set local role authenticated;
select pg_temp.as_user('31a00000-0000-4000-8000-00000000000b');
select is(pg_temp.errors('{"first_name": "  ", "last_name": 5}'), 'first_name,last_name', 'nombre vacío y apellido que no es texto');
select is(pg_temp.errors('{"phone": "3401234567"}'), 'phone', 'el teléfono va con prefijo (+39…), solo dígitos');
select is(pg_temp.errors('{"phone": "+39 340 123"}'), 'phone', 'sin espacios (la app lo normaliza)');
select is(pg_temp.errors('{"birth_date": "1990-02-30"}'), 'birth_date', 'una fecha que no existe');
select is(pg_temp.errors('{"birth_date": "17/05/1990"}'), 'birth_date', 'otro formato');
select is(pg_temp.errors(format('{"birth_date": "%s"}', ((now() at time zone 'Europe/Rome')::date - interval '18 years' + interval '1 day')::date)::jsonb),
  'underage', 'menor de 18 (le falta un día): no');
select is(pg_temp.errors('{"address_street": "", "address_city": "Bergamo", "address_postal_code": ""}'),
  'address_postal_code,address_street', 'la dirección va toda junta (calle, ciudad y código postal)');
select is(pg_temp.errors('{"favorite_season": "monsone", "heard_from": "tv", "household_size": "10"}'),
  'favorite_season,heard_from,household_size', 'respuestas que no están en la lista');
select is(pg_temp.errors('{"interests": ["weekly", "otra"], "preferred_days": [1, 6]}'), 'interests,preferred_days',
  'listas con valores desconocidos (sábado no: Evelyn trabaja de lunes a viernes)');
select is(pg_temp.errors('{"interests": "weekly", "preferred_days": ["1"]}'), 'interests,preferred_days', 'listas con otra forma');
select is(pg_temp.errors('{"privacy_version": null}'), 'privacy_version', 'sin la versión de la privacy aceptada, no');
reset role;
select is((select count(*)::int from public.account_details where profile_id = '31a00000-0000-4000-8000-00000000000b'), 0,
  'con un error no se guarda nada');
set local role authenticated;
select pg_temp.as_user('31a00000-0000-4000-8000-00000000000b');
select is(pg_temp.errors(format('{"birth_date": "%s"}', ((now() at time zone 'Europe/Rome')::date - interval '18 years')::date)::jsonb),
  'sin error', 'el día que cumple 18, sí');
reset role;
delete from public.account_details where profile_id = '31a00000-0000-4000-8000-00000000000b';

-- La cocina no tiene ficha de clienta; sin sesión, nada.
set local role authenticated;
select pg_temp.as_user('31a00000-0000-4000-8000-0000000000c1');
select throws_ok($$ select public.save_account_details(pg_temp.body()) $$, '42501', 'not_a_client_account', 'la cocinera no');
select pg_temp.as_user('31a00000-0000-4000-8000-0000000000a1');
select throws_ok($$ select public.save_account_details(pg_temp.body()) $$, '42501', 'not_a_client_account', 'un colaborador tampoco');
reset role;
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.save_account_details(pg_temp.body()) $$, '42501', 'not_authenticated', 'sin sesión no');

-- =====================================================================
-- 3. Quién lee
-- =====================================================================
set local role authenticated;
select pg_temp.as_user('31a00000-0000-4000-8000-00000000000b');
select public.save_account_details(pg_temp.body('{"first_name": "Bea", "phone": "+393409999999"}'));
select is((select array_agg(first_name order by 1) from public.account_details), array['Bea'], 'B ve solo la suya');
select pg_temp.as_user('31a00000-0000-4000-8000-00000000000a');
select is((select array_agg(first_name order by 1) from public.account_details), array['Anna'], 'A, la suya');
select pg_temp.as_user('31a00000-0000-4000-8000-0000000000c1');
select is((select array_agg(first_name order by 1) from public.account_details), array['Anna', 'Bea'], 'la cocinera, todas');
select pg_temp.as_user('31a00000-0000-4000-8000-0000000000a1');
select is((select count(*)::int from public.account_details), 2, 'su colaborador, también');
reset role;
set local role anon;
select throws_ok($$ select count(*) from public.account_details $$, '42501', null, 'anon no lee nada');
reset role;

select * from finish();
rollback;
