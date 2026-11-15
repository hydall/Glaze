#ifndef RUNNER_RUNTIME_CHECK_H_
#define RUNNER_RUNTIME_CHECK_H_

// Checks the Visual C++ runtime this process loaded before anything uses it.
//
// Glaze ships msvcp140.dll next to Glaze.exe, but a copy missing those files
// falls back to the one in System32, and below 14.40 that crashes the first
// time a plugin locks a mutex (for Glaze: when a chat opens). Shows a dialog
// offering Microsoft's download page in that case.
//
// Returns false when the reader chose to go and get the runtime: the caller
// should exit. True when the runtime is new enough, its version cannot be
// read, or the reader chose to start anyway.
bool CheckVisualCppRuntime();

#endif  // RUNNER_RUNTIME_CHECK_H_
