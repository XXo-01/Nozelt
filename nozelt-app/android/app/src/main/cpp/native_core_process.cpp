#include <jni.h>

#include <android/log.h>
#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

extern char** environ;

namespace {

constexpr char kLogTag[] = "NozeltNativeCore";
constexpr int kInheritedTunFd = 3;

std::string toString(JNIEnv* env, jstring value) {
    if (value == nullptr) return {};
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) return {};
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

bool waitForExit(pid_t pid, int attempts, useconds_t delayMicros) {
    for (int index = 0; index < attempts; ++index) {
        int status = 0;
        const pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) return true;
        usleep(delayMicros);
    }
    return false;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_dev_nozelt_nozelt_NativeCoreProcess_nativeSpawn(
    JNIEnv* env,
    jobject,
    jstring executableValue,
    jstring configValue,
    jstring coreValue,
    jstring logValue,
    jstring assetDirectoryValue,
    jint tunFd
) {
    const std::string executable = toString(env, executableValue);
    const std::string config = toString(env, configValue);
    const std::string core = toString(env, coreValue);
    const std::string logPath = toString(env, logValue);
    const std::string assetDirectory = toString(env, assetDirectoryValue);
    if (executable.empty() || config.empty()) return -EINVAL;
    const std::string descriptor = std::to_string(kInheritedTunFd);

    if (core != "xray" && core != "sing_box") return -EINVAL;

    // Everything the child needs is prepared before fork(). Between fork and
    // exec in this multithreaded process only async-signal-safe calls are
    // allowed, so the child must not touch setenv/unsetenv or allocate.
    const char* tunVariable = core == "xray" ? "XRAY_TUN_FD" : "NOZELT_TUN_FD";
    std::vector<std::string> ownVariables;
    if (tunFd >= 0) ownVariables.push_back(std::string(tunVariable) + "=" + descriptor);
    if (core == "xray" && !assetDirectory.empty()) {
        ownVariables.push_back("XRAY_LOCATION_ASSET=" + assetDirectory);
    }
    std::vector<char*> environment;
    for (char** entry = environ; entry != nullptr && *entry != nullptr; ++entry) {
        const char* value = *entry;
        if (strncmp(value, "XRAY_TUN_FD=", 12) == 0 ||
            strncmp(value, "NOZELT_TUN_FD=", 14) == 0 ||
            strncmp(value, "XRAY_LOCATION_ASSET=", 20) == 0) {
            continue;
        }
        environment.push_back(*entry);
    }
    for (auto& variable : ownVariables) environment.push_back(variable.data());
    environment.push_back(nullptr);

    std::vector<char*> arguments;
    std::string executableArgument = executable;
    std::string runArgument = "run";
    std::string configFlag = "-c";
    std::string configArgument = config;
    arguments.push_back(executableArgument.data());
    if (core == "xray") {
        arguments.push_back(runArgument.data());
        arguments.push_back(configFlag.data());
    }
    arguments.push_back(configArgument.data());
    arguments.push_back(nullptr);

    const pid_t pid = fork();
    if (pid < 0) return -errno;
    if (pid == 0) {
        if (tunFd >= 0) {
            if (dup2(tunFd, kInheritedTunFd) < 0) _exit(120);
            if (tunFd != kInheritedTunFd) close(tunFd);
            const int descriptorFlags = fcntl(kInheritedTunFd, F_GETFD);
            if (descriptorFlags >= 0) {
                fcntl(kInheritedTunFd, F_SETFD, descriptorFlags & ~FD_CLOEXEC);
            }
        }
        if (!logPath.empty()) {
            const int fd = open(logPath.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
            if (fd >= 0) {
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                if (fd > STDERR_FILENO) close(fd);
            }
        }
        execve(executable.c_str(), arguments.data(), environment.data());
        _exit(121);
    }

    __android_log_print(
        ANDROID_LOG_INFO,
        kLogTag,
        "Started %s process pid=%d",
        core.c_str(),
        static_cast<int>(pid)
    );
    return static_cast<jint>(pid);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_nozelt_nozelt_NativeCoreProcess_nativeIsAlive(
    JNIEnv*,
    jobject,
    jint rawPid
) {
    const pid_t pid = static_cast<pid_t>(rawPid);
    if (pid <= 0) return JNI_FALSE;
    int status = 0;
    const pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0) return JNI_TRUE;
    if (result == pid || (result < 0 && errno == ECHILD)) return JNI_FALSE;
    return kill(pid, 0) == 0 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_nozelt_nozelt_NativeCoreProcess_nativeTerminate(
    JNIEnv*,
    jobject,
    jint rawPid
) {
    const pid_t pid = static_cast<pid_t>(rawPid);
    if (pid <= 0) return;
    if (kill(pid, SIGTERM) != 0 && errno == ESRCH) return;
    if (!waitForExit(pid, 20, 100000)) {
        kill(pid, SIGKILL);
        waitForExit(pid, 10, 100000);
    }
}
