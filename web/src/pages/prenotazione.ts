// Página de la clienta (/prenotazione/, SPEC 5.8): su reserva con el menú que Evelyn mandó de cada semana, para
// confirmarlo o pedir cambios (docs/contracts/client-link.md). Toda la lógica vive en src/reservation/ (pura y
// testeada): acá se lee el token del fragmento, se pinta lo que dice el estado y se pasan los clics.
// El idioma: el que eligió la visitante (?lang= o el guardado) o, si nunca eligió, el de su reserva.
// Nunca se registran en la consola el token, la reserva ni el mensaje de la clienta.
import "../styles/base.css";
import "../styles/reservation.css";
import { mount } from "../lib/vdom.ts";
import { createReservation, type ActionResult, type Focus, type Message } from "../reservation/controller.ts";
import { changesCountText, focusId, messageText, reservationTree } from "../reservation/render.ts";
import { readToken } from "../reservation/token.ts";
import { config } from "../site-config.ts";
import { initShell, type Shell } from "./shell.ts";

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Falta #${id} en el HTML`);
  return el as T;
}

const root = byId("reservation");
const live = byId("reservation-live");
const reservation = createReservation({ supabaseUrl: config.supabaseUrl, token: readToken(window.location.hash) });
// La reserva se pide enseguida, junto con los textos: si la visitante nunca eligió un idioma, se usan los de la
// reserva (y la página no se pinta dos veces).
const loaded = reservation.load();
const defaultLang = loaded.then(() => (reservation.state.kind === "ready" ? reservation.state.view.locale : null));

// Otro link en la misma pestaña cambia solo el fragmento: se carga de nuevo con el token nuevo.
window.addEventListener("hashchange", () => window.location.reload());

function start(shell: Shell): void {
  /** Miniaturas que no cargaron: se pintan sin foto. */
  const failedPhotos = new Set<string>();

  /** Pinta el estado. El foco va a `focus` o, si no, se queda en el mismo elemento (por id). */
  const paint = (focus: Focus | null = null): void => {
    const active = document.activeElement;
    const activeId = active instanceof HTMLElement && root.contains(active) ? active.id : "";
    root.replaceChildren(mount(reservationTree({ state: reservation.state, ui: reservation.ui, i18n: shell.i18n, failedPhotos }), document));
    root.setAttribute("aria-busy", reservation.state.kind === "loading" ? "true" : "false");
    const target = (focus ? document.getElementById(focusId(focus)) : null) ?? (activeId ? document.getElementById(activeId) : null);
    target?.focus({ preventScroll: focus === null });
  };

  /** La región en vivo: se vacía y se escribe un instante después, así se anuncia también un texto repetido. */
  const announce = (message: Message | null): void => {
    live.textContent = "";
    if (!message) return;
    window.setTimeout(() => {
      live.textContent = messageText(message, shell.i18n, reservation.state);
    }, 100);
  };

  const finish = (result: ActionResult): void => {
    paint(result.focus);
    announce(result.announce);
  };

  reservation.subscribe(() => paint());
  shell.onLanguageChange(() => paint());

  root.addEventListener("click", (event) => {
    const target = event.target instanceof Element ? event.target.closest<HTMLElement>("[data-action]") : null;
    if (!target || !root.contains(target)) return;
    // Mientras espera una respuesta el botón conserva el foco, pero no hace nada.
    if (target.getAttribute("aria-disabled") === "true") {
      event.preventDefault();
      return;
    }
    const week = Number(target.dataset["week"]);
    switch (target.dataset["action"]) {
      case "retry":
        void reservation.load();
        break;
      case "confirm":
        void reservation.confirm(week).then(finish);
        break;
      case "open-changes":
        finish(reservation.openChanges(week));
        break;
      case "close-changes":
        finish(reservation.closeChanges(week));
        break;
    }
  });

  root.addEventListener("submit", (event) => {
    event.preventDefault();
    const form = event.target instanceof HTMLFormElement ? event.target : null;
    if (!form) return;
    void reservation.submitChanges(Number(form.dataset["week"])).then(finish);
  });

  // Mientras escribe no se vuelve a pintar (se perdería el cursor): solo el contador y, si ya vale, el error.
  root.addEventListener("input", (event) => {
    const field = event.target instanceof HTMLTextAreaElement && event.target.name === "changes" ? event.target : null;
    if (!field) return;
    const week = Number(field.dataset["week"]);
    const { textErrorCleared } = reservation.setDraft(week, field.value);
    const count = document.getElementById(`week-${week}-count`);
    if (count) count.textContent = changesCountText(field.value.length, shell.i18n);
    if (textErrorCleared) {
      document.getElementById(`week-${week}-text-error`)?.remove();
      field.removeAttribute("aria-invalid");
      const describedBy = (field.getAttribute("aria-describedby") ?? "").split(" ").filter((id) => id !== `week-${week}-text-error`);
      field.setAttribute("aria-describedby", describedBy.join(" "));
    }
  });

  // Una miniatura que no carga se saca (nada de ícono roto): el evento error no sube, se escucha en la captura.
  root.addEventListener(
    "error",
    (event) => {
      const img = event.target instanceof HTMLImageElement && event.target.classList.contains("dish__photo") ? event.target : null;
      if (!img) return;
      failedPhotos.add(img.getAttribute("src") ?? "");
      img.closest(".dish")?.classList.remove("dish--photo");
      img.remove();
    },
    true,
  );

  paint();
}

// Si no llegan los textos, initShell muestra el aviso y se resuelve recién si un reintento funciona.
void initShell({ defaultLang }).then(start);
