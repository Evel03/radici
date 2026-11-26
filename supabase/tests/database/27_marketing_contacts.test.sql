-- =====================================================================
-- Lista de contactos para ofertas (migración 20261127100000_marketing_contacts.sql,
-- docs/contracts/public-request.md §13): doble opt-in, baja, retención y privilegios.
-- Corre como postgres.
-- =====================================================================
begin;
create extension if not exists pgtap with schema extensions;

select plan(45);

insert into auth.users (id, email) values
  ('a0270000-0000-4000-8000-000000000001', 'cocinera@marketing.test');
insert into public.chefs (id, profile_id, display_name) values
  ('cef27000-0000-4000-8000-000000000001', 'a0270000-0000-4000-8000-000000000001', 'Cocina de marketing');

-- Hash de prueba: 64 hexadecimales a partir de una letra.
create function pg_temp.h(p text) returns text language sql as $$
  select encode(extensions.digest(p, 'sha256'), 'hex');
$$;
create function pg_temp.sub(p_email text, p_token text, p_name text default 'Giulia', p_version text default '2026-11-27')
returns jsonb language sql as $$
  select public.marketing_subscribe(jsonb_build_object(
    'chef_id', 'cef27000-0000-4000-8000-000000000001', 'email', p_email, 'first_name', p_name,
    'locale', 'it', 'source', 'web', 'text_version', p_version, 'token_hash', pg_temp.h(p_token)));
$$;
create function pg_temp.row_of(p_email text) returns public.marketing_contacts language sql as $$
  select * from public.marketing_contacts where email = p_email;
$$;

-- ---------------------------------------------------------------------
-- 1. Privilegios: nadie más que la service role, y solo por las funciones
-- ---------------------------------------------------------------------
select ok(not has_table_privilege('anon', 'public.marketing_contacts', 'select'), 'anon no lee la lista');
select ok(not has_table_privilege('authenticated', 'public.marketing_contacts', 'select'), 'authenticated no lee la lista');
select ok(has_table_privilege('service_role', 'public.marketing_contacts', 'select'), 'la service role la lee');
select ok(not has_table_privilege('service_role', 'public.marketing_contacts', 'insert'), 'la service role no escribe directo');
select ok(not has_table_privilege('service_role', 'public.marketing_contacts', 'update'), 'ni actualiza directo');
select ok(not has_table_privilege('service_role', 'public.marketing_contacts', 'delete'), 'ni borra directo');
select ok(not has_function_privilege('anon', 'public.marketing_subscribe(jsonb)', 'execute'), 'anon no suscribe');
select ok(not has_function_privilege('authenticated', 'public.marketing_set(text, text)', 'execute'), 'authenticated no confirma ni da de baja');
select ok(not has_function_privilege('anon', 'public.marketing_status(text)', 'execute'), 'anon no ve estados');
select ok(has_function_privilege('service_role', 'public.marketing_subscribe(jsonb)', 'execute'), 'la service role suscribe');
select ok(has_function_privilege('service_role', 'public.marketing_status(text)', 'execute'), 'la service role ve el estado');
select ok(has_function_privilege('service_role', 'public.marketing_set(text, text)', 'execute'), 'la service role confirma y da de baja');
select ok(not has_function_privilege('service_role', 'private.purge_marketing_contacts()', 'execute'), 'la purga es solo del dueño');
select ok((select relrowsecurity from pg_class where oid = 'public.marketing_contacts'::regclass), 'RLS prendida, sin políticas');

-- ---------------------------------------------------------------------
-- 2. Suscribir: pendiente, con el email normalizado
-- ---------------------------------------------------------------------
select is(pg_temp.sub('  Giulia@Example.IT ', 'tok-1'), '{"send": true, "status": "pending"}'::jsonb, 'nuevo: pendiente y manda el link');
select is((pg_temp.row_of('giulia@example.it')).status, 'pending', 'queda pendiente, con el email en minúsculas');
select is(public.marketing_status(pg_temp.h('tok-1')) ->> 'status', 'pending', 'el link ve «pendiente»');
select is(public.marketing_status(pg_temp.h('tok-1')) ->> 'email', 'giulia@example.it', 'y el email (la función lo enmascara)');
select ok(not (public.marketing_status(pg_temp.h('tok-1')) ? 'first_name'), 'nunca el nombre');
select is(public.marketing_status(pg_temp.h('otro')), null, 'un token de nadie: null');

-- Otro pedido antes de confirmar: token nuevo, el viejo deja de servir.
select is(pg_temp.sub('giulia@example.it', 'tok-2'), '{"send": true, "status": "pending"}'::jsonb, 'pendiente otra vez: manda el link nuevo');
select is(public.marketing_status(pg_temp.h('tok-1')), null, 'el link viejo ya no sirve');
select is((select count(*)::int from public.marketing_contacts where email = 'giulia@example.it'), 1, 'una sola fila por email');

