import {logger} from "firebase-functions";
import {onDocumentCreated} from "firebase-functions/v2/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";

// Deliberately no database or Storage dependencies: retired clients must not
// mutate assignments, schedule a purge, or receive a false success response.
function rejectConversationRemoval(auth: {uid: string} | undefined): never {
  if (!auth?.uid) {
    throw new HttpsError("unauthenticated", "Sign in to continue.");
  }
  throw new HttpsError(
    "failed-precondition",
    "Conversation removal is no longer available.",
  );
}

export const closeConversation = onCall(
  {region: "us-west1", enforceAppCheck: false},
  async (request) => rejectConversationRemoval(request.auth),
);

export const deleteConversation = onCall(
  {region: "us-west1", enforceAppCheck: false},
  async (request) => rejectConversationRemoval(request.auth),
);

// Retain the trigger's deployed name and any existing job as inert evidence.
// Neither a queued event nor a retry may erase history after removal is retired.
export const deleteConversationData = onDocumentCreated(
  {
    document: "conversationDeletionJobs/{conversationId}",
    region: "us-west1",
    retry: true,
  },
  async () => {
    logger.warn("Conversation deletion is disabled; queued job retained.");
  },
);
