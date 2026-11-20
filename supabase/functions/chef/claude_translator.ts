// La traducción de los platos con Claude (POST /chef/translate, docs/contracts/chef-api.md §12): la
// única parte que usa el SDK oficial de Anthropic. La importa solo index.ts; el pedido, la lectura de
// la respuesta y la validación están en translation.ts (con tests en Node) y handler.ts recibe un
// Translator sin conocer el SDK. handler.test.ts mira el texto de este archivo.
//
// Según la guía de la API (skill claude-api): el SDK fijado a una versión exacta (1.6.0, publicada
// el 05/11/2026), client.beta.messages.create por el fallback del servidor ante una negativa,
// timeout corto y un solo reintento. Nunca loguea ni devuelve el mensaje de un error: puede traer el
// texto del plato. La clave llega de index.ts y no sale de acá.
import Anthropic from "npm:@anthropic-ai/sdk@1.6.0";
import {
  TRANSLATION_MAX_RETRIES,
  TRANSLATION_TIMEOUT_MS,
  buildTranslationRequest,
  replyFromMessage,
  type Translator,
  type TranslatorReply,
} from "./translation.ts";

export function createClaudeTranslator(apiKey: string): Translator {
  // Con timeout propio el SDK no calcula uno por max_tokens; los timeouts también se reintentan, así
  // que lo peor son dos intentos.
  const client = new Anthropic({ apiKey, timeout: TRANSLATION_TIMEOUT_MS, maxRetries: TRANSLATION_MAX_RETRIES });
  return {
    async translate(source) {
      try {
        const message = await client.beta.messages.create(buildTranslationRequest(source));
        return replyFromMessage(message);
      } catch (error) {
        return failureFrom(error);
      }
    },
  };
}

/**
 * Error del SDK → falla para el log, del más específico al más general (APIConnectionTimeoutError
 * hereda de APIConnectionError, y las dos de APIError). Solo el tipo y el estado HTTP.
 */
function failureFrom(error: unknown): TranslatorReply {
  if (error instanceof Anthropic.APIConnectionTimeoutError) return { kind: "failed", reason: "timeout", status: null };
  if (error instanceof Anthropic.APIUserAbortError) return { kind: "failed", reason: "aborted", status: null };
  if (error instanceof Anthropic.APIConnectionError) return { kind: "failed", reason: "connection", status: null };
  if (error instanceof Anthropic.RateLimitError) return { kind: "failed", reason: "rateLimited", status: 429 };
  if (error instanceof Anthropic.APIError) {
    return { kind: "failed", reason: "apiError", status: typeof error.status === "number" ? error.status : null };
  }
  if (error instanceof Anthropic.AnthropicError) return { kind: "failed", reason: "sdk", status: null };
  return { kind: "failed", reason: "unexpected", status: null };
}
