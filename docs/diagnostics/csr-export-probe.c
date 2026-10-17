/* Original diagnostic source, MIT. No target function is invoked. */
#include <windows.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>

int main(void)
{
    HMODULE module;
    FARPROC positive;
    FARPROC target;
    DWORD module_error;
    DWORD positive_error;
    DWORD target_error;

    SetLastError(ERROR_SUCCESS);
    module = GetModuleHandleW(L"ntdll.dll");
    module_error = GetLastError();
    if (!module) {
        printf("{\"pointerBits\":%u,\"ntdllPresent\":false,\"lastError\":%lu}\n",
               (unsigned)(sizeof(void *) * 8), (unsigned long)module_error);
        return 1;
    }

    SetLastError(ERROR_SUCCESS);
    positive = GetProcAddress(module, "NtQueryInformationProcess");
    positive_error = GetLastError();
    SetLastError(ERROR_SUCCESS);
    target = GetProcAddress(module, "CsrGetProcessId");
    target_error = GetLastError();

    printf("{\"pointerBits\":%u,\"ntdllPresent\":true,"
           "\"NtQueryInformationProcess\":{\"present\":%s,\"address\":\"0x%" PRIxPTR "\",\"lastError\":%lu},"
           "\"CsrGetProcessId\":{\"present\":%s,\"address\":\"0x%" PRIxPTR "\",\"lastError\":%lu},"
           "\"targetInvoked\":false}\n",
           (unsigned)(sizeof(void *) * 8),
           positive ? "true" : "false", (uintptr_t)positive, (unsigned long)positive_error,
           target ? "true" : "false", (uintptr_t)target, (unsigned long)target_error);
    fflush(stdout);
    return positive ? 0 : 2;
}
