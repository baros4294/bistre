#ifndef RUNNER_HOST_SPEECH_H_
#define RUNNER_HOST_SPEECH_H_

#include <windows.h>

#include <string>

// Listens on the default microphone with the dictation grammar until one phrase is heard,
// `cancel` is set, or 12 s pass; returns the words heard, or nothing. Runs on its own
// thread with its own COM apartment.
std::wstring DictateOnce(HANDLE cancel);

#endif  // RUNNER_HOST_SPEECH_H_
