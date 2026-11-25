-- =====================================================================
-- Radici · Menú de la web: los nombres de los ingredientes, solo para el buscador.
--
-- Decisión de la dueña (25/11/2026): la caja de búsqueda del formulario tiene que encontrar «carne»,
-- «verdura», «calabacín»… aunque el nombre y la descripción del plato no lo digan. Los nombres de los
-- ingredientes viajan en el menú público, pero la web NO los muestra: solo los usa el buscador.
--
-- get_public_menu: la misma de 20261120100000_recipe_photos.sql, más `ingredients` en cada plato: los
-- nombres de los ingredientes del plato tal como los escribió Evelyn (en español), recortados, sin repetir
-- sin distinguir mayúsculas, en el orden del plato y hasta 40 (cada uno ya tiene un máximo de 80 caracteres
-- por check de la tabla). Sale por private.recipe_ingredient_names (la del libro del menú), la misma lista
-- que ve la clienta en el envío. [] sin ingredientes: la clave está siempre. Nunca cantidades, unidades,
-- secciones ni notas.
--
-- create or replace conserva la firma y los privilegios (solo service_role); se repiten para que se vean.
-- =====================================================================
create or replace function public.get_public_menu(p_chef_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', r.id,
             'name', jsonb_build_object('it', r.name_it, 'es', r.name_es, 'en', r.name_en),
             'description', jsonb_build_object('it', r.description_it, 'es', r.description_es,
                                               'en', r.description_en),
             'allergens', (select coalesce(jsonb_agg(a.allergen order by a.allergen), '[]'::jsonb)
                           from public.recipe_allergens a
                           where a.recipe_id = r.id),
             'diet', r.diet,
             'seasonMonths', (select jsonb_agg(m order by m) from unnest(r.season_months) as m),
             'photoId', r.photo_id,
             'ingredients', (select coalesce(jsonb_agg(t.name order by t.n), '[]'::jsonb)
                             from jsonb_array_elements(private.recipe_ingredient_names(r.id))
                                    with ordinality as t(name, n)
                             where t.n <= 40))
           order by lower(r.name_it), r.id),
         '[]'::jsonb)
  from public.recipes r
  where r.chef_id = p_chef_id
    and r.active
    and r.catalog_visible
    and r.description_it is not null
$$;

comment on function public.get_public_menu(uuid) is
  'Los platos publicados de una cocinera (activos, visibles en el catálogo y con descripción en italiano) para la pestaña «Menù» de la web: [{id, name: {it, es, en}, description: {it, es, en}, allergens, diet, seasonMonths, photoId, ingredients}], por nombre sin mayúsculas y después por id; [] si no hay. photoId null = sin foto. ingredients: solo los nombres (como los escribió la cocinera, sin repetir, en el orden del plato, hasta 40) para el buscador de la web, que no los muestra; [] sin ingredientes. Nunca cantidades, unidades, secciones ni notas. Solo service role (Edge Function public-request).';

revoke all on function public.get_public_menu(uuid) from public, anon, authenticated;
grant execute on function public.get_public_menu(uuid) to service_role;
