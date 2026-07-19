from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


backend_source = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
controller_source = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
app_delegate_source = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


require(
    "WhisperKitComputeProfile" in backend_source
    and "backgroundComputeOptions" in backend_source
    and "audioEncoderCompute: .cpuAndNeuralEngine" in backend_source,
    "WhisperKit still requires GPU compute in a background path that has no GPU grant.",
)
require(
    "loadedComputeProfile" in backend_source
    and "desiredComputeProfile" in backend_source
    and "compute-profile-changed" in backend_source,
    "A foreground GPU-loaded Whisper model is reused after switching to background-safe compute.",
)
require(
    '"continued-cpu"' in controller_source
    and "BGContinuedProcessingTaskRequest" in controller_source
    and "BGContinuedProcessingTaskRequestResourcesGPU" in controller_source,
    "The user-started continued task has no CPU/ANE path when iOS reports GPU unsupported.",
)
require(
    "hasActiveSystemBackgroundGrant" in queue_source
    and 'case "legacy-processing", "continued-cpu", "continued-gpu":' in queue_source,
    "Queue pausing does not recognize all system-delivered processing grants.",
)
require(
    '"continued-cpu"' in app_delegate_source
    and "ICTranscriptionActiveContinuedPath" in app_delegate_source,
    "The continued-task handler does not preserve the compute path selected by the button.",
)
