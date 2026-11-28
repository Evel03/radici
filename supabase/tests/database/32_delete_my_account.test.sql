-- =====================================================================
-- «Borrar mi cuenta» (migración 20261127150000_delete_my_account.sql, auth.md §20).
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

-- La cocinera C, su colaborador M y una clienta A con datos de cuenta y ficha.
insert into auth.users (id, email, email_confirmed_at) values
  ('32a00000-0000-4000-8000-0000000000c1', 'cocina@borrar.test', now()),
  ('32a00000-0000-4000-8000-0000000000a1', 'socio@borrar.test',  now()),
  ('32a00000-0000-4000-8000-00000000000a', 'a@borrar.test',      now());
update public.profiles set role = 'chef'
where id in ('32a00000-0000-4000-8000-0000000000c1', '32a00000-0000-4000-8000-0000000000a1');
insert into public.chefs (id, profile_id, display_name, whatsapp) values
  ('32a10000-0000-4000-8000-000000000001', '32a00000-0000-4000-8000-0000000000c1', 'Chef Borrar', '+393330000032');
insert into public.chef_members (chef_id, profile_id) values
  ('32a10000-0000-4000-8000-000000000001', '32a00000-0000-4000-8000-0000000000a1');
insert into public.clients (id, chef_id, profile_id, display_name, status, share_pantry) values
  ('32a20000-0000-4000-8000-00000000000a', '32a10000-0000-4000-8000-000000000001', '32a00000-0000-4000-8000-00000000000a', 'Anna', 'active', false);
insert into public.account_details (profile_id, first_name, last_name, phone, birth_date, privacy_version, privacy_accepted_at) values
  ('32a00000-0000-4000-8000-00000000000a', 'Anna', 'Rota', '+393401234567', '1990-05-17', '2026-11-28', now());
insert into auth.sessions (id, user_id) values
  ('32a30000-0000-4000-8000-00000000000a', '32a00000-0000-4000-8000-00000000000a');

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

select ok(has_function_privilege('authenticated', 'public.delete_my_account()', 'EXECUTE'), 'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.delete_my_account()', 'EXECUTE'), 'anon no');

-- La cocina no se borra así.
select pg_temp.as_user('32a00000-0000-4000-8000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.delete_my_account() $$, '42501', 'kitchen_account', 'la cocinera no');
reset role;
select pg_temp.as_user('32a00000-0000-4000-8000-0000000000a1');
set local role authenticated;
select throws_ok($$ select public.delete_my_account() $$, '42501', 'kitchen_account', 'su colaborador tampoco');
reset role;
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.delete_my_account() $$, '42501', 'not_authenticated', 'sin sesión no');

-- La clienta se borra.
select pg_temp.as_user('32a00000-0000-4000-8000-00000000000a');
set local role authenticated;
select lives_ok($$ select public.delete_my_account() $$, 'A borra su cuenta');
reset role;
select is((select count(*)::int from auth.users where id = '32a00000-0000-4000-8000-00000000000a'), 0, 'su cuenta de Auth no está');
select is((select count(*)::int from public.profiles where id = '32a00000-0000-4000-8000-00000000000a')
          + (select count(*)::int from public.account_details where profile_id = '32a00000-0000-4000-8000-00000000000a'), 0,
  'ni su perfil ni sus datos de cuenta');
select is((select count(*)::int from auth.sessions where user_id = '32a00000-0000-4000-8000-00000000000a'), 0, 'ni sus sesiones');
select is(
  (select row(display_name, profile_id)::text from public.clients where id = '32a20000-0000-4000-8000-00000000000a'),
  '(Anna,)',
  'la ficha de Evelyn queda, sin la cuenta');
select is((select count(*)::int from auth.users where id in ('32a00000-0000-4000-8000-0000000000c1', '32a00000-0000-4000-8000-0000000000a1')), 2,
  'las cuentas de la cocina siguen');

select * from finish();
rollback;
