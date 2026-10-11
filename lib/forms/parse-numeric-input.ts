// /lib/forms/parse-numeric-input.ts
// =============================================================================
// Parser de saisie numérique partagé par les formulaires de l'app.
//
// Pourquoi un module dédié :
//   - Plusieurs écrans saisissent des numériques (formulaire de
//     trade, dialogue de clôture). Le même parser doit s'appliquer
//     partout, sinon le test manuel sur un écran diverge du
//     comportement de l'autre.
//
// Comportement :
//   - Virgule ou point acceptés comme séparateur décimal.
//   - Espaces et sauts de ligne retirés avant parsing.
//   - Regex stricte après normalisation de la virgule en point :
//     chiffres optionnels avant la virgule, fraction décimale
//     optionnelle après, OU virgule décimale seule suivie de
//     chiffres. Cela accepte « 5. », « .5 », « 0.5 », « 5 »,
//     « 1234,56 ». Pas de notation scientifique, pas d'hexadécimal,
//     pas d'infini — Number() les accepte, on les rejette.
//   - Si la chaîne est vide, ou la regex ne matche pas → retourne
//     null. Le caller décide quoi faire (null, 0, message d'erreur).
//   - Pas de validation > 0 : c'est une règle métier, pas une
//     préoccupation du parser. Le caller applique sa règle.
// =============================================================================

// Regex stricte post-normalisation virgule → point :
//   -?: signe optionnel
//   (\d+(\.\d*)? | \.\d+) : soit "chiffres[.chiffres]" soit ".chiffres"
// La première branche accepte "5", "5.5", "5." (chiffres . vide).
// La deuxième accepte ".5" (point suivi de chiffres).
const NUMERIC_INPUT_RE = /^-?(\d+(\.\d*)?|\.\d+)$/;

/**
 * Parse une saisie utilisateur en nombre.
 *
 * @param value - La valeur brute du champ texte (type="text", inputMode="decimal").
 * @returns Le nombre parsé, ou null si la saisie est vide / invalide.
 *
 * @example
 *   parseNumericInput("1234,56")  // 1234.56
 *   parseNumericInput("1.5")      // 1.5
 *   parseNumericInput(",5")       // 0.5
 *   parseNumericInput("5.")       // 5
 *   parseNumericInput(".5")       // 0.5
 *   parseNumericInput("  3,14  ") // 3.14
 *   parseNumericInput("")         // null
 *   parseNumericInput("abc")      // null
 *   parseNumericInput("1e3")      // null
 *   parseNumericInput("0x1A")     // null
 *   parseNumericInput("5.5.5")    // null
 */
export function parseNumericInput(value: string): number | null {
  const normalized = value.replace(/\s+/g, "").replace(",", ".");
  if (normalized === "") return null;
  if (!NUMERIC_INPUT_RE.test(normalized)) return null;
  const parsed = Number(normalized);
  if (!Number.isFinite(parsed)) return null;
  return parsed;
}