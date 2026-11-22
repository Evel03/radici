// Página de la clienta (/prenotazione/, SPEC 5.8): su reserva con el menú que Evelyn mandó de cada semana, para
// confirmarlo o pedir cambios (docs/contracts/client-link.md). Toda la lógica vive en src/reservation/ (pura y
// testeada): acá se lee el token del fragmento, se pinta lo que dice el estado y se pasan los clics.
// El idioma: el que eligió la visitante (?lang= o el guardado) o, si nunca eligió, el de su reserva.
// Nunca se registran en la consola el token, la reserva ni el mensaje de la clienta.
import "../styles/base.css";
import "../styles/reservation.css";
import "../styles/book.css";
import { mount } from "../lib/vdom.ts";
import { createBookHistory, createFocusReveal, type RevealTarget } from "../reservation/book/state.ts";
import { attachBookView, type BookView } from "../reservation/book/view.ts";
import { createReservation, type ActionResult, type Focus, type Message } from "../reservation/controller.ts";
import { changesCountText, focusId, messageText, reservationTree, weekDomId } from "../reservation/render.ts";
import { hashChangeAction, readToken, tokenFragment } from "../reservation/token.ts";
import { config } from "../site-config.ts";
import { initShell, type Shell } from "./shell.ts";

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Falta #${id} en el HTML`);
  return el as T;
}

const root = byId("reservation");
const live = byId("reservation-live");
const token = readToken(window.location.hash);

/** Lo que Espacio y Enter tocan (button) y donde escriben (text); en lo demás, Espacio mueve la página. */
const BUTTON = "button, [role='button'], input[type='button'], input[type='submit'], input[type='reset'], input[type='checkbox'], input[type='radio']";
const TEXT = "textarea, select, input, [contenteditable]:not([contenteditable='false'])";

/** Lo que tiene el foco en la reserva, para createFocusReveal: su caja, cómo traerlo a la vista y qué es. */
function focusedInReservation(): RevealTarget | null {
  const el = document.activeElement;
  if (!(el instanceof HTMLElement) || !root.contains(el)) return null;
  return {
    rect: () => el.getBoundingClientRect(),
    reveal: () => {
      try {
        el.scrollIntoView({ block: "center", behavior: "instant" });
      } catch {
        // Un navegador que no conozca "instant" tira TypeError (WebIDL): centrado igual, con el scroll-behavior de la página.
        el.scrollIntoView({ block: "center" });
      }
    },
    kind: el.matches(BUTTON) ? "button" : el.matches(TEXT) ? "text" : "other",
  };
}

// El libro del menú, desde el primer script, antes de pedir los textos y la reserva: «adelante» puede volver a la
// entrada del libro antes de que la página termine de cargar, y createBookHistory tiene que haber visto la entrada de la
// página para decidir si cerrarlo vuelve atrás (onBookEntry). createFocusReveal escucha popstate y hashchange desde ya:
// después de cerrar el libro o de una vuelta del historial, lo que tiene el foco en la reserva queda a la vista.
const bookHistory = createBookHistory(window);
const focusReveal = createFocusReveal(window, focusedInReservation);

const reservation = createReservation({ supabaseUrl: config.supabaseUrl, token });
// La reserva se pide enseguida, junto con los textos: si la visitante nunca eligió un idioma, se usan los de la
// reserva (y la página no se pinta dos veces).
const loaded = reservation.load();
const defaultLang = loaded.then(() => (reservation.state.kind === "ready" ? reservation.state.view.locale : null));

// Cambió el fragmento con la página abierta (hashChangeAction): otro link pegado en la misma pestaña recarga; un
// ancla interna (el «Vai al contenuto» del encabezado lleva a #main) no puede sacar el token de la URL, así que
// se vuelve a poner sin navegar (replaceState no dispara otro hashchange).
window.addEventListener("hashchange", () => {
  const action = hashChangeAction(token, window.location.hash);
  if (action === "reload") window.location.reload();
  else if (action === "restore" && token) {
    window.history.replaceState(window.history.state, "", `${window.location.pathname}${window.location.search}${tokenFragment(token)}`);
  }
});

function start(shell: Shell): void {
  /** Miniaturas que no cargaron: se pintan sin foto. */
  const failedPhotos = new Set<string>();
  /** El libro del menú (reservation/book/): se conecta después de pintar la página por primera vez. */
  let book: BookView | null = null;

  /** Pinta el estado. El foco va a `focus` o, si no, se queda en el mismo elemento (por id). */
  const paint = (focus: Focus | null = null): void => {
    const active = document.activeElement;
    const activeId = active instanceof HTMLElement && root.contains(active) ? active.id : "";
    const tree = reservationTree({
      state: reservation.state,
      ui: reservation.ui,
      i18n: shell.i18n,
      retrying: reservation.retrying,
      pageNotice: reservation.pageNotice,
      failedPhotos,
    });
    root.replaceChildren(mount(tree, document));
    root.setAttribute("aria-busy", reservation.state.kind === "loading" || reservation.retrying ? "true" : "false");
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
    const session = target.dataset["session"] ?? "";
    switch (target.dataset["action"]) {
      case "retry":
        void reservation.retry().then(finish);
        break;
      case "confirm":
        void reservation.confirm(session).then(finish);
        break;
      case "open-changes":
        finish(reservation.openChanges(session));
        break;
      case "close-changes":
        finish(reservation.closeChanges(session));
        break;
      case "open-book":
        book?.open(session, target.id || null);
        break;
    }
  });

  root.addEventListener("submit", (event) => {
    event.preventDefault();
    const form = event.target instanceof HTMLFormElement ? event.target : null;
    if (!form) return;
    void reservation.submitChanges(form.dataset["session"] ?? "").then(finish);
  });

  // Mientras escribe no se vuelve a pintar (se perdería el cursor): solo el contador y, si ya vale, el error.
  root.addEventListener("input", (event) => {
    const field = event.target instanceof HTMLTextAreaElement && event.target.name === "changes" ? event.target : null;
    if (!field) return;
    const session = field.dataset["session"] ?? "";
    const id = weekDomId(session);
    const { textErrorCleared } = reservation.setDraft(session, field.value);
    const count = document.getElementById(`${id}-count`);
    if (count) count.textContent = changesCountText(field.value.length, shell.i18n);
    if (textErrorCleared) {
      document.getElementById(`${id}-text-error`)?.remove();
      field.removeAttribute("aria-invalid");
      const describedBy = (field.getAttribute("aria-describedby") ?? "").split(" ").filter((ref) => ref !== `${id}-text-error`);
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

  // El libro del menú: «Sfoglia il menù» en cada semana o libro=<sesión> en el fragmento (el link del mensaje).
  book = attachBookView({
    token,
    brand: config.brandName,
    i18n: () => shell.i18n,
    state: () => reservation.state,
    onStateChange: (listener) => reservation.subscribe(listener),
    onLanguageChange: (listener) => shell.onLanguageChange(() => listener()),
    history: bookHistory,
    reveal: focusReveal,
  });
}

// Si no llegan los textos, initShell muestra el aviso y se resuelve recién si un reintento funciona.
void initShell({ defaultLang }).then(start);
