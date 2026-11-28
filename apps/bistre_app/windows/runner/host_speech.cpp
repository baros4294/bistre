#include "host_speech.h"

#include <sapi.h>

namespace {

constexpr DWORD kDictationLimitMs = 12000;

}  // namespace

std::wstring DictateOnce(HANDLE cancel) {
  std::wstring heard;
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
    return heard;
  }
  ISpRecognizer* recognizer = nullptr;
  ISpObjectTokenCategory* category = nullptr;
  ISpObjectToken* mic = nullptr;
  ISpRecoContext* context = nullptr;
  ISpRecoGrammar* grammar = nullptr;
  LPWSTR mic_id = nullptr;
  const ULONGLONG interest = SPFEI(SPEI_RECOGNITION);
  bool ready =
      SUCCEEDED(CoCreateInstance(CLSID_SpInprocRecognizer, nullptr, CLSCTX_ALL,
                                 IID_PPV_ARGS(&recognizer))) &&
      SUCCEEDED(CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr, CLSCTX_ALL,
                                 IID_PPV_ARGS(&category))) &&
      SUCCEEDED(category->SetId(SPCAT_AUDIOIN, FALSE)) &&
      SUCCEEDED(category->GetDefaultTokenId(&mic_id)) &&
      SUCCEEDED(CoCreateInstance(CLSID_SpObjectToken, nullptr, CLSCTX_ALL,
                                 IID_PPV_ARGS(&mic))) &&
      SUCCEEDED(mic->SetId(nullptr, mic_id, FALSE)) &&
      SUCCEEDED(recognizer->SetInput(mic, TRUE)) &&
      SUCCEEDED(recognizer->CreateRecoContext(&context)) &&
      SUCCEEDED(context->SetNotifyWin32Event()) &&
      SUCCEEDED(context->SetInterest(interest, interest)) &&
      SUCCEEDED(context->CreateGrammar(0, &grammar)) &&
      SUCCEEDED(grammar->LoadDictation(nullptr, SPLO_STATIC)) &&
      SUCCEEDED(grammar->SetDictationState(SPRS_ACTIVE));
  if (ready) {
    HANDLE waits[2] = {context->GetNotifyEventHandle(), cancel};
    if (WaitForMultipleObjects(2, waits, FALSE, kDictationLimitMs) == WAIT_OBJECT_0) {
      SPEVENT event{};
      ULONG fetched = 0;
      while (SUCCEEDED(context->GetEvents(1, &event, &fetched)) && fetched == 1) {
        // A recognition event owns its result object.
        auto* result = reinterpret_cast<ISpRecoResult*>(event.lParam);
        if (event.eEventId == SPEI_RECOGNITION && result != nullptr && heard.empty()) {
          LPWSTR text = nullptr;
          if (SUCCEEDED(result->GetText(static_cast<ULONG>(SP_GETWHOLEPHRASE),
                                        static_cast<ULONG>(SP_GETWHOLEPHRASE), TRUE,
                                        &text, nullptr)) &&
              text != nullptr) {
            heard = text;
            CoTaskMemFree(text);
          }
        }
        if (event.elParamType == SPET_LPARAM_IS_OBJECT && result != nullptr) {
          result->Release();
        }
      }
    }
  }
  if (grammar != nullptr) grammar->Release();
  if (context != nullptr) context->Release();
  if (mic != nullptr) mic->Release();
  if (mic_id != nullptr) CoTaskMemFree(mic_id);
  if (category != nullptr) category->Release();
  if (recognizer != nullptr) recognizer->Release();
  CoUninitialize();
  return heard;
}
