#!/usr/bin/env bash
# Cuentas del área de Evelyn (/gestione/ y la app) en producción. Lo corre deploy-supabase.yml desde la
# raíz del repo, en dos pasos:
#
#   chef     «Cuenta de la cocinera (solo la primera vez)», justo después de db push. Solo mientras no
#            haya ninguna cocinera: crea su cuenta, corre promote_to_chef (que le pone una contraseña al
#            azar y le cierra las sesiones, así que nunca corre otra vez) y le carga el horario inicial
#            (private.add_default_availability, contrato public-request §11.1).
#   members  «Colaboradores de la cocinera», al final, en cada despliegue. La lista del secreto
#            CHEF_MEMBER_EMAILS manda: la valida y la convierte en SQL chef-members.ts (al lado, con
#            tests); crea las cuentas que faltan y private.sync_chef_members agrega a los que faltan y
#            saca a los que ya no están (su cuenta de Auth se borra; la de una ficha de cliente, o una que
#            no se puede borrar, queda como cuenta de cliente). Después cuenta los usuarios de Auth: tienen
#            que ser la cocinera y sus colaboradores. Va después de publicar las funciones: un error en la
#            lista deja el despliegue en rojo, pero no deja la base migrada con las funciones viejas.
#
#            Además exige (corta el paso): una sola fila en chefs, ningún usuario anónimo y, después de
#            sincronizar, chef_members igual a la lista. Avisa, sin cortar, si una cuenta de la cocina tiene
#            identidades que no son de email (el hook de la cocina solo con código, PR08, las deja sin uso),
#            e informa cuántas cuentas hay de clientas, de prueba y sin confirmar: solo números, nunca emails.
#
# Las cuentas nacen confirmadas, con una contraseña al azar que nadie conoce (se entra con el código por
# email) y con el idioma de los avisos para el email del código. La clave secreta del proyecto se lee una
# sola vez, enmascarada, y solo si hay que crear alguna cuenta. Ningún email de un colaborador sale en el
# log: cada uno se enmascara (::add-mask::) antes de usarlo y los mensajes dicen solo «s***@d***.it».
#
# Entorno: SUPABASE_PROJECT_REF y SUPABASE_ACCESS_TOKEN; chef: CHEF_LOGIN_EMAIL, CHEF_DISPLAY_NAME y
# CHEF_LOCALE; members: CHEF_MEMBER_EMAILS, CHEF_LOGIN_EMAIL y CHEF_LOCALE. Necesita curl, jq, openssl y
# node. Tests: deploy-accounts.test.ts (al lado), con la Management API y Auth simuladas.
set -euo pipefail

api="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}"

# SQL como postgres por la Management API: imprime las filas en JSON. Si falla, muestra solo el mensaje de
# error (las respuestas de error no traen claves).
sql() {
  local out
  if ! out=$(jq -n --arg query "$1" '{query: $query}' \
    | curl -sS --fail-with-body -X POST "${api}/database/query" \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary @-); then
    echo "::error::Falló una consulta a la base: $(jq -r '.message // .error // "sin mensaje"' <<< "${out}" 2>/dev/null || echo "sin mensaje")" >&2
    return 1
  fi
  printf '%s' "${out}"
}

# El número de una consulta que devuelve una fila con la columna n.
count() {
  sql "$1" | jq -r '.[0].n'
}

# Cuántas cuentas hay con ese email, y cuántas sin confirmar. El email ya está validado (sin comillas ni
# espacios): va dentro de SQL.
users_with() {
  count "select count(*)::int as n from auth.users where lower(email) = lower('$1')"
}
unconfirmed_with() {
  count "select count(*)::int as n from auth.users where lower(email) = lower('$1') and email_confirmed_at is null"
}

# Clave secreta nueva (sb_secret_…: solo en apikey, el gateway arma el JWT) o, si el proyecto todavía usa
# las de antes, la service_role (también como Bearer). Se lee una sola vez.
admin_headers=()
admin_key() {
  local keys secret legacy key
  if [ "${#admin_headers[@]}" -gt 0 ]; then return 0; fi
  keys=$(curl -sS --fail-with-body "${api}/api-keys?reveal=true" -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}")
  secret=$(jq -r '[.[] | select(.type == "secret")][0].api_key // empty' <<< "${keys}")
  legacy=$(jq -r '[.[] | select(.name == "service_role")][0].api_key // empty' <<< "${keys}")
  unset keys
  for key in "${secret}" "${legacy}"; do
    if [ -n "${key}" ]; then echo "::add-mask::${key}"; fi
  done
  if [ -n "${secret}" ]; then
    admin_headers=(-H "Content-Type: application/json" -H "apikey: ${secret}")
  elif [ -n "${legacy}" ]; then
    admin_headers=(-H "Content-Type: application/json" -H "apikey: ${legacy}" -H "Authorization: Bearer ${legacy}")
  else
    echo "::error::No se pudo leer la clave secreta del proyecto."
    return 1
  fi
}

