//
//  cperf_backtrace.c
//  主线程登记与线程枚举。
//

#include "include/cperf_backtrace.h"

#include <pthread.h>
#include <string.h>

#pragma mark - 主线程

/// 主线程端口。进程生命周期内不变，因此一次登记、全程可读。
///
/// 用 volatile 而非原子类型：写入只发生一次（bootstrap 期间的主线程上），
/// 之后全是读取；而这个值要在 signal handler 里被读到，
/// 那里连 `atomic_load` 的函数调用开销都该省掉。
static volatile mach_port_t g_main_thread_port = MACH_PORT_NULL;

void cperf_register_main_thread(void) {
    g_main_thread_port = pthread_mach_thread_np(pthread_self());
}

mach_port_t cperf_main_thread_port(void) {
    return g_main_thread_port;
}

bool cperf_is_main_thread_port(mach_port_t thread) {
    mach_port_t main_port = g_main_thread_port;
    return main_port != MACH_PORT_NULL && thread == main_port;
}

#pragma mark - 线程枚举

kern_return_t cperf_thread_list(thread_act_array_t *threads, mach_msg_type_number_t *count) {
    if (threads == NULL || count == NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    *threads = NULL;
    *count = 0;
    return task_threads(mach_task_self(), threads, count);
}

void cperf_free_thread_list(thread_act_array_t threads, mach_msg_type_number_t count) {
    if (threads == NULL) {
        return;
    }
    // task_threads 为每个线程都返回一个 send right，逐个释放后
    // 再释放承载数组的那块 vm 内存。漏掉任何一步都是端口/内存泄漏——
    // 而这个函数会被高频调用（每次全线程采样一次）。
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        (vm_size_t)(count * sizeof(thread_act_t))
    );
}

void cperf_thread_name(mach_port_t thread, char *buffer, size_t buffer_size) {
    if (buffer == NULL || buffer_size == 0) {
        return;
    }
    buffer[0] = '\0';

    pthread_t handle = pthread_from_mach_thread_np(thread);
    if (handle == NULL) {
        return;
    }
    if (pthread_getname_np(handle, buffer, buffer_size) != 0) {
        buffer[0] = '\0';
    }
}
