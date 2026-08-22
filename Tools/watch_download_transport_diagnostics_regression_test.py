#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


download_manager = read("InstacastWatch/WatchDownloadManager.swift")
connectivity = read("InstacastWatch/WatchConnectivityController.swift")
watch_app = read("InstacastWatch/InstacastWatchApp.swift")

progress_callback = download_manager.split("didWriteData bytesWritten: Int64", 1)[1]
progress_callback = progress_callback.split("\n    }\n}", 1)[0]
progress_gate = progress_callback.find("recordProgressCallback")
main_actor_hop = progress_callback.find("Task { @MainActor in")
require(
    progress_gate >= 0 and main_actor_hop >= 0 and progress_gate < main_actor_hop,
    "URLSession progress callbacks must be sampled/throttled before allocating MainActor tasks; "
    "otherwise a fast transfer floods the Watch main actor with one task per network callback.",
)
require(
    "lastProgressReportByHash" not in download_manager,
    "Progress throttling must be task-identifier based off-main, not a hash-based MainActor map "
    "that can mix replacement tasks for the same episode.",
)

for required_metrics_token in (
    "URLSessionTaskMetrics",
    "didFinishCollecting metrics",
    "transportTaskSeconds",
    "downloadElapsedSeconds",
    "downloadAverageBitsPerSecond",
    "transportTransactionCount",
    "transportProtocol",
    "transportFetchType",
    "transportCellular",
    "transportExpensive",
    "transportConstrained",
    "transportMultipath",
    "transportDNSSeconds",
    "transportConnectSeconds",
    "transportTLSSeconds",
    "transportTTFBSeconds",
    "transportResponseSeconds",
    "transportResponseBodyBytes",
    "progressCallbackCount",
    "maxProgressCallbackGapSeconds",
):
    require(
        required_metrics_token in download_manager,
        f"Completed and failed Watch downloads must log {required_metrics_token} for throughput diagnosis.",
    )

require(
    "transportMetadata" in download_manager
    and '"download-transport-metrics"' in download_manager
    and "delivery: .reliable" in download_manager,
    "Every task completion must emit one reliable transport-metrics diagnostic that correlates "
    "successes, transport failures, validation failures, and cancellations.",
)

for environment_key in (
    "watchAppVersion",
    "watchAppBuild",
    "watchSystemVersion",
    "watchDeviceSystemVersion",
    "watchModel",
    "watchLocalizedModel",
    "watchHardwareIdentifier",
    "watchLowPowerModeEnabled",
    "watchThermalState",
    "watchConnectivityActivationState",
    "watchConnectivityReachable",
    "watchConnectivityOutstandingUserInfoTransfers",
    "watchConnectivityOutstandingFileTransfers",
):
    require(
        f'payloadMetadata["{environment_key}"]' in connectivity,
        f"Every forwarded Watch diagnostic must include {environment_key}.",
    )

require(
    "import WatchKit" in connectivity
    and "WKInterfaceDevice.current()" in connectivity
    and "operatingSystemVersionString" in connectivity,
    "Watch diagnostics must read the real watch model and watchOS/build information at runtime.",
)

scene_phase_log = watch_app.split('WatchDiagnostics.log("scene-phase"', 1)[1]
scene_phase_log = scene_phase_log[:800]
require(
    "delivery: .live" in scene_phase_log,
    "High-frequency scene-phase diagnostics must be best-effort so unreachable periods do not "
    "create an hours-old transferUserInfo backlog.",
)

print("Watch download transport diagnostics regression checks passed")
