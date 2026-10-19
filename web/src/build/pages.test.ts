import { expect, it } from "vitest";
import { notFoundCandidates } from "./pages.ts";

it("notFoundCandidates: el 404.html más cercano primero, como Cloudflare Pages", () => {
  expect(notFoundCandidates("/no-existe")).toEqual(["/404.html"]);
  expect(notFoundCandidates("/")).toEqual(["/404.html"]);
  expect(notFoundCandidates("/richiesta/vecchia/pagina")).toEqual([
    "/richiesta/vecchia/404.html",
    "/richiesta/404.html",
    "/404.html",
  ]);
  expect(notFoundCandidates("/gestione/")).toEqual(["/gestione/404.html", "/404.html"]);
  expect(notFoundCandidates("sin-barra")).toEqual([]);
});
