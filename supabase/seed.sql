-- =====================================================================
-- Radici · datos de desarrollo (solo local; nunca en producción)
--
-- Usuarios (contraseña de desarrollo para todos: radici-dev-2026; también
-- sirve el login por OTP con Mailpit en http://127.0.0.1:54324):
--   evelyn@example.test   cocinera (Bergamo)
--   giulia@example.test   segunda cocinera, para probar aislamiento entre chefs
--   chiara@example.test   cliente con cuenta, alergia a lácteos (con consentimiento)
--   luca@example.test     familia Bonetti, un niño celíaco (con consentimiento)
--   paolo@example.test    cliente de Giulia
--   Sara Colombo          prospecto sin cuenta (vino del formulario web)
--
-- Fechas relativas a la semana actual (lunes = date_trunc('week', current_date)):
--   pasado  → semana anterior (siempre en el pasado)
--   futuro  → semana siguiente (siempre en el futuro)
-- Montos en centavos, calculados con la fórmula de SPEC §5.1 y las tarifas por defecto.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Usuarios de auth (el trigger on_auth_user_created crea los profiles como client)
-- ---------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
select
  '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
  extensions.crypt('radici-dev-2026', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', u.full_name, 'locale', u.locale),
  now(), now(), '', '', '', ''
from (values
  ('e0000000-0000-4000-8000-000000000001'::uuid, 'evelyn@example.test', 'Evelyn Ramírez', 'es'),
  ('e0000000-0000-4000-8000-000000000002'::uuid, 'giulia@example.test', 'Giulia Ferrari', 'it'),
  ('c0000000-0000-4000-8000-000000000001'::uuid, 'chiara@example.test', 'Chiara Rossi',   'it'),
  ('c0000000-0000-4000-8000-000000000002'::uuid, 'luca@example.test',   'Luca Bonetti',   'it'),
  ('c0000000-0000-4000-8000-000000000003'::uuid, 'paolo@example.test',  'Paolo Gritti',   'it')
) as u (id, email, full_name, locale);

insert into auth.identities (user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select u.id, u.id::text, 'email',
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       now(), now(), now()
from auth.users u
where u.email like '%@example.test';

update public.profiles set role = 'chef', phone = '+39 333 000 0001'
where id = 'e0000000-0000-4000-8000-000000000001';
update public.profiles set role = 'chef', phone = '+39 333 000 0002'
where id = 'e0000000-0000-4000-8000-000000000002';

-- ---------------------------------------------------------------------
-- Cocineras, tarifas y disponibilidad
-- ---------------------------------------------------------------------
insert into public.chefs (id, profile_id, display_name, service_area, whatsapp) values
  ('cef00000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001',
   'Evelyn', array['Bergamo','Città Alta','Seriate','Torre Boldone','Curno'], '+393330000001'),
  ('cef00000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000002',
   'Giulia', array['Treviglio','Dalmine'], '+393330000002');

-- Evelyn: todos los valores por defecto de la spec (2200, 1200, 380, 250, 15 %, 90, 45, 30, 30, 14, 24, 48, 90)
insert into public.chef_settings (chef_id) values ('cef00000-0000-4000-8000-000000000001');
-- Giulia: tarifas distintas, para que se note si se mezclan datos entre chefs
insert into public.chef_settings (chef_id, hourly_rate_cents, travel_fee_cents, shop_minutes, gap_minutes)
values ('cef00000-0000-4000-8000-000000000002', 2500, 1500, 40, 20);

-- Evelyn: lunes a viernes 9–18, sábado 9–13 (dow: 0 = domingo)
insert into public.availability_rules (chef_id, dow, start_time, end_time)
select 'cef00000-0000-4000-8000-000000000001'::uuid, d, time '09:00', time '18:00' from generate_series(1, 5) as d
union all
select 'cef00000-0000-4000-8000-000000000001'::uuid, 6, time '09:00', time '13:00';
-- Giulia: martes a sábado 10–19
insert into public.availability_rules (chef_id, dow, start_time, end_time)
select 'cef00000-0000-4000-8000-000000000002'::uuid, d, time '10:00', time '19:00' from generate_series(2, 6) as d;

-- Evelyn bloquea el viernes de dentro de dos semanas
insert into public.availability_exceptions (chef_id, date, note)
values ('cef00000-0000-4000-8000-000000000001', date_trunc('week', current_date)::date + 18, 'Giorno libero');

-- ---------------------------------------------------------------------
-- Clientes
-- ---------------------------------------------------------------------
insert into public.clients (id, chef_id, profile_id, display_name, contact_email, contact_phone, zone, address,
                            adults, kids, preferences, kitchen_notes, pay_mode, status, share_pantry, since) values
  ('c1000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001',
   'Chiara Rossi', 'chiara@example.test', '+39 340 111 2233', 'Città Alta', 'Via Gombito 12, 24129 Bergamo',
   2, 0, 'Poca carne rossa, tanta verdura. Niente cipolla cruda.', 'Forno ventilato, piano a induzione. Contenitori nel mobile alto.',
   'preauth', 'active', true, current_date - 60),
  ('c1000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002',
   'Famiglia Bonetti', 'luca@example.test', '+39 347 444 5566', 'Seriate', 'Via Paderno 5, 24068 Seriate',
   2, 1, 'Il bambino (7 anni) è celiaco. Piatti semplici, poco piccanti.', 'Cucina a gas. Pentole senza glutine separate, nel cassetto a sinistra.',
   'pay_after', 'trial', false, current_date - 20),
  -- prospecto: sin cuenta (profile_id null), vino del formulario público
  ('c1000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', null,
   'Sara Colombo', 'sara.colombo@example.test', '+39 333 777 8899', 'Bergamo centro', null,
   2, 2, null, null, 'preauth', 'prospect', false, current_date - 1),
  ('c1000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000003',
   'Paolo Gritti', 'paolo@example.test', '+39 349 000 1122', 'Treviglio', 'Viale Monte Grappa 8, 24047 Treviglio',
   1, 0, null, null, 'preauth', 'active', false, current_date - 30);

-- Consentimientos: privacidad para todos; salud para quien tiene restricciones (y Sara, que lo dio en el formulario)
insert into public.consents (chef_id, client_id, kind, text_version, granted_at) values
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'privacy',     'privacy-it-2026-10', now() - interval '60 days'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'health_data', 'health-it-2026-10',  now() - interval '60 days'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002', 'privacy',     'privacy-it-2026-10', now() - interval '20 days'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002', 'health_data', 'health-it-2026-10',  now() - interval '20 days'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000003', 'privacy',     'privacy-it-2026-10', now() - interval '1 day'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000003', 'health_data', 'health-it-2026-10',  now() - interval '1 day'),
  ('cef00000-0000-4000-8000-000000000002', 'c1000000-0000-4000-8000-000000000004', 'privacy',     'privacy-it-2026-10', now() - interval '30 days');

-- Restricciones (requieren el consentimiento de salud de arriba)
insert into public.client_restrictions (chef_id, client_id, allergen) values
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'milk'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002', 'gluten');

-- ---------------------------------------------------------------------
-- Recetario de Evelyn (piatti italiani) y de Giulia
-- ---------------------------------------------------------------------
insert into public.recipes (id, chef_id, name_it, name_es, fridge_days, freezable, freezer_days, diet, notes) values
  ('a0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'Lasagne alla bolognese',          'Lasaña a la boloñesa',               3, true,  60, null,         null),
  ('a0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'Risotto ai funghi porcini',       'Risotto de hongos porcini',           2, false, 60, 'vegetarian', 'Si può fare senza burro e parmigiano.'),
  ('a0000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', 'Minestrone di verdure',           'Minestrone de verduras',              4, true,  90, 'vegan',      null),
  ('a0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 'Polpette al sugo',                'Albóndigas con salsa',                3, true,  60, null,         null),
  ('a0000000-0000-4000-8000-000000000005', 'cef00000-0000-4000-8000-000000000001', 'Pollo al limone',                 'Pollo al limón',                      3, false, 60, null,         'Senza farina: adatto a celiaci.'),
  ('a0000000-0000-4000-8000-000000000006', 'cef00000-0000-4000-8000-000000000001', 'Pasta e fagioli',                 'Pasta con porotos',                   3, true,  60, 'vegan',      null),
  ('a0000000-0000-4000-8000-000000000007', 'cef00000-0000-4000-8000-000000000001', 'Polenta taragna e brasato',       'Polenta taragna con estofado',        3, true,  60, null,         'Piatto bergamasco. Il brasato si congela, la polenta no.'),
  ('a0000000-0000-4000-8000-000000000008', 'cef00000-0000-4000-8000-000000000001', 'Casoncelli alla bergamasca',      'Casoncelli a la bergamasca',          2, true,  60, null,         null),
  ('a0000000-0000-4000-8000-000000000009', 'cef00000-0000-4000-8000-000000000001', 'Salmone al forno con patate',     'Salmón al horno con papas',           2, false, 60, null,         null),
  ('a0000000-0000-4000-8000-000000000010', 'cef00000-0000-4000-8000-000000000001', 'Frittata di zucchine',            'Tortilla de zapallitos',              2, false, 60, 'vegetarian', null),
  ('a0000000-0000-4000-8000-000000000021', 'cef00000-0000-4000-8000-000000000002', 'Risotto alla milanese',           'Risotto a la milanesa',               2, false, 60, 'vegetarian', null),
  ('a0000000-0000-4000-8000-000000000022', 'cef00000-0000-4000-8000-000000000002', 'Ossobuco con gremolata',          'Osobuco con gremolata',               3, true,  60, null,         null);

insert into public.recipe_allergens (recipe_id, chef_id, allergen)
select r.recipe_id::uuid, r.chef_id::uuid, r.allergen::public.allergen
from (values
  ('a0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'gluten'),
  ('a0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'milk'),
  ('a0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'eggs'),
  ('a0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'celery'),
  ('a0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'milk'),
  ('a0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'celery'),
  ('a0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'sulphites'),
  ('a0000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', 'celery'),
  ('a0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 'gluten'),
  ('a0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 'eggs'),
  ('a0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 'milk'),
  ('a0000000-0000-4000-8000-000000000006', 'cef00000-0000-4000-8000-000000000001', 'gluten'),
  ('a0000000-0000-4000-8000-000000000006', 'cef00000-0000-4000-8000-000000000001', 'celery'),
  ('a0000000-0000-4000-8000-000000000007', 'cef00000-0000-4000-8000-000000000001', 'milk'),
  ('a0000000-0000-4000-8000-000000000007', 'cef00000-0000-4000-8000-000000000001', 'celery'),
  ('a0000000-0000-4000-8000-000000000007', 'cef00000-0000-4000-8000-000000000001', 'sulphites'),
  ('a0000000-0000-4000-8000-000000000008', 'cef00000-0000-4000-8000-000000000001', 'gluten'),
  ('a0000000-0000-4000-8000-000000000008', 'cef00000-0000-4000-8000-000000000001', 'eggs'),
  ('a0000000-0000-4000-8000-000000000008', 'cef00000-0000-4000-8000-000000000001', 'milk'),
  ('a0000000-0000-4000-8000-000000000009', 'cef00000-0000-4000-8000-000000000001', 'fish'),
  ('a0000000-0000-4000-8000-000000000010', 'cef00000-0000-4000-8000-000000000001', 'eggs'),
  ('a0000000-0000-4000-8000-000000000010', 'cef00000-0000-4000-8000-000000000001', 'milk'),
  ('a0000000-0000-4000-8000-000000000021', 'cef00000-0000-4000-8000-000000000002', 'milk'),
  ('a0000000-0000-4000-8000-000000000022', 'cef00000-0000-4000-8000-000000000002', 'gluten'),
  ('a0000000-0000-4000-8000-000000000022', 'cef00000-0000-4000-8000-000000000002', 'celery'),
  ('a0000000-0000-4000-8000-000000000022', 'cef00000-0000-4000-8000-000000000002', 'sulphites')
) as r (recipe_id, chef_id, allergen);

-- ---------------------------------------------------------------------
-- Pedidos
-- restrictions: {"allergens": [...], "diets": [...], "note": "..."} como los guarda
-- submit_public_request (docs/contracts/public-request.md §3); null sin restricciones.
-- ---------------------------------------------------------------------
insert into public.requests (id, chef_id, client_id, type, status, adults, kids, days, meals, restrictions, wishes,
                             notes, preferred_date, preferred_start, pay_mode, target_session_id, text, created_at) values
  -- Chiara, semana pasada (ya cobrada)
  ('b0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001',
   'week', 'accepted', 2, 0, 5, array['dinner'], '{"allergens": ["milk"], "diets": [], "note": ""}',
   array['a0000000-0000-4000-8000-000000000003'::uuid], null,
   date_trunc('week', current_date)::date - 5, '10:00', 'preauth', null, null, now() - interval '14 days'),
  -- Bonetti, semana pasada (cocinada, paga en efectivo)
  ('b0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002',
   'week', 'accepted', 2, 1, 5, array['dinner'], '{"allergens": ["gluten"], "diets": [], "note": ""}',
   array['a0000000-0000-4000-8000-000000000005'::uuid], 'Primo servizio, siamo curiosi!',
   date_trunc('week', current_date)::date - 3, '14:00', 'pay_after', null, null, now() - interval '12 days'),
  -- Chiara, semana que viene (confirmada)
  ('b0000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001',
   'week', 'accepted', 2, 0, 5, array['dinner'], '{"allergens": ["milk"], "diets": [], "note": ""}',
   '{}', null,
   date_trunc('week', current_date)::date + 8, '10:00', 'preauth', null, null, now() - interval '4 days'),
  -- Sara (prospecto), presupuesto enviado y horario retenido
  ('b0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000003',
   'week', 'quoted', 2, 2, 5, array['dinner'], null,
   array['a0000000-0000-4000-8000-000000000001'::uuid, 'a0000000-0000-4000-8000-000000000008'::uuid], 'Ci hanno consigliato i casoncelli!',
   date_trunc('week', current_date)::date + 10, '15:00', 'preauth', null, null, now() - interval '1 day'),
  -- Bonetti, evento: compleanno (bandeja de entrada de Evelyn)
  ('b0000000-0000-4000-8000-000000000005', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002',
   'extra', 'new', 10, 6, 1, array['dinner'], '{"allergens": ["gluten"], "diets": [], "note": ""}',
   '{}', 'Festa di compleanno di Tommaso: tutto senza glutine, per favore.',
   date_trunc('week', current_date)::date + 12, '16:00', 'pay_after', null, null, now() - interval '3 hours'),
  -- Paolo (cliente de Giulia)
  ('b0000000-0000-4000-8000-000000000007', 'cef00000-0000-4000-8000-000000000002', 'c1000000-0000-4000-8000-000000000004',
   'week', 'accepted', 1, 0, 5, array['lunch'], null,
   '{}', null,
   date_trunc('week', current_date)::date + 8, '10:00', 'preauth', null, null, now() - interval '5 days');

-- ---------------------------------------------------------------------
-- Sesiones (busy se calcula sola; compra y margen se copian de chef_settings)
-- ---------------------------------------------------------------------
insert into public.sessions (id, chef_id, client_id, request_id, date, start_time, cook_minutes, portions, status, hold_until,
                             pay_mode, service_cents, groceries_est_cents, preauth_cents, groceries_actual_cents,
                             service_paid_at, groceries_paid_at, cancelled_at, cancel_reason) values
  -- Chiara, pasada y cobrada. 2 ad · 5 días · cena: 10 porciones, 3 recetas, 180 min
  ('d0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000001', date_trunc('week', current_date)::date - 5, '10:00', 180, 10, 'paid', null,
   'preauth', 7800, 3800, 4370, 3925,
   (date_trunc('week', current_date)::date - 5 + time '14:00') at time zone 'Europe/Rome',
   (date_trunc('week', current_date)::date - 5 + time '14:00') at time zone 'Europe/Rome', null, null),
  -- Bonetti, pasada y cocinada, paga al final. 2 ad · 1 niño · 5 días · cena (vector 5): 15 porciones, 180 min
  ('d0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002',
   'b0000000-0000-4000-8000-000000000002', date_trunc('week', current_date)::date - 3, '14:00', 180, 15, 'cooked', null,
   'pay_after', 7800, 5050, 5808, 5310, null, null, null, null),
  -- Chiara, semana que viene, confirmada
  ('d0000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000003', date_trunc('week', current_date)::date + 8, '10:00', 180, 10, 'confirmed', null,
   'preauth', 7800, 3800, 4370, null, null, null, null, null),
  -- Sara, presupuesto enviado: sesión held que retiene el horario 48 h. 2 ad · 2 niños · 5 días · cena (vector 1)
  ('d0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000003',
   'b0000000-0000-4000-8000-000000000004', date_trunc('week', current_date)::date + 10, '15:00', 180, 20, 'held', now() + interval '47 hours',
   'preauth', 7800, 6300, 7245, null, null, null, null, null),
  -- Bonetti, un presupuesto anterior que rechazaron (2 ad · 1 niño · 3 días · cena): cancelado,
  -- no bloquea aunque se superpone con la de Chiara
  ('d0000000-0000-4000-8000-000000000005', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002',
   null, date_trunc('week', current_date)::date + 8, '11:00', 150, 9, 'cancelled', null,
   'pay_after', 6700, 3030, 3485, null, null, null, now() - interval '6 days', 'declined'),
  -- Paolo (Giulia), mismo día y hora que Chiara: otro chef, no choca
  ('d0000000-0000-4000-8000-000000000007', 'cef00000-0000-4000-8000-000000000002', 'c1000000-0000-4000-8000-000000000004',
   'b0000000-0000-4000-8000-000000000007', date_trunc('week', current_date)::date + 8, '10:00', 150, 5, 'confirmed', null,
   'preauth', 7750, 1900, 2185, null, null, null, null, null);

-- ---------------------------------------------------------------------
-- Presupuestos (snapshot de tarifas al enviar)
-- ---------------------------------------------------------------------
insert into public.quotes (id, chef_id, request_id, session_id, version, menu, cook_minutes, portions,
                           service_cents, groceries_est_cents, preauth_cents, pricing_snapshot, allergen_override,
                           slot_date, slot_start, hold_until, sent_at, accepted_at) values
  ('f0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
   'd0000000-0000-4000-8000-000000000001', 1,
   array['a0000000-0000-4000-8000-000000000003','a0000000-0000-4000-8000-000000000005','a0000000-0000-4000-8000-000000000006']::uuid[],
   180, 10, 7800, 3800, 4370,
   '{"hourly_rate_cents":2200,"travel_fee_cents":1200,"adult_portion_cents":380,"kid_portion_cents":250,"preauth_buffer_pct":15,"min_cook_minutes":90,"recipes":3}',
   null, date_trunc('week', current_date)::date - 5, '10:00', now() - interval '12 days', now() - interval '13 days', now() - interval '12 days'),
  ('f0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
   'd0000000-0000-4000-8000-000000000002', 1,
   array['a0000000-0000-4000-8000-000000000005','a0000000-0000-4000-8000-000000000009','a0000000-0000-4000-8000-000000000002']::uuid[],
   180, 15, 7800, 5050, 5808,
   '{"hourly_rate_cents":2200,"travel_fee_cents":1200,"adult_portion_cents":380,"kid_portion_cents":250,"preauth_buffer_pct":15,"min_cook_minutes":90,"recipes":3}',
   null, date_trunc('week', current_date)::date - 3, '14:00', now() - interval '9 days', now() - interval '11 days', now() - interval '10 days'),
  ('f0000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000003',
   'd0000000-0000-4000-8000-000000000003', 1,
   array['a0000000-0000-4000-8000-000000000003','a0000000-0000-4000-8000-000000000005','a0000000-0000-4000-8000-000000000009']::uuid[],
   180, 10, 7800, 3800, 4370,
   '{"hourly_rate_cents":2200,"travel_fee_cents":1200,"adult_portion_cents":380,"kid_portion_cents":250,"preauth_buffer_pct":15,"min_cook_minutes":90,"recipes":3}',
   null, date_trunc('week', current_date)::date + 8, '10:00', now() - interval '1 day', now() - interval '3 days', now() - interval '2 days'),
  -- Sara: enviado, sin aceptar. La lasaña lleva lácteos y gluten pero Sara no tiene restricciones.
  ('f0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000004',
   'd0000000-0000-4000-8000-000000000004', 1,
   array['a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000008','a0000000-0000-4000-8000-000000000004']::uuid[],
   180, 20, 7800, 6300, 7245,
   '{"hourly_rate_cents":2200,"travel_fee_cents":1200,"adult_portion_cents":380,"kid_portion_cents":250,"preauth_buffer_pct":15,"min_cook_minutes":90,"recipes":3}',
   null, date_trunc('week', current_date)::date + 10, '15:00', now() + interval '47 hours', now() - interval '1 hour', null);

update public.sessions s set quote_id = q.id
from public.quotes q
where q.session_id = s.id;

-- Chiara pide un cambio para su próxima sesión
insert into public.requests (id, chef_id, client_id, type, status, target_session_id, text, created_at) values
  ('b0000000-0000-4000-8000-000000000006', 'cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001',
   'change', 'new', 'd0000000-0000-4000-8000-000000000003', 'Questa volta al posto del salmone una frittata, grazie!', now() - interval '2 hours');

-- ---------------------------------------------------------------------
-- Menú de cada sesión
-- ---------------------------------------------------------------------
insert into public.session_menu (session_id, recipe_id, chef_id, portions)
select m.session_id::uuid, m.recipe_id::uuid, m.chef_id::uuid, m.portions
from (values
  ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', 4),
  ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000005', 'cef00000-0000-4000-8000-000000000001', 3),
  ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000006', 'cef00000-0000-4000-8000-000000000001', 3),
  ('d0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000005', 'cef00000-0000-4000-8000-000000000001', 5),
  ('d0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000009', 'cef00000-0000-4000-8000-000000000001', 5),
  ('d0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002', 'cef00000-0000-4000-8000-000000000001', 5),
  ('d0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000003', 'cef00000-0000-4000-8000-000000000001', 4),
  ('d0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000005', 'cef00000-0000-4000-8000-000000000001', 3),
  ('d0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000009', 'cef00000-0000-4000-8000-000000000001', 3),
  ('d0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000001', 'cef00000-0000-4000-8000-000000000001', 7),
  ('d0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000008', 'cef00000-0000-4000-8000-000000000001', 7),
  ('d0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000004', 'cef00000-0000-4000-8000-000000000001', 6),
  ('d0000000-0000-4000-8000-000000000007', 'a0000000-0000-4000-8000-000000000021', 'cef00000-0000-4000-8000-000000000002', 3),
  ('d0000000-0000-4000-8000-000000000007', 'a0000000-0000-4000-8000-000000000022', 'cef00000-0000-4000-8000-000000000002', 2)
) as m (session_id, recipe_id, chef_id, portions);

-- ---------------------------------------------------------------------
-- Tickets y pagos
-- (las fotos no se suben al bucket en el seed: solo queda la fila con su ruta)
-- ---------------------------------------------------------------------
insert into public.receipts (chef_id, session_id, storage_path, total_cents, store_name, purchased_at, uploaded_by) values
  ('cef00000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
   'cef00000-0000-4000-8000-000000000001/d0000000-0000-4000-8000-000000000001/scontrino.jpg', 3925, 'Esselunga Bergamo',
   (date_trunc('week', current_date)::date - 5 + time '09:30') at time zone 'Europe/Rome',
   'e0000000-0000-4000-8000-000000000001'),
  ('cef00000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
   'cef00000-0000-4000-8000-000000000001/d0000000-0000-4000-8000-000000000002/scontrino.jpg', 5310, 'Coop Seriate',
   (date_trunc('week', current_date)::date - 3 + time '13:30') at time zone 'Europe/Rome',
   'e0000000-0000-4000-8000-000000000001');

insert into public.payments (chef_id, session_id, kind, provider, stripe_payment_intent_id, amount_cents, captured_cents,
                             service_part_cents, groceries_part_cents, status, idempotency_key, created_at) values
  -- Chiara: retención única (servicio 7800 + insumos 4370) capturada al cocinar por servicio + ticket (7800 + 3925)
  ('cef00000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001', 'preauth', 'stripe', 'pi_seed_chiara_0001',
   12170, 11725, 7800, 3925, 'succeeded',
   'session:d0000000-0000-4000-8000-000000000001:preauth:1', now() - interval '9 days'),
  -- Bonetti: Evelyn registró efectivo, pendiente de confirmar (servicio 7800 + ticket 5310)
  ('cef00000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002', 'cash', 'cash', null,
   13110, 0, 7800, 5310, 'pending',
   'session:d0000000-0000-4000-8000-000000000002:cash:1', now() - interval '2 days');

-- ---------------------------------------------------------------------
-- F2: porciones en la heladera y despensa
-- ---------------------------------------------------------------------
insert into public.prepared_portions (chef_id, client_id, session_id, recipe_id, count_initial, count_left, location, made_on, consume_by)
select 'cef00000-0000-4000-8000-000000000001'::uuid, 'c1000000-0000-4000-8000-000000000002'::uuid,
       'd0000000-0000-4000-8000-000000000002'::uuid, p.recipe_id::uuid, p.n, p.left_n, p.loc::public.storage_loc,
       date_trunc('week', current_date)::date - 3,
       date_trunc('week', current_date)::date - 3 + p.days
from (values
  ('a0000000-0000-4000-8000-000000000005', 5, 1, 'fridge',  3),
  ('a0000000-0000-4000-8000-000000000009', 5, 0, 'fridge',  2),
  ('a0000000-0000-4000-8000-000000000002', 5, 4, 'freezer', 60)
) as p (recipe_id, n, left_n, loc, days);

insert into public.pantry_items (chef_id, client_id, name, qty_text, location, expires_on, added_by) values
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'Latte di avena',  '1 l',    'fridge',  current_date + 2,   'c0000000-0000-4000-8000-000000000001'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'Zucchine',        '4',      'fridge',  current_date + 3,   'c0000000-0000-4000-8000-000000000001'),
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'Riso Carnaroli',  '1 kg',   'pantry',  current_date + 200, 'c0000000-0000-4000-8000-000000000001'),
  -- Bonetti no comparte la despensa: Evelyn no lo ve
  ('cef00000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002', 'Pasta senza glutine', '500 g', 'pantry', current_date + 120, 'c0000000-0000-4000-8000-000000000002');
