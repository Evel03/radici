// La traducción de los platos con Claude (POST /chef/translate, docs/contracts/chef-api.md §12) y de
// la lista de compras y la nota de un menú (POST /chef/menus/preview, §13): la única parte que usa el
// SDK oficial de Anthropic. index.ts la importa recién en la primera traducción (import dinámico,
// lazyTranslator): si el SDK no carga, solo fallan las traducciones. El pedido,
// la lectura de la respuesta, el mapeo de errores y la validación están en translation.ts (con tests
// en Node) y handler.ts recibe un Translator sin conocer el SDK. handler.test.ts mira el texto de
// este archivo.
//
// Según la guía de la API (skill claude-api): el SDK fijado a una versión exacta (1.6.0, publicada
// el 05/11/2026), client.beta.messages.create por el fallback del servidor ante una negativa,
// timeout corto por intento, un solo reintento y un tope de 40 s para todo. Nada del entorno cambia
// la llamada: la URL es fija (ANTHROPIC_BASE_URL no desvía la clave), sin logs del SDK
// (ANTHROPIC_LOG=debug loguearía el cuerpo, con el plato) y sin trazas de OpenTelemetry
// (ANTHROPIC_OPEN_TELEMETRY_* podría exportar el contenido). Nunca loguea ni devuelve el mensaje de
// un error. La clave llega de index.ts y no sale de acá.
import Anthropic from "npm:@anthropic-ai/sdk@1.6.0";
import {
  ANTHROPIC_API_URL,
  TRANSLATION_DEADLINE_MS,
  TRANSLATION_MAX_RETRIES,
  TRANSLATION_TIMEOUT_MS,
  buildMenuTranslationRequest,
  buildTranslationRequest,
  failureFrom,
  replyFromMessage,
  type Translator,
} from "./translation.ts";

export function createClaudeTranslator(apiKey: string): Translator {
  // Con timeout propio el SDK no calcula uno por max_tokens. Los timeouts también se reintentan y la
  // espera entre intentos no cuenta: el tope de toda la llamada es el AbortSignal de abajo.
  const client = new Anthropic({
    apiKey,
    baseURL: ANTHROPIC_API_URL,
    logLevel: "off",
    openTelemetry: false,
    timeout: TRANSLATION_TIMEOUT_MS,
    maxRetries: TRANSLATION_MAX_RETRIES,
  });
  return {
    async translate(source) {
      try {
        const message = await client.beta.messages.create(buildTranslationRequest(source), {
          signal: AbortSignal.timeout(TRANSLATION_DEADLINE_MS),
        });
        return replyFromMessage(message);
      } catch (error) {
        return failureFrom(error, Anthropic);
      }
    },
    async translateMenu(source) {
      // El mismo cliente, el mismo tope y el mismo mapeo de errores que un plato.
      try {
        const message = await client.beta.messages.create(buildMenuTranslationRequest(source), {
          signal: AbortSignal.timeout(TRANSLATION_DEADLINE_MS),
        });
        return replyFromMessage(message);
      } catch (error) {
        return failureFrom(error, Anthropic);
      }
    },
  };
}
