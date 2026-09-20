//
//  cperf_symbolicate.c
//  dladdr 符号化与 Mach-O 镜像清单。
//

#include "include/cperf_backtrace.h"

#include <dlfcn.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

#pragma mark - 符号化

bool cperf_symbolicate(uint64_t address, cperf_symbol_t *out) {
    if (out == NULL) {
        return false;
    }
    memset(out, 0, sizeof(*out));

    Dl_info info;
    if (dladdr((const void *)(uintptr_t)address, &info) == 0) {
        return false;
    }

    out->image_path = info.dli_fname;
    out->image_address = (uint64_t)(uintptr_t)info.dli_fbase;
    // Release 构建下大量符号被 strip，dli_sname 为 NULL 是常态，
    // 不是错误——此时靠镜像 UUID + 偏移在服务端还原。
    out->symbol_name = info.dli_sname;
    out->symbol_address = (uint64_t)(uintptr_t)info.dli_saddr;
    return true;
}

#pragma mark - 镜像清单

uint32_t cperf_image_count(void) {
    return _dyld_image_count();
}

/// 从 Mach-O 头里找 LC_UUID。
static bool cperf_read_uuid(const struct mach_header *header, uint8_t out[16]) {
    if (header == NULL) {
        return false;
    }

    uintptr_t cursor;
    uint32_t command_count;

    if (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64) {
        const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
        cursor = (uintptr_t)header64 + sizeof(struct mach_header_64);
        command_count = header64->ncmds;
    } else if (header->magic == MH_MAGIC || header->magic == MH_CIGAM) {
        cursor = (uintptr_t)header + sizeof(struct mach_header);
        command_count = header->ncmds;
    } else {
        return false;
    }

    for (uint32_t i = 0; i < command_count; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize == 0) {
            break;
        }
        if (command->cmd == LC_UUID) {
            const struct uuid_command *uuid_command = (const struct uuid_command *)command;
            memcpy(out, uuid_command->uuid, 16);
            return true;
        }
        cursor += command->cmdsize;
    }
    return false;
}

bool cperf_image_at_index(uint32_t index, cperf_image_t *out) {
    if (out == NULL || index >= _dyld_image_count()) {
        return false;
    }
    memset(out, 0, sizeof(*out));

    const struct mach_header *header = _dyld_get_image_header(index);
    if (header == NULL) {
        return false;
    }

    out->path = _dyld_get_image_name(index);
    out->load_address = (uint64_t)(uintptr_t)header;
    out->slide = (uint64_t)_dyld_get_image_vmaddr_slide(index);
    out->has_uuid = cperf_read_uuid(header, out->uuid);
    return true;
}