# Cuenta confirmada para $1, con una contraseña al azar y el idioma del email del código. $2 dice de quién
# es en los mensajes ("de la cocinera", "del colaborador s***@…"; nunca el email de un colaborador).
create_user() {
  local created status
  admin_key
  created="$(mktemp)"
  status=$(jq -n --arg email "$1" --arg password "$(openssl rand -hex 32)" --arg locale "${CHEF_LOCALE:-es}" \
    '{email: $email, password: $password, email_confirm: true, user_metadata: {locale: $locale}}' \
    | curl -sS -o "${created}" -w '%{http_code}' -X POST "https://${SUPABASE_PROJECT_REF}.supabase.co/auth/v1/admin/users" \
        "${admin_headers[@]}" --data-binary @-)
  if [ "${status}" != "200" ] && [ "${status}" != "201" ]; then
    echo "::error::No se pudo crear la cuenta $2 (${status}): $(jq -r '.msg // .message // .error_code // "sin mensaje"' "${created}" 2>/dev/null || echo "sin mensaje")"
    rm -f "${created}"
    return 1
  fi
  rm -f "${created}"
}

# La cocinera, solo la primera vez.
chef_account() {
  local chefs users unconfirmed rules
  chefs=$(count "select count(*)::int as n from public.chefs")
  if [ "${chefs}" != "0" ]; then
    echo "Ya hay cocinera: no se toca (promote_to_chef le cerraría las sesiones)."
    return 0
  fi
  if [ -z "${CHEF_LOGIN_EMAIL:-}" ] || [ -z "${CHEF_DISPLAY_NAME:-}" ]; then
    echo "::warning::Todavía no hay cocinera y faltan las variables CHEF_LOGIN_EMAIL o CHEF_DISPLAY_NAME: la función responde 500 (no_chef) hasta crearla."
    return 0
  fi
  # Sin comillas ni espacios: el email y el nombre van dentro de SQL.
  if ! [[ "${CHEF_LOGIN_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "::error::CHEF_LOGIN_EMAIL no es un email válido."
    exit 1
  fi
  if ! [[ "${CHEF_DISPLAY_NAME}" =~ ^[[:alpha:]][[:alpha:][:space:].-]{0,49}$ ]]; then
    echo "::error::CHEF_DISPLAY_NAME tiene que ser un nombre (letras, espacios, punto o guion)."
    exit 1
  fi
  users=$(users_with "${CHEF_LOGIN_EMAIL}")
  if [ "${users}" = "0" ]; then
    create_user "${CHEF_LOGIN_EMAIL}" "de la cocinera"
  fi
  # Una cuenta con ese email sin confirmar la registró otro (antes de apagar las altas) o se creó en el
  # panel sin "Auto Confirm User": promote_to_chef la rechaza. Hay que borrarla a mano.
  unconfirmed=$(unconfirmed_with "${CHEF_LOGIN_EMAIL}")
  if [ "${unconfirmed}" != "0" ]; then
    echo "::error::Ya hay una cuenta con ${CHEF_LOGIN_EMAIL} sin confirmar (no la creó este workflow). Borrarla en Authentication → Users y volver a desplegar."
    exit 1
  fi
  sql "select public.promote_to_chef('${CHEF_LOGIN_EMAIL}', '${CHEF_DISPLAY_NAME}')" > /dev/null
  # Horario inicial (contrato §11.1): db push corrió antes de que existiera la cocinera, así que la
  # migración no se lo dio. Con la cocinera ya creada esta parte no vuelve a correr.
  if ! rules=$(count "select private.add_default_availability() as n"); then
    echo "::error::La cocinera quedó creada sin horario y este paso no lo reintenta: correr select private.add_default_availability(); en el SQL editor."
    exit 1
  fi
  echo "Cocinera creada. Horario inicial cargado: ${rules} reglas (lunes a viernes de 9 a 15)."
}

# La lista de emails del secreto como array de SQL (ya validados: sin comillas ni espacios).
sql_array() {
  jq -r --arg q "'" '"array[" + ([.[].email | $q + . + $q] | join(", ")) + "]::text[]"' <<< "$1"
}

# Las cuentas de la cocina (la cocinera y sus colaboradores), como subconsulta de ids.
kitchen_ids="select profile_id from public.chefs union select profile_id from public.chef_members"

# Lo que se verifica en cada despliegue sobre las cuentas de la cocina y sobre las demás. Todo son números:
# ningún email sale en el log.
account_checks() {
  local anonymous
  anonymous=$(count "select count(*)::int as n from auth.users where is_anonymous")
  if [ "${anonymous}" != "0" ]; then
    echo "::error::Hay ${anonymous} usuarios anónimos en Auth: las altas anónimas están apagadas (contrato auth.md), nadie tendría que existir. Revisar Authentication → Users."
    exit 1
  fi
}

account_report() {
  local identities clients test unconfirmed
  identities=$(count "select count(*)::int as n from auth.identities where provider <> 'email' and user_id in (${kitchen_ids})")
  if [ "${identities}" != "0" ]; then
    echo "::warning::${identities} identidades de las cuentas de la cocina no son de email (por ejemplo Google): la cocina entra solo con el código por email y esas identidades quedan sin uso. Quitarlas en Authentication → Users."
  fi
  clients=$(count "select count(*)::int as n from auth.users where id not in (${kitchen_ids})")
  test=$(count "select count(*)::int as n from auth.users where id not in (${kitchen_ids}) and email ~* '(@example\.(com|org|net)|\.test|\.invalid)\$'")
  unconfirmed=$(count "select count(*)::int as n from auth.users where email_confirmed_at is null")
  echo "Cuentas de clientas: ${clients} (de prueba: ${test}; sin confirmar: ${unconfirmed})."
}

# Los colaboradores, en cada despliegue: la lista manda.
members() {
  local list total_list email masked users unconfirmed query result chefs members_db members_match total extra i
  if ! list=$(node supabase/scripts/chef-members.ts list); then
    echo "::error::CHEF_MEMBER_EMAILS no es una lista válida (el motivo está arriba). Corregir el secreto y volver a correr Deploy Supabase."
    exit 1
  fi
  while IFS= read -r email; do
    if [ -n "${email}" ]; then echo "::add-mask::${email}"; fi
  done < <(jq -r '.[].email' <<< "${list}")
  total_list=$(jq 'length' <<< "${list}")

  account_checks
  chefs=$(count "select count(*)::int as n from public.chefs")
  if [ "${chefs}" -gt 1 ]; then
    echo "::error::Hay ${chefs} cocinas en public.chefs y tiene que haber una sola (SPEC §6): no se sincronizan colaboradores."
    exit 1
  fi
  if [ "${chefs}" = "0" ]; then
    if [ "${total_list}" != "0" ]; then
      echo "::warning::Sin cocinera no hay de quién ser colaborador: CHEF_MEMBER_EMAILS se aplica en el despliegue que la cree."
    fi
  else
    for ((i = 0; i < total_list; i++)); do
      email=$(jq -r --argjson i "${i}" '.[$i].email' <<< "${list}")
      masked=$(jq -r --argjson i "${i}" '.[$i].masked' <<< "${list}")
      users=$(users_with "${email}")
      if [ "${users}" = "0" ]; then
        create_user "${email}" "del colaborador ${masked}"
        echo "Cuenta creada para el colaborador ${masked}."
        continue
      fi
      unconfirmed=$(unconfirmed_with "${email}")
      if [ "${unconfirmed}" != "0" ]; then
        echo "::error::Ya hay una cuenta del colaborador ${masked} sin confirmar (no la creó este workflow). Borrarla en Authentication → Users y volver a desplegar."
        exit 1
      fi
    done
    query=$(node supabase/scripts/chef-members.ts sql)
    result=$(sql "${query}" | jq -c '.[0].result')
    echo "Colaboradores: $(jq -r '"\(.members) en la lista (nuevos: \(.added); sin cambios: \(.kept); salieron: \(.removed); cuentas borradas: \(.accounts_deleted))"' <<< "${result}")."
  fi

  # chef_members tiene que ser la lista, ni uno más ni uno menos (también por email: la misma cantidad
  # no alcanza si es otra persona).
  members_db=$(count "select count(*)::int as n from public.chef_members")
  if [ "${chefs}" != "0" ]; then
    members_match=$(count "select count(*)::int as n from public.chef_members m join auth.users u on u.id = m.profile_id where lower(u.email) = any ($(sql_array "${list}"))")
    if [ "${members_db}" != "${total_list}" ] || [ "${members_match}" != "${total_list}" ]; then
      echo "::error::Los colaboradores en la base (${members_db}) no son los de la lista (${total_list}): revisar public.chef_members."
      exit 1
    fi
  fi

  # Usuarios en Auth: la cocinera, sus colaboradores y las clientas (cuentas con ficha en public.clients).
  # Una cuenta que salió de la lista y no se pudo borrar, o que se creó a mano en el panel, queda de más
  # (sin ficha): el aviso la cuenta.
  total=$(count "select count(*)::int as n from auth.users")
  extra=$(count "select count(*)::int as n from auth.users u where u.id not in (${kitchen_ids}) and not exists (select 1 from public.clients c where c.profile_id = u.id)")
  echo "Usuarios en Auth: ${total} (cocinera: ${chefs}; colaboradores: ${members_db})."
  if [ "${extra}" != "0" ]; then
    echo "::warning::Hay ${extra} usuarios en Auth que no son la cocinera, ni sus colaboradores, ni tienen ficha de cliente: revisar en el panel que no haya otro."
  fi
  account_report
}

case "${1:-}" in
  chef) chef_account ;;
  members) members ;;
  *)
    echo "Uso: bash supabase/scripts/deploy-accounts.sh chef|members" >&2
    exit 2
    ;;
esac
