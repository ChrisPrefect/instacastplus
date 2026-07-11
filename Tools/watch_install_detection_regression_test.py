from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method {signature}.")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing method body for {signature}.")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise SystemExit(f"Unterminated method body for {signature}.")


refresh_body = method_body(MANAGER, "- (void)_refreshSessionStateAndNotify:(BOOL)notify")
incoming_body = method_body(MANAGER, "- (void)_handleIncomingPayloadOnMainThread:(NSDictionary*)payload type:(NSString*)type")
manifest_body = method_body(MANAGER, "- (BOOL)_sendManifestPayload:(NSDictionary*)payload")

require(
    "self.watchAppInstalled = session.watchAppInstalled;" in refresh_body
    and "self.lastWatchStatusDate != nil" not in refresh_body,
    "The iOS UI must not treat incoming Watch status as install proof when WCSession.watchAppInstalled is false.",
)

last_status_index = incoming_body.find("self.lastWatchStatusDate = [NSDate date];")
refresh_index = incoming_body.rfind("[self _refreshSessionStateAndNotify:YES];")
require(
    last_status_index >= 0 and refresh_index > last_status_index,
    "Incoming Watch payloads must record status before refreshing the iOS Watch UI.",
)

require(
    "BOOL shouldSyncAfterHandling = NO;" in incoming_body
    and "BOOL shouldSyncAfterHandling = (!hadWatchStatus && self.needsManifestSyncAfterActivation);" not in incoming_body,
    "The first incoming Watch status must not retry a manifest that WCSession rejected as not installed.",
)

require(
    "if (session.activationState != WCSessionActivationStateActivated || !session.watchAppInstalled)" in manifest_body,
    "Manifest delivery must stay blocked while WCSession.watchAppInstalled is false.",
)

context_error_index = manifest_body.find("if (contextError) {")
transfer_index = manifest_body.find("[self _transferUserInfo:payload];", context_error_index)
return_no_index = manifest_body.find("return NO;", context_error_index)
require(
    context_error_index >= 0 and return_no_index > context_error_index and (transfer_index < 0 or return_no_index < transfer_index),
    "A failed updateApplicationContext must return NO instead of logging a fake successful manifest send.",
)