-- ---------------------------------------------------------------------
-- 3. Confirmar y darse de baja
-- ---------------------------------------------------------------------
select is(public.marketing_set(pg_temp.h('tok-2'), 'confirm') ->> 'status', 'confirmed', 'confirma');
select isnt((pg_temp.row_of('giulia@example.it')).confirmed_at, null, 'con la fecha de confirmación');
select is(public.marketing_set(pg_temp.h('tok-2'), 'confirm') ->> 'status', 'confirmed', 'confirmar dos veces no cambia nada');

-- Ya confirmada: otro pedido con la casilla no manda nada ni cambia el token.
select is(pg_temp.sub('giulia@example.it', 'tok-3', 'Giulia', '2026-12-01'), '{"send": false, "status": "confirmed"}'::jsonb, 'ya confirmada: no manda nada');
select is(public.marketing_status(pg_temp.h('tok-2')) ->> 'status', 'confirmed', 'el token sigue siendo el de la confirmación');
select is((pg_temp.row_of('giulia@example.it')).text_version, '2026-12-01', 'anota el texto aceptado esta vez');

select is(public.marketing_set(pg_temp.h('tok-2'), 'withdraw') ->> 'status', 'withdrawn', 'se da de baja');
select is((pg_temp.row_of('giulia@example.it')).first_name, null, 'la baja borra el nombre');
select isnt((pg_temp.row_of('giulia@example.it')).withdrawn_at, null, 'y guarda la fecha de la baja');
select is(public.marketing_set(pg_temp.h('tok-2'), 'confirm') ->> 'status', 'withdrawn', 'confirmar una baja no la revive');

-- Vuelve a marcar la casilla en otro pedido: un consentimiento nuevo, pendiente otra vez.
select is(pg_temp.sub('giulia@example.it', 'tok-4'), '{"send": true, "status": "pending"}'::jsonb, 'después de la baja, marcar otra vez: pendiente');
select is((pg_temp.row_of('giulia@example.it')).withdrawn_at, null, 'sin la baja vieja');

-- «No, grazie» desde el link de un pendiente: baja.
select pg_temp.sub('marco@example.it', 'tok-m');
select is(public.marketing_set(pg_temp.h('tok-m'), 'withdraw') ->> 'status', 'withdrawn', 'un pendiente que dice que no: baja');

select throws_ok($$select public.marketing_set(encode(extensions.digest('tok-m', 'sha256'), 'hex'), 'borrar')$$, '22023', null, 'acción inválida');
select throws_ok($$select public.marketing_subscribe('{"chef_id": "cef27000-0000-4000-8000-000000000001", "email": "x@y.it", "locale": "it", "source": "web", "text_version": "v", "token_hash": "no"}')$$, '22023', null, 'hash inválido');
select throws_ok($$select pg_temp.sub('sin-arroba', 'tok-x')$$, '23514', null, 'email inválido: lo frena la tabla');

-- ---------------------------------------------------------------------
-- 4. Vencimiento y retención
-- ---------------------------------------------------------------------
select pg_temp.sub('vieja@example.it', 'tok-v');
update public.marketing_contacts set requested_at = now() - interval '8 days' where email = 'vieja@example.it';
select is(public.marketing_status(pg_temp.h('tok-v')), null, 'un pendiente de más de 7 días ya no se ve');
select is(public.marketing_set(pg_temp.h('tok-v'), 'confirm'), null, 'ni se confirma');

select pg_temp.sub('activa@example.it', 'tok-a');
select public.marketing_set(pg_temp.h('tok-a'), 'confirm');
select pg_temp.sub('dormida@example.it', 'tok-d');
select public.marketing_set(pg_temp.h('tok-d'), 'confirm');
update public.marketing_contacts set last_activity_at = now() - interval '25 months' where email = 'dormida@example.it';
update public.marketing_contacts set withdrawn_at = now() - interval '25 months' where email = 'marco@example.it';

select is(private.purge_marketing_contacts(), 3, 'la purga borra el pendiente vencido, la confirmada dormida y la baja vieja');
select is(
  (select array_agg(email order by email) from public.marketing_contacts),
  array['activa@example.it', 'giulia@example.it'],
  'quedan la activa y la que volvió a aceptar'
);

select is((select schedule from cron.job where jobname = 'radici-purge-marketing-contacts'), '45 3 * * *', 'la purga corre todos los días');

-- Borrar el pedido no borra el contacto (vive aparte: la lista no depende de la ficha).
select ok(
  (select confdeltype = 'n' from pg_constraint where conrelid = 'public.marketing_contacts'::regclass and contype = 'f'
     and confrelid = 'public.requests'::regclass),
  'el pedido borrado deja el contacto (on delete set null)'
);

select * from finish();
rollback;
