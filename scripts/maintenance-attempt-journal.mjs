// Public conformance-only surface. The generic attempt runner is intentionally
// private inside the exact Debian autonomy composition.
export {
  attemptIdentity,
  loadPinnedJournalSchema,
  validateJournalConformance,
} from "./debian-maintenance-autonomy.mjs";
